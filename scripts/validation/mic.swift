// Ferramenta dos experimentos de validação. Abre entradas com o áudio descartado: nada é lido nem guardado.
//   mic hold <builtin|bluetooth> <segundos>
//   mic pattern <builtin|bluetooth> <aberto:fechado>...   ex.: 0.1:5 0.3:5 (segundos; imprime cada abertura em JSONL)
//   mic sample <segundos>                                 uma linha JSONL a cada mudança nas entradas e nos processos
//   mic output                                            taxa e canais da saída padrão (A2DP ou HFP)
import CoreAudio
import Darwin
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(s), v: UInt32 = 0, n = UInt32(4)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &n, &v) == noErr ? v : 0
}
func string(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s), v: Unmanaged<CFString>?, n = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(o, &a, 0, nil, &n, $0) }
    guard status == noErr, let v else { return "" }
    return v.takeRetainedValue() as String
}
func objects(_ s: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = addr(s), n: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &n) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(n) / 4)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &n, &ids)
    return ids
}
func hasInput(_ d: AudioObjectID) -> Bool {
    var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), n: UInt32 = 0
    AudioObjectGetPropertyDataSize(d, &a, 0, nil, &n)
    return n > 0
}
func input(_ kind: String) -> AudioObjectID {
    let want = kind == "bluetooth" ? kAudioDeviceTransportTypeBluetooth : kAudioDeviceTransportTypeBuiltIn
    guard let d = objects(kAudioHardwarePropertyDevices).first(where: { u32($0, kAudioDevicePropertyTransportType) == want && hasInput($0) }) else {
        print("sem entrada \(kind)")
        exit(2)
    }
    return d
}
func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "hold":
    let d = input(args[1])
    var proc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil) { _, _, _, _, _ in }
    AudioDeviceStart(d, proc)
    print("{\"t\":\(now()),\"kind\":\"open\"}")
    Thread.sleep(forTimeInterval: Double(args[2])!)
    AudioDeviceStop(d, proc)
    AudioDeviceDestroyIOProcID(d, proc!)
    print("{\"t\":\(now()),\"kind\":\"close\"}")
case "pattern":
    let d = input(args[1])
    var proc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil) { _, _, _, _, _ in }
    for step in args.dropFirst(2) {
        let p = step.split(separator: ":").map { Double($0)! }
        AudioDeviceStart(d, proc)
        print("{\"t\":\(now()),\"kind\":\"open\",\"step\":\"\(step)\"}")
        Thread.sleep(forTimeInterval: p[0])
        AudioDeviceStop(d, proc)
        print("{\"t\":\(now()),\"kind\":\"close\",\"step\":\"\(step)\"}")
        Thread.sleep(forTimeInterval: p[1])
    }
case "sample":
    var last = ""
    let end = Date().addingTimeInterval(Double(args[1])!)
    while Date() < end {
        let devices = objects(kAudioHardwarePropertyDevices).filter { hasInput($0) && u32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 }
            .map { "\"\(string($0, kAudioObjectPropertyName))\"" }.sorted()
        let procs = objects(kAudioHardwarePropertyProcessObjectList).filter { u32($0, kAudioProcessPropertyIsRunningInput) != 0 }
            .map { "\"\(string($0, kAudioProcessPropertyBundleID))\"" }.sorted()
        let line = "\"devices\":[\(devices.joined(separator: ","))],\"processes\":[\(procs.joined(separator: ","))]"
        if line != last {
            print("{\"t\":\(now()),\"kind\":\"sample\",\(line)}")
            last = line
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
case "output":
    let d: AudioObjectID = {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice), v: UInt32 = 0, n = UInt32(4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &v)
        return v
    }()
    var a = addr(kAudioDevicePropertyNominalSampleRate), rate = 0.0, n = UInt32(8)
    AudioObjectGetPropertyData(d, &a, 0, nil, &n, &rate)
    print("{\"t\":\(now()),\"kind\":\"output\",\"name\":\"\(string(d, kAudioObjectPropertyName))\",\"rate\":\(Int(rate))}")
default:
    print("uso: mic hold|pattern|sample|output")
    exit(2)
}
