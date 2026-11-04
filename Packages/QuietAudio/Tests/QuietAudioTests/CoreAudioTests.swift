import Foundation
import Testing
@testable import QuietAudio

/// O Steam Streaming Speakers devolve a saída na entrada: dá para ver o que chegou ao dispositivo
/// sem som audível e sem fone. Sem ele, ou no CI, estes testes são pulados.
private enum Gate {
    static let loopback = "SteamStreamingSpeakers_UID"
    static var hasLoopback: Bool {
        ProcessInfo.processInfo.environment["CI"] == nil && AudioDevices.find(uid: loopback) != nil
    }
    static var cli: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../.build/debug/mdr-cli").standardized
    }
}

@Suite(.serialized, .enabled(if: Gate.hasLoopback, "Precisa de Core Audio real e de um dispositivo com loopback: pulado no CI"))
struct CoreAudioTests {
    private func start(_ args: [String], output: Any = FileHandle.nullDevice) throws -> Process {
        let p = Process()
        p.executableURL = Gate.cli
        p.arguments = ["audio-probe"] + args
        p.standardOutput = output
        try p.run()
        return p
    }

    /// Lê os picos da entrada do loopback até o limite de tempo ou até `until` valer.
    private func level(_ out: URL) -> Double? {
        guard let text = try? String(contentsOf: out, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").dropLast().last?.split(separator: " ").first.flatMap { Double($0) }
    }

    private func wait(_ out: URL, _ condition: (Double) -> Bool) async throws -> Bool {
        for _ in 0..<60 {
            if let l = level(out), condition(l) { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Mata com `kill -9` o processo que segura a tap com mudo: o som tem de voltar sozinho.
    @Test func killedProcessGivesTheAudioBack() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Gate.cli.path), "compile antes: swift build --product mdr-cli")
        let out = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }

        let tone = try start(["--play", Gate.loopback, "--seconds", "20"])
        defer { tone.terminate() }
        let listener = try start(["--listen", Gate.loopback, "--seconds", "20"], output: FileHandle(forWritingTo: out))
        defer { listener.terminate() }
        #expect(try await wait(out) { $0 > 0.09 }, "o tom deveria chegar ao loopback")

        let tap = try start(["--device", Gate.loopback, "--mute", "--hold", "--seconds", "20"])
        defer { tap.terminate() }
        // Com a tap, o que chega é o tom processado (0,063 nesta curva), sem o original somado.
        #expect(try await wait(out) { $0 < 0.08 }, "o mudo deveria tirar o original")

        kill(tap.processIdentifier, SIGKILL)
        tap.waitUntilExit()
        #expect(try await wait(out) { $0 > 0.09 }, "o som deveria voltar sozinho depois do kill -9")
    }

    /// O teste de eco de verdade: com a tap mutando, o original tem de zerar no dispositivo.
    @available(macOS 14.2, *)
    @Test @MainActor func echoTestMeasuresTheLoopback() async throws {
        let device = try #require(AudioDevices.find(uid: Gate.loopback))
        let r = await EchoTest.run(on: device) { _ in }
        #expect(r.baseline > 0.09)
        #expect(r.tapRan)
        #expect(r.verdict == .passed)
    }

    @Test func defaultOutputDescribesItself() throws {
        let d = try #require(AudioDevices.defaultOutput())
        #expect(!d.uid.isEmpty && d.sampleRate > 0)
    }
}
