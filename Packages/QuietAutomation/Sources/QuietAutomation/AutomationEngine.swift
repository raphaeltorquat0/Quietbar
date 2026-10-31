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

    @ObservationIgnored private let device: AutomationDevice
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let log = Logger(subsystem: "io.github.raphaeltorquat0.Quietbar", category: "automation")
    /// Valor de cada ajuste antes de uma regra mudá-lo.
    @ObservationIgnored private var baseline: Settings = [:]
    /// Último valor visto em cada ajuste, para reconhecer o que mudou sem passar pelo motor.
    @ObservationIgnored private var known: Settings = [:]
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var needsRetry = false
    @ObservationIgnored private var echoUntil: ContinuousClock.Instant

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
        log.info("regra \(String(describing: kind), privacy: .public): \(rule?.name ?? "nenhuma")")
        if contextChanged, !manual.isEmpty {
            manual = [:]
            log.info("override manual encerrado pela mudança de contexto")
        }
        schedule()
    }

    /// Ajustes escolhidos pelo usuário sem passar pelo fone antes, como "aplicar perfil" nos Atalhos.
    public func applyManually(_ settings: Settings) {
        manual.merge(settings) { $1 }
        log.info("override manual pedido: \(settings.count, privacy: .public) ajustes")
        schedule()
    }

    /// Estado vindo do fone ou do Som no Mac. O que mudou sem passar pelo motor é override manual:
    /// assim contam painel, atalho, Central de Controle e o botão físico, sem marcar cada um.
    public func deviceReported(_ state: Settings) {
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
            log.info("mudança manual em \(String(describing: field), privacy: .public)")
        }
    }

    /// O canal fechou: o próximo estado lido é ponto de partida, não mudança.
    public func deviceLost() {
        known = known.filter { !$0.key.isHeadphone }
    }

    /// O fone voltou. Só escreve se ficou algo pendente: abrir o painel não reimpõe regra.
    public func deviceAvailable() {
        if needsRetry { schedule() }
    }

    /// Outro fone foi escolhido: o que estava guardado era do anterior.
    public func forgetDevice() {
        deviceLost()
        baseline = baseline.filter { !$0.key.isHeadphone }
    }

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
            log.info("fone indisponível: transição pendente")
            return
        }
        known.merge(state) { $1 }
        let ruled = rulesMerged
        for field in ruled.keys where baseline[field] == nil && manual[field] == nil {
            baseline[field] = state[field]
        }
        // Só o que o aparelho informa: sem valor lido, o ajuste não existe neste fone.
        let changes = target.filter { field, value in state[field].map { $0 != value } ?? false }
        let label = active.map { String(describing: $0) } ?? "padrão"
        log.info("decisão: \(label, privacy: .private) escreve \(changes.count, privacy: .public) ajustes")
        if !changes.isEmpty {
            do {
                known.merge(try await device.write(changes)) { $1 }
                echoUntil = now() + Self.echoGrace
            } catch {
                needsRetry = true
                log.error("escrita falhou: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        baseline = baseline.filter { ruled[$0.key] != nil }
    }
}
