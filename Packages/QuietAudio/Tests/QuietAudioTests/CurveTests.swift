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
