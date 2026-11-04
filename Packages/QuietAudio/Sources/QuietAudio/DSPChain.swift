import CQuietAudio
import Foundation

/// Dono da cadeia em C. Sobrevive às remontagens da tap: as estatísticas podem ser lidas a qualquer hora.
public final class DSPChain: @unchecked Sendable {
    let raw: OpaquePointer

    public struct Stats: Sendable {
        public var frames: UInt64
        public var lastSignalFrame: UInt64
        public var outputPeak: Float
        public var load: Float
        public var latency: Float
    }

    public init() { raw = qa_chain_create() }
    deinit { qa_chain_destroy(raw) }

    public func reset(sampleRate: Double, inputChannelOffset: Int = 0) {
        qa_chain_reset(raw, sampleRate, Int32(inputChannelOffset))
    }

    public func set(curve: EQCurve, sampleRate: Double) {
        var p = qa_params()
        p.count = Int32(min(curve.filters.count, Int(QA_MAX_FILTERS)))
        p.preamp = pow(10, curve.autoPreampDB(sampleRate: sampleRate) / 20)
        withUnsafeMutableBytes(of: &p.filters) { raw in
            let slots = raw.bindMemory(to: qa_coeffs.self)
            for (i, f) in curve.filters.prefix(Int(QA_MAX_FILTERS)).enumerated() {
                let c = f.coefficients(sampleRate: sampleRate)
                slots[i] = qa_coeffs(b0: c.b0, b1: c.b1, b2: c.b2, a1: c.a1, a2: c.a2)
            }
        }
        qa_chain_set_params(raw, &p)
    }

    public func setBypass(_ on: Bool) { qa_chain_set_bypass(raw, on) }
    public func setFade(open: Bool) { qa_chain_set_fade(raw, open) }
    public func setTone(_ on: Bool) { qa_chain_set_tone(raw, on) }

    public func readStats() -> Stats {
        let s = qa_chain_read_stats(raw)
        return Stats(frames: s.frames, lastSignalFrame: s.last_signal_frame, outputPeak: s.output_peak,
                     load: s.load, latency: s.latency)
    }

    /// Render offline: mesmo caminho da thread de áudio, sem Core Audio.
    public func process(left: inout [Float], right: inout [Float]) {
        let n = min(left.count, right.count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                qa_chain_process(raw, l.baseAddress, r.baseAddress, Int32(n))
            }
        }
    }
}
