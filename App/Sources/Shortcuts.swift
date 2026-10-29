import AppKit
import Carbon.HIToolbox
import MDRKit
import MDRSession
import SwiftUI

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case toggleNcAmbient, cycleMode, noiseCanceling, ambient, off, focusOnVoice, playPause, showPopup

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggleNcAmbient: "Alternar Cancelamento / Ambiente"
        case .cycleMode: "Ciclar Cancelamento → Ambiente → Desligado"
        case .noiseCanceling: "Cancelamento de ruído"
        case .ambient: "Som ambiente"
        case .off: "Desligar controle de som"
        case .focusOnVoice: "Alternar Focus on Voice"
        case .playPause: "Play / pausa"
        case .showPopup: "Mostrar o popup do fone"
        }
    }

    @MainActor func run(_ device: DeviceController) {
        if self == .showPopup { return PopupController.shared.present() }
        device.perform { s in
            let st = await s.state
            let mode = st.noiseControl?.soundMode
            switch self {
            case .toggleNcAmbient: try await s.setSoundMode(mode == .noiseCanceling ? .ambient : .noiseCanceling)
            case .cycleMode:
                let all = SoundMode.allCases
                try await s.setSoundMode(all[((mode.flatMap { all.firstIndex(of: $0) } ?? -1) + 1) % all.count])
            case .noiseCanceling: try await s.setSoundMode(.noiseCanceling)
            case .ambient: try await s.setSoundMode(.ambient)
            case .off: try await s.setSoundMode(.off)
            case .focusOnVoice: try await s.setNoiseControl { $0.soundMode = .ambient; $0.focusOnVoice.toggle() }
            case .playPause: try await s.playback(st.playback?.isPlaying == true ? .pause : .play)
            case .showPopup: break
            }
        }
    }
}

struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        var s = ""
        if f.contains(.control) { m |= UInt32(controlKey); s += "⌃" }
        if f.contains(.option) { m |= UInt32(optionKey); s += "⌥" }
        if f.contains(.shift) { m |= UInt32(shiftKey); s += "⇧" }
        if f.contains(.command) { m |= UInt32(cmdKey); s += "⌘" }
        guard m != 0 else { return nil } // atalho global sem modificador sequestraria a tecla
        keyCode = UInt32(event.keyCode)
        carbonModifiers = m
        display = s + (event.charactersIgnoringModifiers?.uppercased() ?? "?")
    }
}

@MainActor @Observable
final class HotKeys {
    static let shared = HotKeys()

    private(set) var combos: [ShortcutAction: KeyCombo] = AppSettings.load("shortcuts") ?? [:]
    @ObservationIgnored private var refs: [EventHotKeyRef] = []
    @ObservationIgnored private var handlerInstalled = false

    func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        combos[action] = combo
        AppSettings.shared.save(combos, "shortcuts")
        register()
    }

    func register() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        installHandler()
        for (i, action) in ShortcutAction.allCases.enumerated() {
            guard let c = combos[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x534E_5943), id: UInt32(i)) // 'SNYC'
            if RegisterEventHotKey(c.keyCode, c.carbonModifiers, id, GetEventDispatcherTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            MainActor.assumeIsolated {
                guard ShortcutAction.allCases.indices.contains(index) else { return }
                ShortcutAction.allCases[index].run(DeviceController.shared)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

struct ShortcutsTab: View {
    private var hotKeys = HotKeys.shared
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.label) {
                        HStack {
                            Button(recording == action ? "Digite o atalho…" : hotKeys.combos[action]?.display ?? "Gravar") {
                                startRecording(action)
                            }
                            .frame(minWidth: 120)
                            if hotKeys.combos[action] != nil {
                                Button { hotKeys.set(nil, for: action) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            } footer: {
                Text("Use ao menos um modificador (⌘ ⌥ ⌃ ⇧). Esc cancela a gravação. Os atalhos abrem o canal com o fone sob demanda.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: stopRecording)
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stopRecording(); return nil }
            if let combo = KeyCombo(event: e) {
                hotKeys.set(combo, for: action)
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
