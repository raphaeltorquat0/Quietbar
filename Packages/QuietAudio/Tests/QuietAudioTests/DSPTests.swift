import Foundation
import Testing
@testable import QuietAudio

/// Passa um seno pela cadeia e mede o ganho real em regime, em dB.
private func measuredGainDB(_ curve: EQCurve, frequency: Double, fs: Double, level: Float = 0.05) -> Double {
    let chain = DSPChain()
    chain.set(curve: curve, sampleRate: fs)
    chain.reset(sampleRate: fs)
    chain.setFade(open: true)
    let n = Int(fs)
    var l = (0..<n).map { level * Float(sin(2 * .pi * frequency * Double($0) / fs)) }
    var r = l
    let dry = l
    chain.process(left: &l, right: &r)
    let tail = n / 2 // depois do fade e do transitório
    func rms(_ x: ArraySlice<Float>) -> Double { (x.reduce(0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot() }
    return 20 * log10(rms(l[tail...]) / rms(dry[tail...]))
}

/// Protótipo analógico do cookbook levado pela transformada bilinear: conta independente do código dos coeficientes.
private func theoreticalDB(_ f: EQFilter, at frequency: Double, fs: Double) -> Double {
    let a = pow(10, f.gain / 40), q = f.q
    let s = tan(.pi * frequency / fs) / tan(.pi * f.frequency / fs)
    func mag(_ nr: Double, _ ni: Double, _ dr: Double, _ di: Double) -> Double { (nr * nr + ni * ni) / (dr * dr + di * di) }
    let m: Double
    switch f.kind {
    case .peak: // (s² + s·A/Q + 1) / (s² + s/(A·Q) + 1)
        m = mag(1 - s * s, s * a / q, 1 - s * s, s / (a * q))
    case .lowShelf: // A · (s² + √A/Q·s + A) / (A·s² + √A/Q·s + 1)
        m = a * a * mag(a - s * s, a.squareRoot() / q * s, 1 - a * s * s, a.squareRoot() / q * s)
    case .highShelf: // A · (A·s² + √A/Q·s + 1) / (s² + √A/Q·s + A)
        m = a * a * mag(1 - a * s * s, a.squareRoot() / q * s, a - s * s, a.squareRoot() / q * s)
    }
    return 10 * log10(m)
}

@Suite struct FilterResponseTests {
    static let filters: [EQFilter] = [
        EQFilter(.peak, frequency: 1000, gain: -6, q: 1.4),
        EQFilter(.peak, frequency: 120, gain: -9, q: 0.7),
        EQFilter(.lowShelf, frequency: 105, gain: -6, q: 0.7),
        EQFilter(.highShelf, frequency: 8000, gain: -5, q: 0.7),
    ]

    @Test(arguments: filters) func measuredMatchesTheory(_ f: EQFilter) {
        for fs in [44_100.0, 48_000.0] {
            for freq in [50.0, 105, 400, 1000, 2000, 8000, 15000] {
                let curve = EQCurve(name: "t", filters: [f])
                let got = measuredGainDB(curve, frequency: freq, fs: fs)
                #expect(abs(got - theoreticalDB(f, at: freq, fs: fs)) < 0.05, "\(f.kind) fs=\(fs) f=\(freq)")
                #expect(abs(curve.responseDB(at: freq, sampleRate: fs) - theoreticalDB(f, at: freq, fs: fs)) < 1e-6)
            }
        }
    }

    @Test func peakHitsItsGainAtCenter() {
        let f = EQFilter(.peak, frequency: 1000, gain: -6, q: 2)
        #expect(abs(measuredGainDB(EQCurve(name: "t", filters: [f]), frequency: 1000, fs: 48_000) + 6) < 0.05)
    }

    @Test func shelvesHitHalfGainAtCorner() {
        let low = EQFilter(.lowShelf, frequency: 200, gain: -8, q: 0.7)
        let high = EQFilter(.highShelf, frequency: 4000, gain: -8, q: 0.7)
        #expect(abs(EQCurve(name: "t", filters: [low]).responseDB(at: 200) + 4) < 0.01)
        #expect(abs(EQCurve(name: "t", filters: [high]).responseDB(at: 4000) + 4) < 0.01)
        #expect(abs(EQCurve(name: "t", filters: [low]).responseDB(at: 20) + 8) < 0.1)
        #expect(abs(EQCurve(name: "t", filters: [high]).responseDB(at: 20000) + 8) < 0.3)
    }

    @Test func filterAboveNyquistIsNeutral() {
        #expect(EQFilter(.peak, frequency: 20_000, gain: 6, q: 1).coefficients(sampleRate: 16_000) == .identity)
    }
}

@Suite struct ChainTests {
    private func makeChain(_ filters: [EQFilter], fs: Double = 48_000) -> DSPChain {
        let c = DSPChain()
        c.set(curve: EQCurve(name: "t", filters: filters), sampleRate: fs)
        c.reset(sampleRate: fs)
        c.setFade(open: true)
        return c
    }

    @Test func autoPreampCancelsTheBoost() {
        let curve = EQCurve(name: "t", filters: [EQFilter(.peak, frequency: 1000, gain: 6, q: 1), EQFilter(.peak, frequency: 1100, gain: 3, q: 1)])
        let preamp = curve.autoPreampDB()
        #expect(preamp < -8 && preamp > -9.1)
        #expect(abs(measuredGainDB(curve, frequency: 1040, fs: 48_000)) < 0.1) // pico da curva vira 0 dB
        #expect(EQCurve(name: "t", filters: [EQFilter(.peak, frequency: 1000, gain: -6, q: 1)]).autoPreampDB() == 0)
    }

    @Test func limiterHoldsTheCeilingWithoutFlatTops() {
        let c = makeChain([]) // sem curva: só o limitador
        let fs = 48_000.0
        var l = (0..<48_000).map { Float(2 * sin(2 * .pi * 440 * Double($0) / fs)) } // +6 dBFS
        var r = l
        c.process(left: &l, right: &r)
        #expect((l.map(abs).max() ?? 9) <= 0.8911)
        // Depois do ataque o limitador é ganho, não corte: o seno continua seno.
        let tail = l[24_000...]
        let peak = tail.map(abs).max() ?? 0
        let flat = tail.filter { abs($0) > peak * 0.999 }.count
        #expect(Double(flat) / Double(tail.count) < 0.05)
        // Volta a ganho 1 depois do pico.
        var quietL = (0..<48_000).map { Float(0.1 * sin(2 * .pi * 440 * Double($0) / fs)) }
        var quietR = quietL
        c.process(left: &quietL, right: &quietR)
        #expect(abs((quietL[40_000...].map(abs).max() ?? 0) - 0.1) < 0.001)
    }

    @Test func bypassIsTheOriginalSignalAndHasNoClick() {
        let c = makeChain([EQFilter(.peak, frequency: 1000, gain: -12, q: 1)])
        let fs = 48_000.0
        let input = (0..<96_000).map { Float(0.5 * sin(2 * .pi * 1000 * Double($0) / fs)) }
        var l = input, r = input
        c.process(left: &l, right: &r)

        c.setBypass(true)
        var l2 = input, r2 = input
        c.process(left: &l2, right: &r2)
        // Passado o crossfade, a saída é a entrada, amostra por amostra.
        #expect(zip(l2[1000...], input[1000...]).allSatisfy { $0 == $1 })
        // A troca acontece em rampa: nenhum salto maior que o do seno com a rampa de 10 ms.
        let maxStep = zip(l2, l2.dropFirst()).map { abs($1 - $0) }.max() ?? 1
        let sineStep = zip(input, input.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(maxStep < sineStep * 1.2)
    }

    @Test func curveChangeHasNoZipperNoise() {
        // Seno de 1 kHz enquanto a curva salta 12 dB: sem interpolação apareceria um degrau.
        let c = makeChain([EQFilter(.peak, frequency: 1000, gain: -12, q: 1)])
        let fs = 48_000.0
        var phase = 0.0
        func next(_ n: Int) -> [Float] {
            (0..<n).map { _ in phase += 2 * .pi * 1000 / fs; return Float(0.3 * sin(phase)) }
        }
        var warm = next(48_000), warmR = warm
        c.process(left: &warm, right: &warmR)
        c.set(curve: EQCurve(name: "t", filters: [EQFilter(.peak, frequency: 1000, gain: 0, q: 1)]), sampleRate: fs)
        var l = next(9_600), r = l
        c.process(left: &l, right: &r)
        // Segunda diferença de um seno puro é pequena; um degrau a faria explodir.
        let d2 = (2..<l.count).map { abs(l[$0] - 2 * l[$0 - 1] + l[$0 - 2]) }.max() ?? 1
        #expect(d2 < 0.3 * Float(pow(2 * .pi * 1000 / fs, 2)) * 1.3)
        #expect(abs((l[4_800...].map(abs).max() ?? 0) - 0.3) < 0.01) // terminou no ganho novo
    }

    @Test func fadeStartsSilentAndClosesSilent() {
        let c = DSPChain()
        c.reset(sampleRate: 48_000)
        var l = [Float](repeating: 0.5, count: 2048), r = l
        c.process(left: &l, right: &r) // fechada: nada sai
        #expect(l.allSatisfy { $0 == 0 })
        c.setFade(open: true)
        l = [Float](repeating: 0.5, count: 4800); r = l
        c.process(left: &l, right: &r)
        #expect(l[0] < 0.01 && abs(l[4799] - 0.5) < 0.001)
        #expect(zip(l, l.dropFirst()).allSatisfy { $1 >= $0 })
        c.setFade(open: false)
        l = [Float](repeating: 0.5, count: 4800); r = l
        c.process(left: &l, right: &r)
        #expect(l[0] > 0.48 && l[4799] < 0.001)
    }

    @Test func statsSeeSignalButNotTheTestTone() {
        let c = makeChain([])
        var l = [Float](repeating: 0, count: 1024), r = l
        c.process(left: &l, right: &r)
        #expect(c.readStats().lastSignalFrame == 0)

        // O tom sai pela cadeia, mas não pode contar como áudio do sistema: é o que libera o mudo.
        c.setTone(true)
        l = [Float](repeating: 0, count: 4800); r = l
        c.process(left: &l, right: &r)
        let toned = c.readStats()
        #expect(toned.lastSignalFrame == 0)
        #expect(toned.outputPeak > 0.05)
        c.setTone(false)

        l = [Float](repeating: 0.2, count: 1024); r = l
        c.process(left: &l, right: &r)
        #expect(c.readStats().lastSignalFrame == 6848)
    }

    @Test func staysStableUnderFullScaleNoiseAndExtremeCurves() {
        let extreme = (0..<10).map { EQFilter(.peak, frequency: 40 * pow(2, Double($0)), gain: $0 % 2 == 0 ? 24 : -24, q: 20) }
        let c = makeChain(extreme)
        var g = SystemRandomNumberGenerator()
        var l = (0..<96_000).map { _ in Float.random(in: -1...1, using: &g) }, r = l
        c.process(left: &l, right: &r)
        #expect(l.allSatisfy { $0.isFinite && abs($0) <= 0.8911 })
    }
}
