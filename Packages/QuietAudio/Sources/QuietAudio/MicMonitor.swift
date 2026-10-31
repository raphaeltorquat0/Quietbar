import CoreAudio
import Darwin
import Foundation

/// Quem usa uma entrada de áudio agora. Vale para qualquer app de chamada, sem lista de nomes.
public struct MicUsage: Equatable, Sendable {
    /// Alguma entrada real está rodando (`kAudioDevicePropertyDeviceIsRunningSomewhere`).
    public var deviceRunning: Bool
    /// Bundle ID de quem lê a entrada, sem o próprio app. `nil` antes do macOS 14.2, que não informa.
    public var processes: [String]?

    public init(deviceRunning: Bool, processes: [String]?) {
        self.deviceRunning = deviceRunning
        self.processes = processes
    }

    /// `true` com a entrada rodando para alguém que não está na lista de ignorados.
    /// Ignorar um app cobre os auxiliares dele: `com.google.Chrome` pega `com.google.Chrome.helper`.
    public func inCall(ignoring ignored: Set<String>) -> Bool {
        guard deviceRunning else { return false }
        guard let processes else { return true }
        return processes.contains { p in !ignored.contains { p == $0 || p.hasPrefix($0 + ".") } }
    }
}

/// Observa as entradas de áudio. Só lê propriedades: não abre stream nem precisa de permissão.
/// Todas as entradas reais contam, porque um app de chamada pode usar um microfone que não é o padrão.
/// Aggregate e virtual ficam de fora: o aggregate do Som no Mac tem entrada e roda sem haver chamada.
public final class MicMonitor: @unchecked Sendable {
    /// Na main thread, a cada mudança.
    public var onChange: (@MainActor @Sendable (MicUsage) -> Void)?

    private let queue = DispatchQueue(label: "quietaudio.mic") // nada de Core Audio na main (DECISIONS.md #99)
    private var devices: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var poll: DispatchSourceTimer?
    private var last: MicUsage?

    public init() {}

    public func start() {
        queue.async { [self] in
            guard systemListener == nil else { return }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebind() }
            var a = address(kAudioHardwarePropertyDevices)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
            systemListener = block
            rebind()
        }
    }

    public func stop() {
        queue.async { [self] in
            guard let block = systemListener else { return }
            var a = address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
            systemListener = nil
            for id in Array(devices.keys) { unwatch(id) }
            setPolling(false)
            last = nil
        }
    }

    /// Leitura avulsa, para diagnóstico.
    public static func current() -> MicUsage {
        usage(devices: inputDevices())
    }

    private func rebind() {
        let now = Set(Self.inputDevices())
        for id in devices.keys where !now.contains(id) { unwatch(id) }
        for id in now where devices[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            var a = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if AudioObjectAddPropertyListenerBlock(id, &a, queue, block) == noErr { devices[id] = block }
        }
        refresh()
    }

    private func unwatch(_ id: AudioObjectID) {
        guard let block = devices.removeValue(forKey: id) else { return }
        var a = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
    }

    private func refresh() {
        let usage = Self.usage(devices: Array(devices.keys))
        // Com a entrada já rodando para um app ignorado, outro app entrar não muda a propriedade: confere de tempos em tempos.
        setPolling(usage.deviceRunning)
        guard usage != last else { return }
        last = usage
        let onChange = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange?(usage) } }
    }

    private func setPolling(_ on: Bool) {
        guard on != (poll != nil) else { return }
        poll?.cancel()
        poll = nil
        guard on else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        poll = timer
    }

    private static func inputDevices() -> [AudioObjectID] {
        AudioDevices.all().filter {
            let transport: UInt32 = read($0, kAudioDevicePropertyTransportType, default: 0)
            return transport != kAudioDeviceTransportTypeAggregate && transport != kAudioDeviceTransportTypeVirtual
                && channelCount($0, kAudioObjectPropertyScopeInput) > 0
        }
    }

    private static func usage(devices: [AudioObjectID]) -> MicUsage {
        let running = devices.contains { read($0, kAudioDevicePropertyDeviceIsRunningSomewhere, default: UInt32(0)) != 0 }
        guard running else { return MicUsage(deviceRunning: false, processes: []) }
        guard #available(macOS 14.2, *) else { return MicUsage(deviceRunning: true, processes: nil) }
        return MicUsage(deviceRunning: true, processes: processesReadingInput())
    }

    @available(macOS 14.2, *)
    private static func processesReadingInput() -> [String] {
        AudioDevices.processes().compactMap { p in
            let pid: pid_t = read(p, kAudioProcessPropertyPID, default: 0)
            guard pid != getpid(), read(p, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0 else { return nil }
            let id = readString(p, kAudioProcessPropertyBundleID)
            return id.isEmpty ? processName(pid) : id
        }.sorted()
    }

    /// Ferramenta de linha de comando não tem bundle ID.
    private static func processName(_ pid: pid_t) -> String {
        var name = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &name, UInt32(name.count))
        return length > 0 ? String(decoding: name.prefix(Int(length)), as: UTF8.self) : "pid \(pid)"
    }
}
