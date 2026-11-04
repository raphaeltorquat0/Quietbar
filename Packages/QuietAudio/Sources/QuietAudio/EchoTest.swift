import CoreAudio
import Foundation

/// Teste de eco: confere se a tap com mudo zera mesmo o som original no dispositivo. O app não enxerga a
/// saída real de um fone, então o teste roda num dispositivo com loopback, que devolve na entrada o que chegou à saída.
/// O tom sai deste processo, e a tap do teste o inclui. Fora do caminho de produção: pode alocar.
@available(macOS 14.2, *)
public enum EchoTest {
    public struct Result: Equatable, Sendable {
        public enum Verdict: Equatable, Sendable {
            case passed
            /// O original continuou chegando ao dispositivo: o usuário ouviria eco.
            case echo
            /// O tom não voltou pela entrada: sem loopback ou sem acesso a ela, o teste não mediu nada.
            case noLoopback
            /// O mudo não saiu ao desmontar.
            case notRestored
        }

        public var baseline: Float
        public var muted: Float
        public var restored: Float
        public var tapRan: Bool

        /// −80 dBFS. O tom toca a −20, e o resto de um mudo incompleto fica muito acima disso.
        public static let zero: Float = 1e-4

        public var verdict: Verdict {
            if baseline < 0.05 { return .noLoopback }
            if muted > Self.zero { return .echo }
            return restored < baseline * 0.9 ? .notRestored : .passed
        }
    }

    private final class Meter: @unchecked Sendable {
        var phase = 0.0
        var peak: Float = 0
    }

    /// Fora do `@MainActor`: o bloco roda na thread de áudio e não pode herdar o isolamento de `run`.
    private nonisolated static func ioBlock(_ meter: Meter, step: Double) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            for b in UnsafeMutableAudioBufferListPointer(output) {
                let channels = Int(b.mNumberChannels), frames = Int(b.mDataByteSize) / 4 / max(channels, 1)
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames {
                    let v = Float(0.1 * sin(meter.phase + step * Double(i)))
                    for c in 0..<channels { p[i * channels + c] = v }
                }
                meter.phase = (meter.phase + step * Double(frames)).truncatingRemainder(dividingBy: 2 * .pi)
            }
            for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(b.mDataByteSize) / 4 { meter.peak = max(meter.peak, abs(p[i])) }
            }
        }
    }

    @MainActor
    public static func run(on device: OutputDevice, log: (String) -> Void) async -> Result {
        let meter = Meter()
        let step = 2 * Double.pi * 1000 / device.sampleRate
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, nil, ioBlock(meter, step: step))
        guard status == noErr, AudioDeviceStart(device.id, proc) == noErr else {
            return Result(baseline: 0, muted: 0, restored: 0, tapRan: false)
        }
        defer {
            AudioDeviceStop(device.id, proc)
            if let proc { AudioDeviceDestroyIOProcID(device.id, proc) }
        }
        func measure(_ seconds: Double) async -> Float {
            try? await Task.sleep(for: .milliseconds(300)) // depois da transição
            meter.peak = 0
            try? await Task.sleep(for: .seconds(seconds))
            return meter.peak
        }

        let baseline = await measure(0.7)
        log(String(format: "tom sem tap: %.4f", baseline))
        let chain = DSPChain()
        let backend = CoreAudioBackend(chain: chain)
        backend.tapsOwnProcess = true
        backend.perform(.mount(device))
        try? await Task.sleep(for: .seconds(1))
        backend.muteOriginal() // sem abrir a saída processada, que voltaria pelo loopback
        let muted = await measure(1)
        let tapRan = chain.readStats().frames > 0
        log(String(format: "com a tap mutando: %.4f (tap %@)", muted, tapRan ? "rodando" : "sem IO"))
        backend.perform(.unmount)
        try? await Task.sleep(for: .milliseconds(300))
        let restored = await measure(0.7)
        log(String(format: "depois de desmontar: %.4f", restored))
        return Result(baseline: baseline, muted: muted, restored: restored, tapRan: tapRan)
    }
}
