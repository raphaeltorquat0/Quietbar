import Foundation
import MDRKit
import MDRSession
import Testing
@testable import MDRSimulator

/// As capturas reais sanitizadas são o contrato: o que o fone mandou tem que passar intacto.
@Suite struct ContractTests {
    @Test(arguments: Fixtures.names)
    func everyFrameRoundTripsByteForByte(_ name: String) throws {
        let frames = try Fixtures.frames(name)
        #expect(!frames.isEmpty)
        for (_, raw) in frames { #expect(try MDRFrame(decoding: raw).encoded() == raw) }
    }

    @Test(arguments: Fixtures.names)
    func parserRebuildsTheStreamOneByteAtATime(_ name: String) throws {
        let frames = try Fixtures.frames(name).map(\.1)
        var parser = MDRFrameParser(), rebuilt: [[UInt8]] = []
        for byte in frames.joined() {
            for case .success(let f) in parser.push([byte]) { rebuilt.append(f.encoded()) }
        }
        #expect(rebuilt == frames)
    }

    /// Tudo o que o MDRKit decodifica volta aos mesmos bytes. A exceção são ajustes gerais que não
    /// são liga/desliga: o MDRKit não modela a lista de opções, e o app só mostra os booleanos.
    @Test(arguments: Fixtures.names)
    func decodedMessagesReencodeToTheSameBytes(_ name: String) throws {
        var nonBoolean: Set<UInt8> = []
        for (_, raw) in try Fixtures.frames(name) {
            let f = try MDRFrame(decoding: raw)
            let table: MDRTable = f.type == .mdrNo2 ? .t2 : .t1
            guard f.type == .mdr || f.type == .mdrNo2,
                  let (verb, message) = MDRMessage.decode(f.payload, table: table) else { continue }
            if case .generalSettingCapability(let c) = message, !c.isBoolean { nonBoolean.insert(c.inquiredType); continue }
            if case .generalSetting(let type, _) = message, nonBoolean.contains(type) { continue }
            #expect(message.command(verb).payload == f.payload, "\(message)")
        }
    }

    /// Replay: o fone virtual responde com o payload exato que o fone real mandou.
    @Test(arguments: Profiles.all.filter(\.isCapture).map(\.id))
    func capturedProfileAnswersWithTheRecordedBytes(_ id: String) throws {
        let profile = try #require(Profiles.find(id))
        guard case .capture(let fixtures, _) = profile.origin else { return }
        let device = VirtualDevice(profile: profile)
        var last: [String: ([UInt8], MDRTable)] = [:]
        for name in fixtures {
            for (direction, raw) in try Fixtures.frames(name) where direction == "rx" {
                let f = try MDRFrame(decoding: raw)
                guard f.type == .mdr || f.type == .mdrNo2, f.payload.count >= 2,
                      let get = VirtualDevice.getCode(for: f.payload[0]) else { continue }
                let table: MDRTable = f.type == .mdr ? .t1 : .t2
                last["\(table)-\(get)-\(f.payload[1])"] = (f.payload, table)
            }
        }
        #expect(!last.isEmpty)
        for (payload, table) in last.values {
            let get = VirtualDevice.getCode(for: payload[0])!
            #expect(device.answer(to: MDRCommand([get, payload[1]], table: table)) == payload)
        }
    }

    /// A sessão consome a captura inteira, sem alterar um byte do que chegou.
    @Test(arguments: Profiles.all.filter(\.isCapture).map(\.id))
    func sessionReplaysTheCapture(_ id: String) async throws {
        let profile = try #require(Profiles.find(id))
        guard case .capture(let fixtures, _) = profile.origin else { return }
        let seen = Seen()
        let t = VirtualTransport(profile: profile)
        let s = MDRSession(channel: t, options: fastOptions(), traffic: { d, b in if d == .rx { seen.add(b) } })
        try await s.connect()
        seen.clear()
        var expected: [[UInt8]] = []
        for name in fixtures {
            for (direction, raw) in try Fixtures.frames(name) where direction == "rx" {
                expected.append(raw)
                await t.emit(raw: raw)
            }
        }
        #expect(await eventually(s) { _ in seen.count >= expected.count })
        #expect(seen.all == expected)
        #expect(await s.state.modelName == profile.modelName)
        #expect(await s.phase == .ready)
    }

    @Test func generatedSwiftMatchesTheFixtures() throws {
        #expect(Set(CapturedFrames.all.keys) == Set(Fixtures.names))
        for name in Fixtures.names {
            let lines = try Fixtures.text(name).split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)
            #expect(CapturedFrames.all[name] == lines)
        }
    }

    /// Só endereços falsos: `02:00:00` é um prefixo administrado localmente.
    @Test(arguments: Fixtures.names)
    func fixturesHaveNoRealAddress(_ name: String) throws {
        let mac = try Regex("[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}")
        for (_, raw) in try Fixtures.frames(name) {
            let text = String(decoding: try MDRFrame(decoding: raw).payload.filter { (0x20...0x7E).contains($0) }, as: UTF8.self)
            for m in text.matches(of: mac) { #expect(text[m.range].hasPrefix("02:00:00:")) }
        }
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[UInt8]] = []
    func add(_ b: [UInt8]) { lock.withLock { frames.append(b) } }
    func clear() { lock.withLock { frames = [] } }
    var count: Int { lock.withLock { frames.count } }
    var all: [[UInt8]] { lock.withLock { frames } }
}
