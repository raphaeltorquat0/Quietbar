import Testing
@testable import MDRKit

/// Frames reais recebidos de um WF-1000XM5 fw 6.1.0 (MDR v2), de [M] `tests/WF-1000XM5-6.1.0/`.
enum Captured {
    static let ack = "3e010100000000023c"
    static let protocolInfo = "3e0c01000000080100030030180000613c"
    static let capabilityInfo = "3e0c000000001503000b1130323a30303a30303a44323a42303a3536d73c" // endereço trocado por um falso
    static let firmware = "3e0c0100000008050205362e312e30143c"
    static let model = "3e0c000000000d05010a57462d31303030584d358e3c"
    static let series = "3e0c0100000004050330034c3c"
    static let supportT1 = "3e0c000000005f07002e10ff12ff13ff14ff15ff16ff17ff23ff253611ff27ff29ff2aff92ff50116b08700190ffa112c1ffc2ffe21bf138fc0d93fff633f941d13b94ff402e423a44ffff2d19fff326e71ad220fd2bb61db042b243b81fb715343ff423f524293c"
    static let supportT2 = "3e0e010000001907000b423d2d53ff54fff1ff60ff61fff2ff63fff830320431ffee3c"
    static let gsCapability = "3e0c000000002ed1d100011053494445544f4e455f53455454494e471853494445544f4e455f53455454494e475f53554d4d415259423c"
    static let gsParam = "3e0c0100000004d7d10001ba3c"
    static let multipointCapability = "3e0c0000000041d1d20001124d554c5449504f494e545f53455454494e47294d554c5449504f494e545f53455454494e475f53554d4d4152595f4c4441435f415641494c41424c45303c"
    static let multipointParam = "3e0c0100000004d7d20000ba3c"
    static let dseeType = "3e0c0000000003e10102f33c"
    static let codec = "3e0c0100000003130202273c"
    static let volume = "3e0c0100000003a7200ce33c"
    static let playback = "3e0c0000000005a301000200b73c"
    static let noiseControl = "3e0c010000000767170100010014a83c"
    static let speakToChat = "3e0c0000000004f70c0101153c"
    static let speakToChatConfig = "3e0c0100000004fb0c0000183c"
    static let eqAvailable = "3e0c0000000003530000623c"
    static let eqParam = "3e0c010000000a5700a006140b0a0d090c5f3c"
    static let dseeAvailable = "3e0c0000000003e30100f33c"
    static let dsee = "3e0c0100000003e70101f93c"
    static let assignable = "3e0c0000000005f703023520623c"
    static let autoPowerOff = "3e0c0000000004270510004c3c"
    static let autoPause = "3e0c0100000003f70100083c"
}

extension [UInt8] {
    init(hex: String) {
        self = stride(from: 0, to: hex.count, by: 2).map {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[i...hex.index(after: i)], radix: 16)!
        }
    }
}

@Suite struct FramingTests {
    @Test func realAck() throws {
        let f = try MDRFrame(decoding: [UInt8](hex: Captured.ack))
        #expect(f == MDRFrame(type: .ack, seq: 1))
        #expect(MDRFrame.ack(for: 0).encoded() == [UInt8](hex: Captured.ack))
    }

    @Test func realFramesRoundTrip() throws {
        let all = [Captured.protocolInfo, Captured.capabilityInfo, Captured.supportT1, Captured.supportT2,
                   Captured.gsCapability, Captured.eqParam, Captured.noiseControl, Captured.autoPowerOff]
        for hex in all {
            let raw = [UInt8](hex: hex)
            let f = try MDRFrame(decoding: raw)
            #expect(f.encoded() == raw, "re-encode de \(hex)")
        }
    }

    @Test func checksumIsSumOfUnescapedBody() {
        let f = MDRFrame(type: .mdr, seq: 0, payload: [0x00, 0x00])
        // 0x0C + 0 + len(2) = 0x0E
        #expect(f.encoded() == [0x3E, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x0E, 0x3C])
    }

    @Test func escapesSpecialBytes() throws {
        let f = MDRFrame(type: .mdr, seq: 1, payload: [0x3C, 0x3D, 0x3E, 0x41])
        let raw = f.encoded()
        let inner = raw.dropFirst().dropLast()
        #expect(!inner.contains(0x3C) && !inner.contains(0x3E))
        #expect(Array(raw[7...12]) == [0x3D, 0x2C, 0x3D, 0x2D, 0x3D, 0x2E])
        #expect(try MDRFrame(decoding: raw) == f)
    }

    @Test func escapedChecksum() throws {
        // payload [0x2F] → checksum 0x0C+0+1+0x2F = 0x3C, que precisa de escape.
        let raw = MDRFrame(type: .mdr, seq: 0, payload: [0x2F]).encoded()
        #expect(Array(raw.suffix(3)) == [0x3D, 0x2C, 0x3C])
        #expect(try MDRFrame(decoding: raw).payload == [0x2F])
    }

    @Test func rejectsCorruption() {
        var raw = [UInt8](hex: Captured.codec)
        raw[8] ^= 0x01
        #expect(throws: MDRFrameError.self) { try MDRFrame(decoding: raw) }
        #expect(throws: MDRFrameError.badMarker) { try MDRFrame(decoding: Array(raw.dropLast())) }
        #expect(throws: MDRFrameError.badEscape) { try MDRFrame(decoding: [0x3E, 0x3D, 0x10, 0x3C]) }
    }

    @Test func parserHandlesSplitAndGluedChunks() throws {
        let a = [UInt8](hex: Captured.ack), b = [UInt8](hex: Captured.codec)
        var p = MDRFrameParser()
        let stream = [0x00, 0x11] + a + b // lixo antes do primeiro frame
        var frames: [MDRFrame] = []
        for chunk in stride(from: 0, to: stream.count, by: 5).map({ Array(stream[$0..<min($0 + 5, stream.count)]) }) {
            frames += try p.push(chunk).map { try $0.get() }
        }
        #expect(frames.map(\.type) == [.ack, .mdr])
        #expect(frames[1].payload == [0x13, 0x02, 0x02])
    }

    @Test func parserSkipsBadFrameAndContinues() {
        var bad = [UInt8](hex: Captured.codec)
        bad[9] ^= 0xFF
        var p = MDRFrameParser()
        let out = p.push(bad + [UInt8](hex: Captured.ack))
        #expect(out.count == 2)
        #expect((try? out[0].get()) == nil)
        #expect((try? out[1].get())?.type == .ack)
    }
}
