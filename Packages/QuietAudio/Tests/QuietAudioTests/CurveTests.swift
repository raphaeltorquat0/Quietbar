import Foundation
import Testing
@testable import QuietAudio

@Suite struct CurveFormatTests {
    /// Formato do `ParametricEQ.txt`, com valores inventados: nenhuma medição real entra no repositório.
    static let sample = """
    Preamp: -4.0 dB
    Filter 1: ON LSC Fc 100 Hz Gain -2.5 dB Q 0.70
    Filter 2: ON PK Fc 2000 Hz Gain 4.0 dB Q 1.50
    Filter 3: ON HSC Fc 9000 Hz Gain 1.5 dB Q 0.71
    Filter 4: OFF PK Fc 3000 Hz Gain 1.0 dB Q 1.00
    Filter 5: ON None
    """

    @Test func parsesAutoEQ() throws {
        let c = try EQCurve.parseAutoEQ(Self.sample, name: "x")
        #expect(c.filters == [EQFilter(.lowShelf, frequency: 100, gain: -2.5, q: 0.7),
                              EQFilter(.peak, frequency: 2000, gain: 4, q: 1.5),
                              EQFilter(.highShelf, frequency: 9000, gain: 1.5, q: 0.71)])
    }

    @Test func autoEQRoundTrip() throws {
        let c = try EQCurve.parseAutoEQ(Self.sample, name: "x")
        #expect(try EQCurve.parseAutoEQ(c.autoEQText(), name: "x") == c)
    }

    @Test func jsonRoundTrip() throws {
        let c = try EQCurve.parseAutoEQ(Self.sample, name: "Minha curva")
        #expect(try EQCurve.parseJSON(c.jsonData()) == c)
    }

    @Test func rejectsBadFiles() {
        #expect(throws: CurveError.self) { try EQCurve.parseAutoEQ("nada aqui", name: "x") }
        #expect(throws: CurveError.self) { try EQCurve.parseAutoEQ("Filter 1: ON XX Fc 1 Hz Gain 1 dB Q 1", name: "x") }
        #expect(throws: CurveError.self) { try EQCurve.parseAutoEQ("Filter 1: ON PK Fc 1000 Hz Gain 99 dB Q 1", name: "x") }
        #expect(throws: CurveError.self) { try EQCurve.parseAutoEQ("Filter 1: ON PK Gain 1 dB Q 1", name: "x") }
        #expect(throws: CurveError.self) { try EQCurve.parseJSON(Data("{}".utf8)) }
        let many = (1...11).map { "Filter \($0): ON PK Fc 1000 Hz Gain 1 dB Q 1" }.joined(separator: "\n")
        #expect(throws: CurveError.tooManyFilters(11)) { try EQCurve.parseAutoEQ(many, name: "x") }
    }
}

@Suite struct CurveDownloadWatcherTests {
    private let sample = "Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00\n"

    private func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func offersOnlyWhatIsNew() throws {
        let d = try folder()
        defer { try? FileManager.default.removeItem(at: d) }
        try sample.write(to: d.appending(path: "ParametricEQ.txt"), atomically: true, encoding: .utf8)
        var w = CurveDownloadWatcher(directory: d)
        #expect(w.poll() == nil, "o que já estava na pasta não é novo")

        let new = d.appending(path: "Sony WH-1000XM5 ParametricEQ (1).txt")
        try sample.write(to: new, atomically: true, encoding: .utf8)
        let polled = w.poll()
        let found = try #require(polled)
        #expect(found.url.lastPathComponent == new.lastPathComponent)
        #expect(found.curve.filters.count == 1)
        #expect(w.poll() == nil, "oferece uma vez só")
    }

    @Test func ignoresOtherFilesAndInvalidCurves() throws {
        let d = try folder()
        defer { try? FileManager.default.removeItem(at: d) }
        var w = CurveDownloadWatcher(directory: d)
        try sample.write(to: d.appending(path: "outra coisa.txt"), atomically: true, encoding: .utf8)
        try "isto não é uma curva".write(to: d.appending(path: "ParametricEQ.txt"), atomically: true, encoding: .utf8)
        #expect(w.poll() == nil)
    }
}

@Suite struct EchoVerdictTests {
    @available(macOS 14.2, *)
    private func verdict(_ baseline: Float, _ muted: Float, _ restored: Float) -> EchoTest.Result.Verdict {
        EchoTest.Result(baseline: baseline, muted: muted, restored: restored, tapRan: true).verdict
    }

    @available(macOS 14.2, *)
    @Test func failsUnlessTheOriginalReachesZero() {
        #expect(verdict(0.1, 0, 0.1) == .passed)
        #expect(verdict(0.1, 0.063, 0.1) == .echo)
        #expect(verdict(0.1, 0.001, 0.1) == .echo)
        #expect(verdict(0.1, 0, 0) == .notRestored)
        #expect(verdict(0, 0, 0) == .noLoopback)
    }
}
