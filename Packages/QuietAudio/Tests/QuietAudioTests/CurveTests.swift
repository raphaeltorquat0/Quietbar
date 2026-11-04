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

@Suite struct CurveFileTests {
    private func file(_ name: String, _ text: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let url = d.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func loadsTheFormatsTheImportOffers() throws {
        let line = "Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00\n"
        #expect(try EQCurve.load(from: file("ParametricEQ.txt", line)).filters.count == 1)
        #expect(try EQCurve.load(from: file("Curva.TXT", line)).name == "Curva")
        let json = try EQCurve(name: "x", filters: [EQFilter(.peak, frequency: 1000, gain: 1, q: 1)]).jsonData()
        #expect(try EQCurve.load(from: file("c.json", String(decoding: json, as: UTF8.self))).filters.count == 1)
    }

    /// Arrastar aceita qualquer arquivo, e o painel deixa passar todo texto simples.
    @Test func refusesOtherFileTypes() throws {
        let url = try file("notas.md", "Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00\n")
        #expect(throws: CurveError.invalidFile("use um arquivo .txt ou .json")) { try EQCurve.load(from: url) }
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
