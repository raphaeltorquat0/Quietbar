import AppKit
import CoreAudio
import IOBluetooth
import MDRKit
import MDRSession
#if DEBUG
import MDRSimulator
#endif
import MDRTransport
import Observation
import UserNotifications

/// Dono da sessão do app. Abre o canal sob demanda e o libera depois de `idleRelease` sem UI aberta,
/// para não disputar com o Sound Connect do celular em multiponto.
@MainActor @Observable
final class DeviceController {
    static let shared = DeviceController()

    private(set) var snapshot = MDRSession.Snapshot(phase: .disconnected, state: MDRDeviceState())
    private(set) var devices: [PairedDevice] = []
    var lastError: String?
    /// Última bateria lida; o canal é solto 15 s após fechar a UI, mas o ícone continua mostrando o valor.
    private(set) var lastBattery: BatteryStatus?

    var state: MDRDeviceState { snapshot.state }
    var isReady: Bool { snapshot.phase == .ready }
    var isBluetoothConnected: Bool { simulating || selectedDevice?.isConnected ?? false }
    var isBatteryLow: Bool { lastBattery.map { Int($0.level) <= settings.lowBatteryThreshold && !$0.isCharging } ?? false }
    var selectedDevice: PairedDevice? { simulating ? nil : devices.first { $0.address == selectedAddress } }

    var selectedAddress: String? {
        didSet {
            UserDefaults.standard.set(selectedAddress, forKey: "selectedAddress")
            if oldValue != selectedAddress {
                MacSound.shared.targetChanged(selectedAddress)
                Automation.shared.engine.forgetDevice()
                Task { await reset() }
            }
        }
    }

    @ObservationIgnored let settings = AppSettings.shared
    @ObservationIgnored private var session: MDRSession?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var batteryTimer: Timer?
    @ObservationIgnored private var visible = 0
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var lowBatteryNotified = false
    @ObservationIgnored private let watcher = BluetoothWatcher()

    private init() {
        selectedAddress = UserDefaults.standard.string(forKey: "selectedAddress")
        refreshDevices()
        if selectedAddress == nil { selectedAddress = BluetoothDevices.preferredSony(among: devices)?.address }
        observeSystem()
        scheduleBatteryCheck()
    }

    func refreshDevices() {
        devices = BluetoothDevices.paired().filter {
            $0.hasMDRService || BluetoothDevices.looksLikeSony($0.name) || $0.address == selectedAddress
        }
    }

    // MARK: - Visibilidade

    func uiAppeared() {
        visible += 1
        idleTask?.cancel()
        refreshDevices()
        Task { await ensureConnected() }
    }

    func uiDisappeared() {
        visible = max(0, visible - 1)
        if visible == 0 { scheduleRelease() }
    }

    private func scheduleRelease() {
        idleTask?.cancel()
        let delay = Duration.seconds(settings.idleReleaseSeconds)
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.visible == 0 else { return }
            await self.session?.disconnect()
        }
    }

    // MARK: - Sessão

    func ensureConnected() async {
        if isReady { return }
        if let connecting { return await connecting.value }
        let t = Task { await connect() }
        connecting = t
        await t.value
        connecting = nil
    }

    /// `true` só em Debug, com um fone simulado ativo: não há Bluetooth envolvido.
    private var simulating: Bool {
        #if DEBUG
        Simulation.shared.transport != nil
        #else
        false
        #endif
    }

    private func connect() async {
        guard simulating || selectedAddress != nil else {
            lastError = "Nenhum fone Sony pareado. Pareie o fone nos Ajustes do Sistema."
            return
        }
        guard simulating || BluetoothDevices.isConnected(selectedAddress ?? "") else {
            lastError = "O fone não está conectado ao Mac."
            return
        }
        let s = session ?? makeSession(selectedAddress ?? "")
        do {
            try await s.connect()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "Conectar" do painel e do menu: pede a conexão Bluetooth se o fone não estiver ligado ao Mac,
    /// depois abre o canal MDR.
    func connectDevice() async {
        guard !simulating, let address = selectedAddress else { return await ensureConnected() }
        if !BluetoothDevices.isConnected(address) {
            lastError = nil
            snapshot = MDRSession.Snapshot(phase: .connecting, state: snapshot.state)
            let ok = await BluetoothDevices.connect(address)
            refreshDevices()
            if !ok {
                snapshot = MDRSession.Snapshot(phase: .disconnected, state: snapshot.state)
                lastError = "O macOS não conseguiu conectar o fone. Ele está ligado e por perto?"
                return
            }
            try? await Task.sleep(for: .seconds(1)) // o serviço RFCOMM sobe logo depois do baseband
        }
        await ensureConnected()
    }

    /// "Desconectar" do menu: solta o canal e a conexão Bluetooth do fone com o Mac.
    func disconnectDevice() async {
        await session?.disconnect()
        if !simulating, let a = selectedAddress { BluetoothDevices.disconnect(a) }
        refreshDevices()
    }

    private func makeSession(_ address: String) -> MDRSession {
        let toFile = settings.logTraffic
        #if DEBUG
        let channel: any MDRChannel = Simulation.shared.transport ?? RFCOMMChannel(address: address)
        #else
        let channel: any MDRChannel = RFCOMMChannel(address: address)
        #endif
        let s = MDRSession(channel: channel, traffic: { dir, bytes in
            if toFile { TrafficLog.append(dir, bytes) }
            Task { @MainActor in ProtocolLog.shared.add(dir, bytes) }
        })
        session = s
        observer?.cancel()
        observer = Task { [weak self] in
            for await snap in await s.snapshots() { self?.received(snap) }
        }
        return s
    }

    #if DEBUG
    /// Troca entre Bluetooth e fone simulado.
    func restartSession() async { await reset() }

    /// O Mac reage ao cenário pelo mesmo caminho dos eventos reais.
    func simulated(_ event: HostEvent) async {
        switch event {
        case .connectionLost: break
        case .connectionRestored, .didWake: if visible > 0 { await ensureConnected() }
        case .willSleep: await session?.disconnect()
        }
    }
    #endif

    private func reset() async {
        idleTask?.cancel()
        observer?.cancel()
        await session?.disconnect()
        session = nil
        snapshot = MDRSession.Snapshot(phase: .disconnected, state: MDRDeviceState())
        if visible > 0 { await ensureConnected() }
    }

    /// Executa uma ação no fone: conecta se preciso e, sem UI aberta, solta o canal depois.
    func perform(_ action: @escaping @Sendable (MDRSession) async throws -> Void) {
        let task = enqueue(action)
        Task {
            do { try await task.value } catch is NotConnected {} catch { lastError = error.localizedDescription }
        }
    }

    /// Como `perform`, para quem precisa do resultado: Atalhos e o motor de automação.
    func run<T: Sendable>(_ action: @escaping @Sendable (MDRSession) async throws -> T) async throws -> T {
        try await enqueue(action).value
    }

    /// Único caminho de escrita no fone: uma ação de cada vez, na ordem em que chegaram. Os `set` partem do
    /// último estado lido, então duas ações juntas podiam desfazer uma à outra.
    private func enqueue<T: Sendable>(_ action: @escaping @Sendable (MDRSession) async throws -> T) -> Task<T, Error> {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            idleTask?.cancel() // a liberação por ociosidade fecharia o canal no meio da ação
            await ensureConnected()
            guard isReady, let session else { throw NotConnected() }
            defer { if visible == 0 { scheduleRelease() } }
            return try await action(session)
        }
        tail = Task { _ = await task.result }
        return task
    }

    private func received(_ snap: MDRSession.Snapshot) {
        snapshot = snap
        #if DEBUG
        HardwareTest.log()
        #endif
        if let b = snap.state.primaryBattery { lastBattery = b }
        checkBattery(snap.state.primaryBattery)
        Automation.shared.report()
    }

    // MARK: - Bateria

    private func checkBattery(_ b: BatteryStatus?) {
        guard let b, settings.lowBatteryAlert else { return }
        if Int(b.level) > settings.lowBatteryThreshold || b.isCharging {
            lowBatteryNotified = false
        } else if !lowBatteryNotified {
            lowBatteryNotified = true
            Notifier.post(title: "Bateria fraca no \(state.modelName ?? "fone")", body: "Restam \(b.level)%.")
        }
    }

    /// Com a UI fechada o canal fica solto; de tempos em tempos abre só para ler a bateria.
    func scheduleBatteryCheck() {
        batteryTimer?.invalidate()
        guard settings.lowBatteryAlert else { return }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.batteryCheckMinutes * 60), repeats: true) { _ in
            MainActor.assumeIsolated {
                let c = DeviceController.shared
                guard c.visible == 0, !c.isReady, let a = c.selectedAddress, BluetoothDevices.isConnected(a) else { return }
                c.perform { _ in }
            }
        }
    }

    // MARK: - Sistema: sleep/wake, Bluetooth, saída de áudio

    private func observeSystem() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Task { await DeviceController.shared.session?.disconnect() } }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let c = DeviceController.shared
                Task {
                    try? await Task.sleep(for: .seconds(3)) // o Bluetooth volta alguns segundos depois do wake
                    if c.visible > 0 { await c.ensureConnected() }
                    // Sem aviso de conexão, porque o link não caiu, uma transição pendente ficaria presa.
                    Automation.shared.engine.deviceAvailable()
                }
            }
        }
        watcher.onChange = { [weak self] address, connected in
            guard let self, address == self.selectedAddress else { return }
            self.refreshDevices()
            if connected, self.visible > 0 { Task { await self.ensureConnected() } }
            if connected { PopupController.shared.deviceConnected() }
            if connected {
                Task {
                    try? await Task.sleep(for: .seconds(2)) // o serviço RFCOMM sobe logo depois do baseband
                    Automation.shared.engine.deviceAvailable()
                }
            }
            if !connected { Task { await self.session?.disconnect() } }
        }
        watcher.start()

        // Troca do dispositivo de saída: o codec pode mudar (ex.: fone virou saída de novo).
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
            MainActor.assumeIsolated {
                let c = DeviceController.shared
                guard c.isReady, let s = c.session else { return }
                Task { try? await s.send(.codec) }
            }
        }
    }
}

struct NotConnected: LocalizedError {
    var errorDescription: String? { String(localized: "O fone não está conectado.") }
}

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Log de tráfego em `~/Library/Logs/Quietbar/traffic.log`: tempo monotônico em ms, hora e o frame como no
/// `mdr-cli --log-hex`. Só o monotônico ordena frames de uma sessão: a hora tem resolução de 1 s e pode ser ajustada.
enum TrafficLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Quietbar/traffic.log")

    @Sendable static func append(_ dir: MDRSession.Direction, _ bytes: [UInt8]) {
        let ms = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000
        let line = "\(ms) \(Date().ISO8601Format()) \(dir == .tx ? ">>" : "<<") \(bytes.hex)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
