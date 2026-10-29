import AppKit
import CoreLocation
import CoreWLAN
import MDRKit
import MDRSession
import SwiftUI

/// Conjunto de ajustes aplicado quando um app fica em foco ou o Mac entra numa rede Wi-Fi.
/// Substituto local do Adaptive Sound Control. `nil` = não alterar.
struct Profile: Codable, Hashable, Identifiable {
    enum Trigger: Codable, Hashable {
        case app(bundleID: String, name: String)
        case wifi(ssid: String)
    }

    var id = UUID()
    var name: String
    var enabled = true
    var trigger: Trigger
    var soundMode: SoundMode?
    var ambientLevel: Int?
    var focusOnVoice: Bool?
    var equalizerPresetID: UInt8?
    var speakToChat: Bool?

    var triggerLabel: String {
        switch trigger {
        case .app(_, let name): "App: \(name)"
        case .wifi(let ssid): "Wi-Fi: \(ssid)"
        }
    }

    func apply(_ s: MDRSession) async throws {
        if soundMode != nil || ambientLevel != nil || focusOnVoice != nil {
            try await s.setNoiseControl { n in
                if let m = soundMode { n.soundMode = m }
                if let l = ambientLevel { n.ambientLevel = UInt8(clamping: l) }
                if let v = focusOnVoice { n.focusOnVoice = v }
            }
        }
        if let id = equalizerPresetID { try await s.setEqualizerPreset(id) }
        if let stc = speakToChat { try await s.setSpeakToChat(stc) }
    }
}

@MainActor @Observable
final class ProfileEngine: NSObject {
    static let shared = ProfileEngine()

    var profiles: [Profile] = AppSettings.load("profiles") ?? [] {
        didSet { AppSettings.shared.save(profiles, "profiles"); evaluate() }
    }
    private(set) var activeProfileID: UUID?
    private(set) var currentSSID: String?
    private(set) var frontmostBundleID: String?

    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                ProfileEngine.shared.frontmostBundleID = id
                ProfileEngine.shared.evaluate()
            }
        }
        if profiles.contains(where: { if case .wifi = $0.trigger { true } else { false } }) { startWiFi() }
        evaluate()
    }

    /// O macOS só revela o SSID para apps com autorização de localização.
    func startWiFi() {
        location.delegate = self
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        let client = CWWiFiClient.shared()
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        readSSID()
    }

    var locationDenied: Bool { [.denied, .restricted].contains(location.authorizationStatus) }

    func readSSID() {
        currentSSID = CWWiFiClient.shared().interface()?.ssid()
        evaluate()
    }

    func evaluate() {
        let enabled = profiles.filter(\.enabled)
        let match = enabled.first {
            if case .app(let id, _) = $0.trigger { return id == frontmostBundleID }
            return false
        } ?? enabled.first {
            if case .wifi(let ssid) = $0.trigger { return ssid == currentSSID }
            return false
        }
        guard let match, match.id != activeProfileID else {
            if match == nil { activeProfileID = nil }
            return
        }
        activeProfileID = match.id
        DeviceController.shared.perform { try await match.apply($0) }
    }
}

extension ProfileEngine: CWEventDelegate, CLLocationManagerDelegate {
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { ProfileEngine.shared.readSSID() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { ProfileEngine.shared.readSSID() }
    }
}

// MARK: - UI

struct ProfilesTab: View {
    @Environment(DeviceController.self) private var device
    @Bindable private var engine = ProfileEngine.shared
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                List(selection: $selection) {
                    ForEach(engine.profiles) { p in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(p.name)
                                if p.id == engine.activeProfileID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            }
                            Text(p.triggerLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(p.id)
                    }
                }
                HStack {
                    Menu {
                        Button("App em foco…") { addAppProfile() }
                        Button("Rede Wi-Fi atual") { addWiFiProfile() }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    Button { engine.profiles.removeAll { $0.id == selection } } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless).disabled(selection == nil)
                }
                .padding(6)
            }
            .frame(minWidth: 180)

            if let i = engine.profiles.firstIndex(where: { $0.id == selection }) {
                ProfileEditor(profile: $engine.profiles[i], presets: device.state.equalizerPresets)
            } else {
                Text("Perfis aplicam ajustes quando um app fica em foco ou o Mac entra numa rede Wi-Fi. App tem prioridade sobre Wi-Fi.")
                    .foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func addAppProfile() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let p = Profile(name: name, trigger: .app(bundleID: id, name: name), soundMode: .noiseCanceling)
        engine.profiles.append(p)
        selection = p.id
    }

    private func addWiFiProfile() {
        engine.startWiFi()
        let ssid = engine.currentSSID ?? ""
        let p = Profile(name: ssid.isEmpty ? "Rede Wi-Fi" : ssid, trigger: .wifi(ssid: ssid), soundMode: .ambient)
        engine.profiles.append(p)
        selection = p.id
    }
}

struct ProfileEditor: View {
    @Binding var profile: Profile
    let presets: [EqPreset]
    private var engine = ProfileEngine.shared

    init(profile: Binding<Profile>, presets: [EqPreset]) {
        _profile = profile
        self.presets = presets
    }

    var body: some View {
        Form {
            TextField("Nome", text: $profile.name)
            Toggle("Ativo", isOn: $profile.enabled)
            if case .wifi(let ssid) = profile.trigger {
                TextField("SSID", text: Binding(get: { ssid }, set: { profile.trigger = .wifi(ssid: $0) }))
                if engine.locationDenied {
                    Text("Sem permissão de Localização o macOS esconde o nome da rede. Libere em Ajustes do Sistema › Privacidade › Serviços de Localização.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                LabeledContent("Gatilho", value: profile.triggerLabel)
            }
            Section("Ao ativar") {
                Picker("Modo", selection: $profile.soundMode) {
                    Text("Não alterar").tag(SoundMode?.none)
                    ForEach(SoundMode.allCases, id: \.self) { Text($0.label).tag(SoundMode?.some($0)) }
                }
                optionalStepper("Nível do ambiente", $profile.ambientLevel, 1...20, default: 10)
                optionalBool("Focus on Voice", $profile.focusOnVoice)
                Picker("Equalizador", selection: $profile.equalizerPresetID) {
                    Text("Não alterar").tag(UInt8?.none)
                    ForEach(presets.isEmpty ? EqPreset.knownNames.keys.sorted().map { EqPreset(id: $0, name: "") } : presets) {
                        Text($0.displayName).tag(UInt8?.some($0.id))
                    }
                }
                optionalBool("Speak-to-Chat", $profile.speakToChat)
            }
        }
        .formStyle(.grouped)
    }

    private func optionalBool(_ title: String, _ b: Binding<Bool?>) -> some View {
        Picker(title, selection: b) {
            Text("Não alterar").tag(Bool?.none)
            Text("Ligado").tag(Bool?.some(true))
            Text("Desligado").tag(Bool?.some(false))
        }
    }

    private func optionalStepper(_ title: String, _ v: Binding<Int?>, _ r: ClosedRange<Int>, default d: Int) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { v.wrappedValue != nil }, set: { v.wrappedValue = $0 ? d : nil }))
            if let value = v.wrappedValue {
                Stepper("\(value)", value: Binding(get: { value }, set: { v.wrappedValue = $0 }), in: r)
            }
        }
    }
}
