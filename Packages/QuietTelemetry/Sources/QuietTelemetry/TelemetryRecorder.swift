import Foundation
import Observation

/// O que muda de um dia para o outro sem ser contador: fica no dia, para o pacote de ontem falar de ontem.
public struct TelemetryContext: Codable, Equatable, Sendable {
    public var appVersion: String
    public var macOSMajor: Int
    public var arch: String
    public var deviceModelFamily: String?
    public var automationEnabled: Bool
    public var trialDay: Int?

    public init(appVersion: String, macOSMajor: Int, arch: String, deviceModelFamily: String?, automationEnabled: Bool, trialDay: Int?) {
        self.appVersion = appVersion
        self.macOSMajor = macOSMajor
        self.arch = arch
        self.deviceModelFamily = deviceModelFamily
        self.automationEnabled = automationEnabled
        self.trialDay = trialDay
    }
}

/// Contadores do dia no Mac e envio de no máximo um pacote por dia. Desligado, nada é contado nem guardado.
@MainActor @Observable
public final class TelemetryRecorder {
    struct Day: Codable, Equatable {
        var context: TelemetryContext
        var modeChanges: [String: Int] = [:]
        var triggers: [String: Int] = [:]
        var overrides = 0
        var panelOpens = 0

        var isActive: Bool { !modeChanges.isEmpty || !triggers.isEmpty || overrides > 0 || panelOpens > 0 }
    }

    struct State: Codable, Equatable {
        var enabled = false
        var installId: UUID?
        var installIdCreated: Date?
        var days: [String: Day] = [:]
        var lastSentOn: String?
        var lastAttempt: Date?
    }

    /// Resposta do servidor: `throws` sem conexão.
    public typealias Transport = @Sendable (URLRequest) async throws -> Int

    static let rotationDays = 90
    static let maxPendingDays = 3
    /// Sem retry agressivo: falhou, só tenta de novo depois disso.
    static let retryInterval: TimeInterval = 6 * 3600
    static let timeout: TimeInterval = 10
    /// Só no exemplo mostrado com as métricas desligadas: o ID real nasce ao ligar.
    private static let noID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private(set) var state: State

    @ObservationIgnored private let save: (Data) -> Void
    @ObservationIgnored private let context: () -> TelemetryContext
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let formatter: DateFormatter

    public init(load: () -> Data?, save: @escaping (Data) -> Void, context: @escaping () -> TelemetryContext,
                now: @escaping () -> Date = { Date() }, timeZone: TimeZone = .current) {
        self.save = save
        self.context = context
        self.now = now
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        state = load().flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    public var enabled: Bool { state.enabled }

    /// Desligar apaga tudo: contadores, pendentes e o ID.
    public func setEnabled(_ on: Bool) {
        guard on != state.enabled else { return }
        state = State()
        state.enabled = on
        if on { rotateIDIfNeeded() }
        persist()
    }

    // MARK: - Contagem

    public func recordModeChange(_ source: ModeSource) { touch { $0.modeChanges[source.rawValue, default: 0] += 1 } }
    public func recordTrigger(_ trigger: AutomationTrigger) { touch { $0.triggers[trigger.rawValue, default: 0] += 1 } }
    public func recordOverride() { touch { $0.overrides += 1 } }
    public func recordPanelOpen() { touch { $0.panelOpens += 1 } }

    /// Sem evento nenhum, ainda conta que o app rodou no dia.
    public func recordAppRunning() { touch { _ in } }

    private func touch(_ change: (inout Day) -> Void) {
        guard state.enabled else { return }
        let key = dateString(now())
        let current = context()
        var day = state.days[key] ?? Day(context: current)
        let family = current.deviceModelFamily ?? day.context.deviceModelFamily // o fone conecta só em parte do dia
        let automation = current.automationEnabled || day.context.automationEnabled
        day.context = current
        day.context.deviceModelFamily = family
        day.context.automationEnabled = automation
        change(&day)
        state.days[key] = day
        persist()
    }

    // MARK: - Pacote

    /// JSON do próximo envio, o mesmo que `sendIfDue` manda. Com nada pendente, é o de hoje até agora.
    /// `isExample`: desligado não há ID nem contadores, então mostra o formato com tudo zerado.
    public func nextPayload() -> (json: Data, isExample: Bool, isPartial: Bool) {
        guard state.enabled else {
            let empty = Day(context: context())
            return (packet(empty, date: dateString(now()), id: Self.noID).json(), true, false)
        }
        rotateIDIfNeeded()
        let today = dateString(now())
        if let date = pendingDate(today: today), let day = state.days[date] {
            return (packet(day, date: date).json(), false, false)
        }
        return (packet(state.days[today] ?? Day(context: context()), date: today).json(), false, true)
    }

    private func packet(_ day: Day, date: String, id: UUID? = nil) -> TelemetryPacket {
        let cap = { (n: Int?) in min(n ?? 0, TelemetryPacket.counterCap) }
        let c = day.context
        return TelemetryPacket(
            installId: (id ?? state.installId ?? Self.noID).uuidString.lowercased(),
            date: date, appVersion: c.appVersion, macOSMajor: c.macOSMajor, arch: c.arch, deviceModelFamily: c.deviceModelFamily,
            activeDay: day.isActive,
            manualModeChanges: cap(day.modeChanges.values.reduce(0, +)),
            modeChangesBySource: .init(panel: cap(day.modeChanges["panel"]), controlCenter: cap(day.modeChanges["controlCenter"]),
                                       hotkey: cap(day.modeChanges["hotkey"]), intent: cap(day.modeChanges["intent"]),
                                       externalChange: cap(day.modeChanges["externalChange"])),
            automation: .init(enabled: c.automationEnabled, trialDay: c.trialDay,
                              triggersFired: .init(call: cap(day.triggers["call"]), focus: cap(day.triggers["focus"]), app: cap(day.triggers["app"]),
                                                   wifi: cap(day.triggers["wifi"]), shortcut: cap(day.triggers["shortcut"])),
                              overridesManual: cap(day.overrides)),
            panelOpens: cap(day.panelOpens))
    }

    private func pendingDate(today: String) -> String? { state.days.keys.filter { $0 < today }.min() }

    // MARK: - Envio

    /// Só `https`: sem URL válida, nada sai.
    public static func endpoint(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Só o dia fechado sai. Modo avião falha na hora, e a rede com Dados Reduzidos é recusada pelo próprio pedido.
    public func sendIfDue(endpoint: URL?, transport: Transport) async {
        guard state.enabled, let endpoint else { return }
        rotateIDIfNeeded()
        let today = dateString(now())
        dropExpired(today: today)
        persist()
        guard state.lastSentOn != today,
              state.lastAttempt.map({ now().timeIntervalSince($0) >= Self.retryInterval }) ?? true,
              let date = pendingDate(today: today), let day = state.days[date] else { return }
        state.lastAttempt = now()
        persist()
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.httpBody = packet(day, date: date).json()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Quietbar", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.allowsConstrainedNetworkAccess = false
        do {
            let status = try await transport(request)
            guard (200..<500).contains(status) else { return } // 5xx: fica até vencer
            state.days[date] = nil // 4xx: o servidor nunca vai aceitar este pacote
            if status < 300 || status == 409 { state.lastSentOn = today }
            persist()
        } catch {
            // Sem rede: fica até vencer.
        }
    }

    private func dropExpired(today: String) {
        guard let date = formatter.date(from: today),
              let limit = formatter.calendar.date(byAdding: .day, value: -Self.maxPendingDays, to: date) else { return }
        let oldest = dateString(limit)
        state.days = state.days.filter { $0.key >= oldest }
    }

    private func rotateIDIfNeeded() {
        if let created = state.installIdCreated, state.installId != nil,
           now().timeIntervalSince(created) < TimeInterval(Self.rotationDays) * 86400 { return }
        state.installId = UUID()
        state.installIdCreated = now()
        persist()
    }

    private func dateString(_ date: Date) -> String { formatter.string(from: date) }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { save(data) }
    }
}
