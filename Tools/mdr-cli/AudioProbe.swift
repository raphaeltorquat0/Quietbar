import CoreAudio
import Foundation
import QuietAudio

/// `mdr-cli audio-probe`: mede a tap num dispositivo real, sem app nem fone.
/// Nunca toca no fone por MDR; o som que ela gera vai só para o dispositivo escolhido.
///   audio-probe --device <uid> [--seconds 10] [--mute] [--tone] [--hold]
///   audio-probe --play <uid> [--seconds 10]    toca um tom em outro processo, para a tap capturar
///   audio-probe --echo-test <uid>              teste de eco num dispositivo com loopback
///   audio-probe --permission                   só consulta as permissões; nunca abre diálogo
///   audio-probe --listen <uid> [--seconds 10]  imprime o pico da entrada do dispositivo a cada 100 ms
func runAudioProbe(_ args: [String]) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    func value(_ key: String) -> String? { args.firstIndex(of: key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let seconds = Double(value("--seconds") ?? "") ?? 10

    if let uid = value("--play") {
        guard let d = AudioDevices.find(uid: uid) else { throw CLIError("dispositivo não encontrado") }
        return try playTone(on: d, seconds: seconds)
    }
    if let uid = value("--listen") {
        guard let d = AudioDevices.find(uid: uid) else { throw CLIError("dispositivo não encontrado") }
        return try listen(to: d, seconds: seconds)
    }
    if args.contains("--permission") {
        return print("áudio do sistema: \(SystemPermission.status(.audioCapture)); microfone: \(SystemPermission.status(.microphone))")
    }
    if args.contains("--bench") {
        return print(String(format: "cadeia com 10 filtros: %.3f%% de um núcleo", AudioProbe.offlineLoad() * 100))
    }
    guard #available(macOS 14.2, *) else { throw CLIError("exige macOS 14.2") }
    if let uid = value("--echo-test") {
        guard let d = AudioDevices.find(uid: uid) else { throw CLIError("dispositivo não encontrado") }
        let result = await EchoTest.run(on: d) { print($0) }
        print("veredito: \(result.verdict)")
        return
    }
    guard let uid = value("--device"), let device = AudioDevices.find(uid: uid) else {
        throw CLIError("use --device <uid>; a sonda não escolhe sozinha para não mutar a saída em uso")
    }
    print("dispositivo: \(device.name) \(device.sampleRate) Hz \(device.channels) canais")

    let report = await AudioProbe.measure(device, seconds: seconds, mute: args.contains("--mute"),
                                          tone: args.contains("--tone"), hold: args.contains("--hold"), trace: args.contains("--timeline")) { print($0) }
    if !report { throw CLIError("a tap não processou áudio") }
}

/// Tom de 1 kHz a -20 dBFS direto no dispositivo.
private func playTone(on device: OutputDevice, seconds: Double) throws {
    final class Phase: @unchecked Sendable { var value = 0.0 }
    let phase = Phase()
    let step = 2 * Double.pi * 1000 / device.sampleRate
    var proc: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, nil) { _, _, _, out, _ in
        for b in UnsafeMutableAudioBufferListPointer(out) {
            let ch = Int(b.mNumberChannels), n = Int(b.mDataByteSize) / 4 / max(ch, 1)
            let p = b.mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                let v = Float(0.1 * sin(phase.value))
                phase.value += step
                for c in 0..<ch { p[i * ch + c] = v }
            }
        }
    }
    guard status == noErr else { throw CLIError("IOProc \(status)") }
    AudioDeviceStart(device.id, proc)
    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(device.id, proc)
    AudioDeviceDestroyIOProcID(device.id, proc!)
}

/// Pico da entrada do dispositivo: num dispositivo com loopback, é o que realmente chegou à saída.
private func listen(to device: OutputDevice, seconds: Double) throws {
    final class Peak: @unchecked Sendable { var value: Float = 0; var calls = 0 }
    let peak = Peak()
    var proc: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, nil) { _, input, _, _, _ in
        peak.calls += 1
        for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<Int(b.mDataByteSize) / 4 { peak.value = max(peak.value, abs(p[i])) }
        }
    }
    guard status == noErr else { throw CLIError("IOProc \(status)") }
    AudioDeviceStart(device.id, proc)
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        Thread.sleep(forTimeInterval: 0.1)
        print(String(format: "%.3f calls=%d", peak.value, peak.calls))
        fflush(stdout)
        peak.value = 0
    }
    AudioDeviceStop(device.id, proc)
    AudioDeviceDestroyIOProcID(device.id, proc!)
}
