import Testing
import MDRKit

/// Os exemplos do README e do DocC do MDRKit, sem `@testable`: só com a API pública.
@Test func documentedExampleDecodesAndBuilds() throws {
    let bytes: [UInt8] = [0x3E, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x07,
                          0x67, 0x17, 0x01, 0x00, 0x01, 0x00, 0x14, 0xA8, 0x3C]
    let frame = try MDRFrame(decoding: bytes)
    guard case let (.ret, .noiseControl(state))? = MDRMessage.decode(frame.payload) else {
        Issue.record("frame não decodificado"); return
    }
    #expect(state.soundMode == .off)
    #expect(state.ambientLevel == 20)

    let target = NoiseControl(enabled: true, ambientMode: true, ambientLevel: 10)
    let command = MDRMessage.noiseControl(target).command(.set)
    let wire = MDRFrame(type: command.table.dataType, seq: 0, payload: command.payload).encoded()
    #expect(try MDRFrame(decoding: wire).payload == command.payload)
    #expect(MDRMessage.decode(command.payload)?.1 == .noiseControl(target))
}
