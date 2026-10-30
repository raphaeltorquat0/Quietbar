import CoreAudio
import CQuietAudio
import Foundation

public protocol AudioBackend: AnyObject {
    /// Roda os comandos em ordem, fora da main thread. Falhas voltam por `onFailure`.
    func perform(_ command: AudioCommand)
    /// Última saída conhecida; nunca bloqueia, porque não fala com o `coreaudiod`.
    func currentOutput() -> OutputDevice?
    var onFailure: (@MainActor @Sendable (String) -> Void)? { get set }
    var onOutputChange: (@MainActor @Sendable () -> Void)? { get set }
}

struct AudioFailure: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) (\(status))" }
}

private func check(_ what: String, _ status: OSStatus) throws {
    if status != noErr { throw AudioFailure(what: what, status: status) }
}

private func address(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
    var a = address(selector, scope)
    var size = UInt32(MemoryLayout<T>.size)
    var out = value
    let status = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
    return status == noErr ? out : value
}

private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var a = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var out: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
    guard status == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

/// Canais somados de todos os streams no escopo pedido.
private func channelCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}

public enum AudioDevices {
    public static func describe(_ id: AudioObjectID) -> OutputDevice {
        OutputDevice(id: id, uid: readString(id, kAudioDevicePropertyDeviceUID), name: readString(id, kAudioObjectPropertyName),
                     sampleRate: read(id, kAudioDevicePropertyNominalSampleRate, default: 0.0),
                     channels: channelCount(id, kAudioObjectPropertyScopeOutput))
    }

    public static func defaultOutput() -> OutputDevice? {
        let id: AudioObjectID = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: 0)
        return id == 0 ? nil : describe(id)
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(selector)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    public static func find(uid: String) -> OutputDevice? {
        objects(kAudioHardwarePropertyDevices).lazy.map(describe).first { $0.uid == uid }
    }

    /// Dispositivos virtuais com entrada e saída: candidatos a loopback para o teste de eco.
    public static func virtualDuplex() -> [OutputDevice] {
        objects(kAudioHardwarePropertyDevices).filter {
            read($0, kAudioDevicePropertyTransportType, default: UInt32(0)) == kAudioDeviceTransportTypeVirtual
                && channelCount($0, kAudioObjectPropertyScopeInput) > 0 && channelCount($0, kAudioObjectPropertyScopeOutput) > 0
        }.map(describe)
    }

    /// Bundle IDs dos outros apps com a saída de áudio aberta. `nil` se o sistema não respondeu:
    /// quem decide pedir a permissão trata isso como "pode haver áudio".
    public static func playingApps() -> [String]? {
        let processes = objects(kAudioHardwarePropertyProcessObjectList)
        guard !processes.isEmpty else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return processes.filter {
            read($0, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 && read($0, kAudioProcessPropertyPID, default: pid_t(0)) != me
        }.map { readString($0, kAudioProcessPropertyBundleID) }
    }
}

/// Tap escopada no dispositivo + aggregate privado + IOProc. Só `arm` silencia o original.
@available(macOS 14.2, *)
public final class CoreAudioBackend: AudioBackend, @unchecked Sendable {
    public var onFailure: (@MainActor @Sendable (String) -> Void)?
    public var onOutputChange: (@MainActor @Sendable () -> Void)?

    /// Buffer pedido ao aggregate: 256 quadros a 48 kHz são 5,3 ms.
    public var bufferFrames: UInt32 = 256
    /// Quadros reais do buffer, depois que o HAL arredonda.
    public private(set) var grantedBufferFrames: UInt32 = 0
    /// Canais do aggregate e da tap, para a aba Desenvolvedor.
    public private(set) var routing = ""

    /// Só o teste de eco: a tap inclui o próprio processo, que é quem toca o tom.
    public var tapsOwnProcess = false

    private let chain: DSPChain
    private let queue = DispatchQueue(label: "quietaudio.backend")
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var description: CATapDescription?
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var armed = false
    private var watched = AudioObjectID(kAudioObjectUnknown)
    private let lock = NSLock()
    private var output: OutputDevice?
    private let fadeTime: useconds_t = 35_000

    /// Nada de Core Audio na main thread: com o pedido de permissão aberto, o `coreaudiod` não atende
    /// clientes novos, e uma chamada aqui congelaria o app até o usuário responder.
    public init(chain: DSPChain) {
        self.chain = chain
        queue.async { [self] in
            var a = address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue) { [weak self] _, _ in
                self?.outputChanged()
            }
            outputChanged()
        }
    }

    public func currentOutput() -> OutputDevice? { lock.withLock { output } }

    public func perform(_ command: AudioCommand) {
        queue.async { [self] in
            do {
                switch command {
                case .mount(let device): try mount(device)
                case .arm: try setMuted(true); chain.setFade(open: true)
                case .disarm:
                    chain.setFade(open: false)
                    usleep(fadeTime)
                    try setMuted(false)
                case .unmount: unmount()
                }
            } catch {
                unmount()
                let message = error.localizedDescription
                let report = onFailure
                Task { @MainActor in report?(message) }
            }
        }
    }

    /// Muta o original sem abrir a saída processada.
    public func muteOriginal() {
        queue.async { [self] in try? setMuted(true) }
    }

    // MARK: Observar a saída

    private func outputChanged() {
        watchDefaultOutput()
        let current = AudioDevices.defaultOutput()
        lock.withLock { output = current }
        let report = onOutputChange
        Task { @MainActor in report?() }
    }

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// Taxa e canais mudam no mesmo dispositivo: é assim que o Bluetooth entra e sai do modo chamada.
    private func watchDefaultOutput() {
        let id: AudioObjectID = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: 0)
        guard id != watched else { return }
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        ]
        if watched != 0, let block = listenerBlock {
            for (s, scope) in selectors {
                var a = address(s, scope)
                AudioObjectRemovePropertyListenerBlock(watched, &a, queue, block)
            }
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputChanged() }
        listenerBlock = block
        watched = id
        guard id != 0 else { return }
        for (s, scope) in selectors {
            var a = address(s, scope)
            AudioObjectAddPropertyListenerBlock(id, &a, queue, block)
        }
    }

    // MARK: Montar e desmontar

    private func mount(_ device: OutputDevice) throws {
        unmount()
        let pid = ProcessInfo.processInfo.processIdentifier
        var process = AudioObjectID(kAudioObjectUnknown)
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var input = pid
        try check("processo", AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                                                         UInt32(MemoryLayout<pid_t>.size), &input, &size, &process))

        // Escopada no dispositivo: se a saída mudar, o áudio que vai para outro lugar nem passa pela tap.
        // O próprio processo fica de fora, ou o Mac ouviria (e mutaria) o som que este app toca.
        let d = CATapDescription(__excludingProcesses: tapsOwnProcess ? [] : [NSNumber(value: process)], andDeviceUID: device.uid, withStream: 0)
        d.name = "Quietbar"
        // Privada de propósito: tap pública sobrevive à morte do processo (testado), e aí o mudo ficaria.
        d.isPrivate = true
        d.muteBehavior = .unmuted
        try check("tap", AudioHardwareCreateProcessTap(d, &tap))
        description = d

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Quietbar",
            kAudioAggregateDeviceUIDKey: "io.github.raphaeltorquat0.Quietbar.aggregate.\(pid).\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: d.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check("aggregate", AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate))

        // A tap vem depois das entradas do próprio dispositivo; o Bluetooth de saída não tem nenhuma.
        var format = AudioStreamBasicDescription()
        format = read(tap, kAudioTapPropertyFormat, default: format)
        let inputs = channelCount(aggregate, kAudioObjectPropertyScopeInput), tapChannels = Int(format.mChannelsPerFrame)
        let safety: UInt32 = read(aggregate, kAudioDevicePropertySafetyOffset, default: 0, scope: kAudioObjectPropertyScopeOutput)
        let safetyIn: UInt32 = read(aggregate, kAudioDevicePropertySafetyOffset, default: 0, scope: kAudioObjectPropertyScopeInput)
        routing = "aggregate: \(inputs) entradas, \(channelCount(aggregate, kAudioObjectPropertyScopeOutput)) saídas; tap: \(tapChannels) canais a \(format.mSampleRate) Hz; safety offset: \(safetyIn) entrada, \(safety) saída"
        chain.reset(sampleRate: device.sampleRate, inputChannelOffset: max(0, inputs - tapChannels))

        let rate: Double = read(aggregate, kAudioDevicePropertyNominalSampleRate, default: 0)
        guard rate == device.sampleRate else { throw AudioFailure(what: "taxa do aggregate \(rate)", status: 0) }

        var frames = bufferFrames
        var bufferAddress = address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(aggregate, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        grantedBufferFrames = read(aggregate, kAudioDevicePropertyBufferFrameSize, default: 0)

        try check("IOProc", AudioDeviceCreateIOProcID(aggregate, qa_io_proc, UnsafeMutableRawPointer(chain.raw), &ioProc))
        try check("início", AudioDeviceStart(aggregate, ioProc))
    }

    private func setMuted(_ muted: Bool) throws {
        guard let description, tap != kAudioObjectUnknown else { return }
        description.muteBehavior = muted ? .muted : .unmuted
        var a = address(kAudioTapPropertyDescription)
        var ref = Unmanaged.passUnretained(description).toOpaque()
        try check("mudo", AudioObjectSetPropertyData(tap, &a, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref))
        armed = muted
    }

    private func unmount() {
        if armed { try? setMuted(false) } // o original volta primeiro: nunca há um instante sem som
        chain.setFade(open: false)
        if ioProc != nil { usleep(fadeTime) }
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        description = nil
        armed = false
    }
}
