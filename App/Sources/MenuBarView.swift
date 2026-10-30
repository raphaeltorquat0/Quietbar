import HeadphoneModel
import MDRKit
import SwiftUI

/// Painel da barra: adapta o `DeviceController` para o `PanelView` (que não conhece o protocolo).
struct MenuBarView: View {
    @Environment(DeviceController.self) private var device
    @Environment(\.openSettings) private var openSettings
    @State private var opened = 0

    var body: some View {
        PanelView(state: DemoPanel.state ?? .from(device), actions: actions, entranceID: opened)
            .keepsChannelOpen()
            .deviceAlerts()
            .onAppear {
                opened += 1
                StatusBar.openSettings = { openSettings() }
            }
    }

    private var actions: PanelActions {
        let d = device
        return PanelActions(
            setMode: { m in d.perform { try await $0.setSoundMode(m) } },
            setAmbient: { v in d.perform { try await $0.setAmbientLevel(v) } },
            setFocusOnVoice: { v in d.perform { try await $0.setFocusOnVoice(v) } },
            setPreset: { id in d.perform { try await $0.setEqualizerPreset(id) } },
            setSpeakToChat: { v in d.perform { try await $0.setSpeakToChat(v) } },
            setDSEE: { v in d.perform { try await $0.setDSEE(v) } },
            previous: { d.perform { try await $0.playback(.previous) } },
            playPause: {
                let playing = d.state.playback?.isPlaying ?? false
                d.perform { try await $0.playback(playing ? .pause : .play) }
            },
            next: { d.perform { try await $0.playback(.next) } },
            setVolume: { v in d.perform { try await $0.setVolume(v) } },
            connect: { Task { await d.connectDevice() } },
            disconnect: { Task { await d.disconnectDevice() } },
            openSettings: { StatusBar.openSettingsWindow() },
            quit: { NSApp.terminate(nil) })
    }
}

extension PanelState {
    @MainActor static func from(_ d: DeviceController) -> PanelState {
        let s = d.state
        var p = PanelState()
        p.name = d.selectedDevice?.name ?? s.modelName ?? String(localized: "Fone")
        p.subtitle = [s.modelName, s.codec.map { "\($0)" }].compactMap { $0 }.joined(separator: " · ")
        p.modelName = s.modelName
        p.link = d.isReady ? .ready : d.isBluetoothConnected ? .bluetoothOnly : .off
        switch d.snapshot.phase {
        case .ready: p.phase = .ready
        case .connecting: p.phase = .loading
        default:
            p.phase = .disconnected(message: d.selectedAddress == nil ? "Nenhum fone pareado. Pareie o fone nos Ajustes do Sistema."
                                    : d.isBluetoothConnected ? "O controle do fone está em pausa." : "O fone não está conectado ao Mac.")
        }
        if let b = s.primaryBattery { p.battery = Int(b.level); p.charging = b.isCharging }
        if s.capabilities.isEarbuds || s.batteryLR != nil {
            let level = { (b: BatteryStatus?) in b.flatMap { $0.level > 0 ? Int($0.level) : nil } }
            p.earbuds = .init(left: level(s.batteryLR?.left), right: level(s.batteryLR?.right), caseLevel: level(s.batteryCase))
        }
        if let n = s.noiseControl {
            p.mode = n.soundMode
            if n.inquiredType == 0x22 { p.modes = [.ambient, .off] } // só ambiente (sem cancelamento)
            p.ambientLevel = Int(n.ambientLevel)
            p.focusOnVoice = n.focusOnVoice
        }
        if let eq = s.equalizer, !s.equalizerPresets.isEmpty {
            p.presets = s.equalizerPresets.map { .init(id: $0.id, name: PresetNames.name($0.id, custom: d.settings.presetNames)) }
            p.presetID = eq.presetID
            // Clear Bass entra como 1º ponto: no XM5 o "Graves realçados" é só Clear Bass, com as bandas em 0.
            p.bands = eq.values
            p.bandsLimit = eq.range.upperBound
        }
        if s.capabilities.speakToChat { p.speakToChat = s.speakToChat ?? false }
        if s.capabilities.dsee {
            p.dsee = s.dsee ?? false
            p.dseeTitle = s.dseeType == 0x03 ? "DSEE Extreme" : "DSEE"
            p.dseeAvailable = s.dseeAvailable != false
        }
        p.showPlayback = s.capabilities.playback
        p.isPlaying = s.playback?.isPlaying ?? false
        p.volume = s.volume.map(Int.init)
        // O fone tem a mensagem de título/artista no protocolo, mas o MDRKit ainda não a decodifica
        // (fora do escopo desta mudança de UI): a linha fica escondida.
        p.nowPlaying = nil
        p.accent = d.settings.ringAccent
        p.use3D = d.settings.popupUse3D
        p.lightRing = d.settings.modelLightRing
        p.customModel = CustomMedia.modelURL
        p.customImage = CustomMedia.image
        return p
    }
}

func batterySymbol(_ level: UInt8) -> String {
    switch level {
    case 0..<13: "battery.0"
    case 13..<38: "battery.25"
    case 38..<63: "battery.50"
    case 63..<88: "battery.75"
    default: "battery.100"
    }
}

