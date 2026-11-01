import MDRKit
import Testing
@testable import MDRSession

private func frame(_ message: MDRMessage, _ verb: MDRVerb, seq: UInt8 = 0) -> [UInt8] {
    MDRFrame(type: .mdr, seq: seq, payload: message.command(verb).payload).encoded()
}

private let ambient = NoiseControl(inquiredType: 0x17, enabled: true, ambientMode: true, ambientLevel: 10)
private let cancelling = NoiseControl(inquiredType: 0x17, enabled: true, ambientMode: false, ambientLevel: 10)

@Test func setDiferenteDoEstadoInformadoEhEnviado() {
    var audit = SetAudit()
    #expect(audit.observe(.rx, frame(.noiseControl(ambient), .ret)) == nil)
    #expect(audit.observe(.tx, frame(.noiseControl(cancelling), .set)) == .sent("\(MDRMessage.noiseControl(cancelling))"))
}

@Test func setIgualAoEstadoInformadoEhRedundante() {
    var audit = SetAudit()
    _ = audit.observe(.rx, frame(.noiseControl(ambient), .notify))
    #expect(audit.observe(.tx, frame(.noiseControl(ambient), .set)) == .redundant("\(MDRMessage.noiseControl(ambient))"))
}

@Test func retransmissaoSemAckNaoContaDeNovo() {
    var audit = SetAudit()
    let set = frame(.noiseControl(cancelling), .set)
    #expect(audit.observe(.tx, set) != nil)
    #expect(audit.observe(.tx, set) == nil)
}

@Test func getAckEFrameQuebrado() {
    var audit = SetAudit()
    #expect(audit.observe(.tx, frame(.noiseControl(ambient), .get)) == nil)
    #expect(audit.observe(.tx, MDRFrame.ack(for: 1).encoded()) == nil)
    #expect(audit.observe(.rx, [0x3E, 0x01, 0x02]) == .malformed)
}
