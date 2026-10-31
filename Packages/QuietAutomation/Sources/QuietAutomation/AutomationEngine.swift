import MDRKit
import Observation
import os

/// Ajuste que uma regra pode definir. Cada regra define só alguns; o resto vem da camada de baixo.
public enum Field: Hashable, Sendable, CaseIterable {
    case soundMode, ambientLevel, focusOnVoice, equalizerPreset, speakToChat, macSound, macPreset

    /// Os dois últimos ficam no Mac: mudá-los não abre o canal com o fone.
    public var isHeadphone: Bool { self != .macSound && self != .macPreset }
}

public enum Value: Hashable, Sendable {
    case mode(SoundMode), int(Int), bool(Bool), text(String)
}

public typealias Settings = [Field: Value]

/// Da menor para a maior precedência. O override manual e o padrão não são regras: ver `target`.
public enum RuleKind: Int, Comparable, CaseIterable, Sendable {
    case wifi, app, focus, call

    public static func < (a: RuleKind, b: RuleKind) -> Bool { a.rawValue < b.rawValue }
}

public struct Rule: Equatable, Sendable {
    public var id: String
    public var name: String
    public var settings: Settings

    public init(id: String, name: String, settings: Settings) {
        self.id = id
        self.name = name
        self.settings = settings
    }
}

/// O que está decidindo o estado do fone, para o indicador do menu.
public enum ActiveRule: Equatable, Sendable {
    case manual
    case rule(RuleKind, name: String)
}

/// Uma decisão do motor, em formato estruturado: vai para o `os.Logger` e para `onEvent`.
public struct AutomationEvent: Sendable, Equatable, Encodable {
    public enum Kind: String, Sendable, Encodable {
        /// Algo mudou no mundo: regra, microfone, Foco.
        case trigger
        /// O motor calculou o alvo.
        case decision
        /// Comando enviado ao fone.
        case write
        /// O fone informou os valores escritos.
        case confirm
        /// Passou a espera e o fone informa outra coisa.
        case divergence
        case failure, manual, overrideEnded, unavailable
    }

    public var kind: Kind
    public var trigger: String?
    /// Regra em vigor: `call`, `focus`, `app`, `wifi`, `manual` ou `default`.
    public var rule: String?
    /// Ajustes do comando, ou o que o fone informou numa divergência.
    public var fields: [String: String]?
    public var latencyMs: Int?
    /// Escritas feitas até aqui.
    public var writes: Int
}

public struct AutomationCounters: Sendable, Equatable, Encodable {
    public var writes = 0, confirmed = 0, divergent = 0, failed = 0
}

/// Quem lê e escreve de verdade. No app, é o fone e o Som no Mac; nos testes, um falso.
@MainActor
public protocol AutomationDevice: AnyObject {
    /// Estado atual, abrindo o canal se `headphone`. `nil` = indisponível: o motor tenta de novo em `deviceAvailable`.
    func read(headphone: Bool) async -> Settings?
    /// Aplica e devolve o que de fato foi escrito (um fone sem cancelamento recusa esse modo, por exemplo).
    func write(_ changes: Settings) async throws -> Settings
}

/// Motor de prioridade, único ponto que decide e escreve o estado automático.
///
/// O alvo é a soma das camadas, por ajuste: padrão < Wi-Fi < app < Foco < chamada < manual. "Padrão" é o
/// valor de antes de uma regra tocar no ajuste, e volta quando nenhuma regra o define mais.
@MainActor @Observable
public final class AutomationEngine {
    public private(set) var rules: [RuleKind: Rule] = [:]
    public private(set) var manual: Settings = [:]
    public private(set) var counters = AutomationCounters()
    /// Cada decisão, além do log do sistema. Serve à validação e aos testes.
    @ObservationIgnored public var onEvent: ((AutomationEvent) -> Void)?

    @ObservationIgnored private let device: AutomationDevice
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let log = Logger(subsystem: "io.github.raphaeltorquat0.Quietbar", category: "automation")
    /// Valor de cada ajuste antes de uma regra mudá-lo.
    @ObservationIgnored private var baseline: Settings = [:]
    /// Último valor visto em cada ajuste, para reconhecer o que mudou sem passar pelo motor. Sobrevive ao
    /// canal fechar: o botão físico não avisa com o canal solto, e a diferença aparece ao reabrir.
    @ObservationIgnored private var known: Settings = [:]
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var needsRetry = false
    @ObservationIgnored private var echoUntil: ContinuousClock.Instant
    /// Escrita à espera de o fone informar os valores.
    @ObservationIgnored private var awaiting: (changes: Settings, started: ContinuousClock.Instant)?

    /// Depois de escrever, o eco do fone demora: enquanto isso, nada que chega conta como mudança manual.
    static let echoGrace = Duration.seconds(2)

    public init(device: AutomationDevice, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.device = device
        self.now = now
        echoUntil = now()
    }

    /// Regra vencedora, para o indicador. O manual só aparece quando contraria uma regra.
    public var active: ActiveRule? {
        let ruled = rulesMerged
        if manual.keys.contains(where: { ruled[$0] != nil }) { return .manual }
        return RuleKind.allCases.reversed().lazy.compactMap { kind in
            self.rules[kind].flatMap { $0.settings.isEmpty ? nil : ActiveRule.rule(kind, name: $0.name) }
        }.first
    }

    // MARK: - Entradas

    /// Liga, troca ou solta uma regra. Mudar de regra é a "mudança de contexto" que encerra o override;
    /// app em foco sem perfil não muda regra nenhuma e, por isso, não conta.
    public func set(_ kind: RuleKind, _ rule: Rule?) {
        guard rules[kind] != rule else { return }
        let contextChanged = rules[kind]?.id != rule?.id
        rules[kind] = rule
        record(.trigger, trigger: "rule.\(kind)")
        log.notice("regra \(String(describing: kind), privacy: .public): \(rule?.name ?? "nenhuma", privacy: .private)")
        if contextChanged {
            forgetHeadphoneState() // o que mudou com o canal solto não pode valer contra a regra nova
            if !manual.isEmpty {
                manual = [:]
                record(.overrideEnded)
            }
        }
        schedule()
    }

    /// Ajustes escolhidos pelo usuário sem passar pelo fone antes, como "aplicar perfil" nos Atalhos.
    public func applyManually(_ settings: Settings) {
        manual.merge(settings) { $1 }
        record(.manual, trigger: "applyManually", fields: Self.describe(settings))
        schedule()
    }

    /// Estado vindo do fone ou do Som no Mac. O que mudou sem passar pelo motor é override manual:
    /// assim contam painel, atalho, Central de Controle e o botão físico, sem marcar cada um.
    public func deviceReported(_ state: Settings) {
        checkConfirmation(state)
        guard !pumping, now() >= echoUntil else { return }
        let ruled = rulesMerged
        for (field, value) in state {
            guard let old = known[field] else {
                known[field] = value
                continue
            }
            guard old != value else { continue }
            known[field] = value
            manual[field] = ruled[field] == value ? nil : value // voltou ao da regra: acabou o override
            record(.manual, trigger: "device", fields: Self.describe([field: value]))
        }
    }

    /// Mudança no mundo que ainda não virou regra, como o microfone abrindo.
    public func noteTrigger(_ source: String, detail: String? = nil) {
        record(.trigger, trigger: source, fields: detail.map { ["detail": $0] })
    }

    /// O fone voltou. Só escreve se ficou algo pendente: abrir o painel não reimpõe regra.
    public func deviceAvailable() {
        if needsRetry { schedule() }
    }

    /// Outro fone foi escolhido: o que estava guardado era do anterior.
    public func forgetDevice() {
        forgetHeadphoneState()
        baseline = baseline.filter { !$0.key.isHeadphone }
    }

    private func forgetHeadphoneState() { known = known.filter { !$0.key.isHeadphone } }

    // MARK: - Transição

    private var rulesMerged: Settings {
        rules.keys.sorted().reduce(into: Settings()) { $0.merge(rules[$1]!.settings) { $1 } }
    }

    private var target: Settings { baseline.merging(rulesMerged) { $1 }.merging(manual) { $1 } }

    /// Uma transição por vez. O que chegar durante uma escrita entra na próxima volta, já com o alvo mais novo.
    private func schedule() {
        dirty = true
        guard !pumping else { return }
        pumping = true
        Task {
            while dirty {
                dirty = false
                await transition()
            }
            pumping = false
        }
    }

    private func transition() async {
        needsRetry = false
        guard !target.isEmpty else { return }
        guard let state = await device.read(headphone: target.keys.contains { $0.isHeadphone }) else {
            needsRetry = true
            record(.unavailable)
            return
        }
        known.merge(state) { $1 }
        let ruled = rulesMerged
        for field in ruled.keys where baseline[field] == nil && manual[field] == nil {
            baseline[field] = state[field]
        }
        // Só o que o aparelho informa: sem valor lido, o ajuste não existe neste fone.
        let changes = target.filter { field, value in state[field].map { $0 != value } ?? false }
        record(.decision, fields: Self.describe(changes))
        if !changes.isEmpty {
            counters.writes += 1
            awaiting = (changes, now())
            record(.write, fields: Self.describe(changes))
            do {
                known.merge(try await device.write(changes)) { $1 }
                echoUntil = now() + Self.echoGrace
                Task { [weak self] in
                    try? await Task.sleep(for: Self.echoGrace)
                    self?.giveUpOnConfirmation()
                }
            } catch {
                needsRetry = true
                awaiting = nil
                counters.failed += 1
                record(.failure, fields: ["error": error.localizedDescription])
                return
            }
        }
        baseline = baseline.filter { ruled[$0.key] != nil }
    }

    // MARK: - Registro

    /// O fone já informa tudo que foi escrito? Só ajustes do fone esperam: o do Mac vale na hora.
    private func checkConfirmation(_ state: Settings) {
        guard let pending = awaiting, pending.changes.allSatisfy({ !$0.key.isHeadphone || state[$0.key] == $0.value }) else { return }
        awaiting = nil
        counters.confirmed += 1
        record(.confirm, fields: Self.describe(pending.changes), latencyMs: Self.ms(now() - pending.started))
    }

    private func giveUpOnConfirmation() {
        guard let pending = awaiting, now() - pending.started >= Self.echoGrace else { return }
        awaiting = nil
        counters.divergent += 1
        let seen = known.filter { pending.changes[$0.key] != nil }
        record(.divergence, fields: Self.describe(seen), latencyMs: Self.ms(now() - pending.started))
    }

    private func record(_ kind: AutomationEvent.Kind, trigger: String? = nil, fields: [String: String]? = nil, latencyMs: Int? = nil) {
        let rule = switch active {
        case nil: "default"
        case .manual: "manual"
        case .rule(let kind, _): String(describing: kind)
        }
        log.notice("""
            \(kind.rawValue, privacy: .public) gatilho=\(trigger ?? "-", privacy: .public) regra=\(rule, privacy: .public) \
            campos=\(fields?.description ?? "-", privacy: .public) latencia_ms=\(latencyMs ?? -1, privacy: .public) escritas=\(self.counters.writes, privacy: .public)
            """)
        onEvent?(AutomationEvent(kind: kind, trigger: trigger, rule: rule, fields: fields, latencyMs: latencyMs, writes: counters.writes))
    }

    /// Só ajustes do fone, valores simples: nomes de perfil, SSID e bundle ID nunca entram aqui.
    private static func describe(_ s: Settings) -> [String: String] {
        s.reduce(into: [:]) { out, item in
            let value = switch item.value {
            case .mode(let m): m.rawValue
            case .int(let v): String(v)
            case .bool(let v): String(v)
            case .text(let v): v
            }
            out[String(describing: item.key)] = value
        }
    }

    private static func ms(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}
