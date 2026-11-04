import Foundation
import os

/// Permissões pelo TCC. Não há API pública para consultar ou pedir a de áudio do sistema; a alternativa
/// é deixar o `coreaudiod` pedir ao iniciar a tap, e aí ele para de atender outros apps até a resposta.
/// São símbolos privados, buscados em tempo de execução. Sem eles, `status` responde `.unavailable` e o
/// app cai no fluxo padrão do sistema (`docs/AUDIO.md`, DECISIONS.md #106 e #112).
public final class SystemPermission: @unchecked Sendable {
    public enum Service: String, Sendable {
        case audioCapture = "kTCCServiceAudioCapture"
        case microphone = "kTCCServiceMicrophone"
    }

    public enum Status: Equatable, Sendable { case granted, denied, notAsked, unavailable }

    /// Resolve um símbolo pelo nome. Os testes injetam a falha aqui.
    public typealias Lookup = @Sendable (String) -> UnsafeMutableRawPointer?

    struct Functions: Sendable {
        var preflight: @Sendable (String) -> Int32
        var request: @Sendable (String, @escaping @Sendable (Bool) -> Void) -> Void
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let guardKey = "tccCallInFlight"

    public static let live = SystemPermission(lookup: { name in
        // `dlsym(nil, ...)` procuraria em todas as bibliotecas carregadas.
        tcc.flatMap { dlsym($0, name) }
    })

    private let functions: Functions?
    private let defaults: UserDefaults
    private let stamp: String
    private let timeout: TimeInterval
    private let lastProblem: OSAllocatedUnfairLock<String?>

    /// Por que os símbolos não puderam ser usados, em texto para o log. Nil se está tudo certo.
    public var problem: String? { lastProblem.withLock { $0 } }

    public convenience init(lookup: Lookup, defaults: UserDefaults = .standard) {
        var functions: Functions?
        let missing = ["TCCAccessPreflight", "TCCAccessRequest"].filter { lookup($0) == nil }
        if missing.isEmpty, let preflightSymbol = lookup("TCCAccessPreflight"), let requestSymbol = lookup("TCCAccessRequest") {
            nonisolated(unsafe) let preflight = unsafeBitCast(preflightSymbol, to: Preflight.self)
            nonisolated(unsafe) let request = unsafeBitCast(requestSymbol, to: Request.self)
            functions = Functions(preflight: { preflight($0 as CFString, nil) },
                                  request: { service, done in request(service as CFString, nil) { done($0) } })
        }
        self.init(functions: functions, defaults: defaults,
                  problem: missing.isEmpty ? nil : "símbolo ausente: \(missing.joined(separator: ", "))")
    }

    init(functions: Functions?, defaults: UserDefaults, problem: String? = nil, timeout: TimeInterval = 3) {
        self.defaults = defaults
        self.timeout = timeout
        // Vale até o macOS ou o app mudarem: uma correção de qualquer lado merece nova tentativa.
        stamp = ProcessInfo.processInfo.operatingSystemVersionString + " " + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
        // A assinatura não é visível no `dlsym`: chamar uma função que mudou pode derrubar o processo.
        // A marca sobreviveu à chamada anterior, então não chama de novo.
        if defaults.string(forKey: Self.guardKey) == stamp {
            self.functions = nil
            lastProblem = .init(initialState: "uma chamada ao TCC não terminou na execução anterior")
        } else {
            self.functions = functions
            lastProblem = .init(initialState: problem)
        }
    }

    /// Só consulta: nunca abre diálogo. Faz IPC com o `tccd`, então fica fora da main thread.
    public func status(_ service: Service) -> Status {
        guard let functions else { return .unavailable }
        final class Box: @unchecked Sendable { var value: Int32 = -1 }
        let box = Box(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [self] in
            box.value = guarded { functions.preflight(service.rawValue) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            defaults.removeObject(forKey: Self.guardKey) // lentidão não é queda: não marca a próxima execução
            return report("TCCAccessPreflight não respondeu em \(Int(timeout)) s")
        }
        switch box.value {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notAsked
        default: return report("TCCAccessPreflight devolveu \(box.value), fora de 0 a 2")
        }
    }

    /// Abre o diálogo do macOS. **Só pode ser chamada por um clique explícito do usuário.**
    /// O retorno só chega quando ele responder, e pode nunca chegar.
    public func request(_ service: Service, completion: @escaping @Sendable (Bool) -> Void) {
        guard let functions else { return completion(false) }
        DispatchQueue.global().async { [self] in
            guarded { functions.request(service.rawValue, completion) }
        }
    }

    private func report(_ text: String) -> Status {
        lastProblem.withLock { $0 = text }
        return .unavailable
    }

    private func guarded<T>(_ call: () -> T) -> T {
        defaults.set(stamp, forKey: Self.guardKey)
        defaults.synchronize() // o processo pode morrer na linha seguinte
        defer { defaults.removeObject(forKey: Self.guardKey) }
        return call()
    }
}
