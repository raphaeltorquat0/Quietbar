import Foundation
import Testing
@testable import QuietAudio

/// Tudo com funções falsas: nenhum teste aqui toca no TCC de verdade nem pode abrir o diálogo.
@Suite struct SystemPermissionTests {
    private func defaults() -> UserDefaults {
        let name = "quietbar.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func fake(_ value: Int32) -> SystemPermission.Functions {
        .init(preflight: { _ in value }, request: { _, done in done(true) })
    }

    @Test(arguments: [("TCCAccessPreflight", true), ("TCCAccessRequest", true), ("TCCAccessPreflight", false)])
    func missingSymbolIsUnavailable(symbol: String, otherExists: Bool) {
        // Um ponteiro inválido de propósito: com um símbolo faltando, nenhum dos dois pode ser chamado.
        nonisolated(unsafe) let invalid = UnsafeMutableRawPointer(bitPattern: 0x10)
        let p = SystemPermission(lookup: { $0 != symbol && otherExists ? invalid : nil }, defaults: defaults())
        #expect(p.status(.audioCapture) == .unavailable)
        #expect(p.problem?.contains(symbol) == true)
    }

    @Test func requestWithoutSymbolsAnswersInsteadOfCrashing() async {
        let p = SystemPermission(lookup: { _ in nil }, defaults: defaults())
        let answer = await withCheckedContinuation { c in p.request(.audioCapture) { c.resume(returning: $0) } }
        #expect(!answer)
    }

    @Test func readsTheThreeKnownAnswers() {
        for (value, status) in [(Int32(0), SystemPermission.Status.granted), (1, .denied), (2, .notAsked)] {
            let p = SystemPermission(functions: fake(value), defaults: defaults())
            #expect(p.status(.audioCapture) == status)
            #expect(p.problem == nil)
        }
    }

    /// A única mudança de assinatura que dá para ver: um retorno fora do combinado.
    @Test func unknownAnswerIsUnavailable() {
        let p = SystemPermission(functions: fake(7), defaults: defaults())
        #expect(p.status(.audioCapture) == .unavailable)
        #expect(p.problem?.contains("7") == true)
    }

    @Test func hungCallReturnsAndDoesNotMarkTheNextRun() {
        let d = defaults()
        let hung = SystemPermission.Functions(preflight: { _ in sleep(5); return 0 }, request: { _, _ in })
        let p = SystemPermission(functions: hung, defaults: d, timeout: 0.05)
        #expect(p.status(.audioCapture) == .unavailable)
        #expect(SystemPermission(functions: fake(0), defaults: d).status(.audioCapture) == .granted)
    }

    /// Uma chamada que derruba o app não acontece uma segunda vez: a marca fica gravada antes dela.
    @Test func crashInsideTheCallIsNotRepeatedOnNextLaunch() {
        nonisolated(unsafe) let d = defaults()
        final class Mark: @unchecked Sendable { var value: String? }
        let mark = Mark()
        let crashing = SystemPermission.Functions(
            preflight: { _ in mark.value = d.string(forKey: "tccCallInFlight"); return 0 },
            request: { _, _ in Issue.record("não pode chamar") })
        #expect(SystemPermission(functions: crashing, defaults: d).status(.audioCapture) == .granted)
        #expect(mark.value != nil)

        // A execução seguinte encontra o que a anterior deixaria se tivesse caído dentro da chamada.
        d.set(mark.value, forKey: "tccCallInFlight")
        let next = SystemPermission(functions: crashing, defaults: d)
        #expect(next.status(.audioCapture) == .unavailable)
        #expect(next.problem != nil)
        next.request(.audioCapture) { #expect(!$0) }
    }

    /// O `TCCAccessRequest` de verdade responde depois de retornar. Sem `@escaping` no bloco, o runtime
    /// derrubava o app ao primeiro pedido (relatório de 03/11, `non-escaping closure has escaped`).
    @Test func requestAnswersAfterTheCallReturns() async {
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        let request: Request = { _, _, done in DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done(true) } }
        nonisolated(unsafe) let symbol = unsafeBitCast(request, to: UnsafeMutableRawPointer.self)
        let p = SystemPermission(lookup: { $0 == "TCCAccessRequest" ? symbol : UnsafeMutableRawPointer(bitPattern: 0x10) },
                                 defaults: defaults())
        let answer = await withCheckedContinuation { c in p.request(.audioCapture) { c.resume(returning: $0) } }
        #expect(answer)
    }

    @Test func finishedCallLeavesNoMark() {
        let d = defaults()
        #expect(SystemPermission(functions: fake(0), defaults: d).status(.audioCapture) == .granted)
        #expect(d.string(forKey: "tccCallInFlight") == nil)
    }
}
