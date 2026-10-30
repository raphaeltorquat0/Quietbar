import AVFoundation
import Foundation
import Testing
@testable import QuietAudio

/// Render offline de um arquivo de verdade: grava, lê do disco, processa, grava e confere.
@Suite struct OfflineRenderTests {
    private let fs = 48_000.0

    /// 4 s estéreo com picos em 0 dBFS: tons graves e agudos e ruído, para a curva ter o que somar.
    private func writeTestFile(_ url: URL) throws {
        let n = Int(4 * fs)
        var g = SystemRandomNumberGenerator()
        var l = (0..<n).map { i -> Float in
            let t = Double(i) / fs
            return Float(0.4 * sin(2 * .pi * 80 * t) + 0.3 * sin(2 * .pi * 1200 * t) + 0.2 * sin(2 * .pi * 7000 * t))
                + Float.random(in: -0.05...0.05, using: &g)
        }
        let peak = l.map(abs).max() ?? 1
        l = l.map { $0 / peak }
        try write(l, l, to: url)
    }

    private func write(_ l: [Float], _ r: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(l.count))!
        b.frameLength = AVAudioFrameCount(l.count)
        for i in 0..<l.count { b.floatChannelData![0][i] = l[i]; b.floatChannelData![1][i] = r[i] }
        try file.write(from: b)
    }

    private func read(_ url: URL) throws -> ([Float], [Float]) {
        let file = try AVAudioFile(forReading: url)
        let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: b)
        let n = Int(b.frameLength)
        return (Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: n)),
                Array(UnsafeBufferPointer(start: b.floatChannelData![1], count: n)))
    }

    private func rmsDB(_ x: ArraySlice<Float>) -> Double {
        10 * log10(x.reduce(0) { $0 + Double($1 * $1) } / Double(x.count))
    }

    @Test func renderWithAndWithoutChain() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "entrada.caf"), rendered = dir.appending(path: "saida.caf")
        try writeTestFile(source)

        // Curva que empurra grave e agudo acima de 0 dBFS se a pré-amplificação falhar.
        let curve = EQCurve(name: "t", filters: [EQFilter(.lowShelf, frequency: 150, gain: 6, q: 0.7),
                                                 EQFilter(.peak, frequency: 7000, gain: 5, q: 1),
                                                 EQFilter(.peak, frequency: 1200, gain: -3, q: 1)])
        let chain = DSPChain()
        chain.set(curve: curve, sampleRate: fs)
        chain.reset(sampleRate: fs)
        chain.setFade(open: true)
        var (l, r) = try read(source)
        let dry = l
        chain.process(left: &l, right: &r)
        try write(l, r, to: rendered)

        let (out, _) = try read(rendered)
        let tail = Int(fs)...
        #expect(out.allSatisfy { $0.isFinite })
        #expect((out.map(abs).max() ?? 9) <= 0.8912, "sem clipping")
        // A pré-amplificação é a do pico da curva; o nível cai, mas não some.
        let drop = rmsDB(out[tail]) - rmsDB(dry[tail])
        #expect(drop < 0 && drop > curve.autoPreampDB() - 1.5)

        // A cadeia em bypass devolve o arquivo idêntico.
        let plain = DSPChain()
        plain.set(curve: curve, sampleRate: fs)
        plain.setBypass(true)
        plain.reset(sampleRate: fs)
        plain.setFade(open: true)
        var (bl, br) = try read(source)
        plain.process(left: &bl, right: &br)
        #expect(zip(bl[4800...], dry[4800...]).allSatisfy { $0 == $1 })
    }
}
