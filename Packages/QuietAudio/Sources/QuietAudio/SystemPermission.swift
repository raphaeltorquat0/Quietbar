import Foundation

/// Permissões pelo TCC. Não há API pública para consultar ou pedir a de áudio do sistema; a alternativa
/// seria deixar o `coreaudiod` pedir ao iniciar a tap, e aí ele para de atender outros apps até a resposta.
/// São símbolos privados, buscados em tempo de execução: sem eles, o recurso fica indisponível (DECISIONS.md #106).
public enum SystemPermission {
    public enum Service: String, Sendable {
        case audioCapture = "kTCCServiceAudioCapture"
        case microphone = "kTCCServiceMicrophone"
    }

    public enum Status: Equatable, Sendable { case granted, denied, notAsked, unavailable }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// Só consulta: nunca abre diálogo. Faz IPC com o `tccd`, então fica fora da main thread.
    public static func status(_ service: Service) -> Status {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unavailable }
        return switch unsafeBitCast(symbol, to: Preflight.self)(service.rawValue as CFString, nil) {
        case 0: .granted
        case 1: .denied
        default: .notAsked
        }
    }

    /// Abre o diálogo do macOS. **Só pode ser chamada por um clique explícito do usuário.**
    /// O retorno só chega quando ele responder, e pode nunca chegar.
    public static func request(_ service: Service, completion: @escaping @Sendable (Bool) -> Void) {
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return completion(false) }
        unsafeBitCast(symbol, to: Request.self)(service.rawValue as CFString, nil) { completion($0) }
    }
}
