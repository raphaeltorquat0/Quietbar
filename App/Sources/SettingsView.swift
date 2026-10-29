import HeadphoneModel
import MDRKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(DeviceController.self) private var device

    @Bindable private var router = SettingsRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            GeneralTab().tabItem { Label("Geral", systemImage: "headphones") }.tag("general")
            SoundTab().tabItem { Label("Som", systemImage: "waveform") }.tag("sound")
            EqualizerTab().tabItem { Label("Equalizador", systemImage: "slider.vertical.3") }.tag("eq")
            ControlsTab().tabItem { Label("Controles", systemImage: "hand.tap") }.tag("controls")
            ShortcutsTab().tabItem { Label("Atalhos", systemImage: "keyboard") }.tag("shortcuts")
            ProfilesTab().tabItem { Label("Perfis", systemImage: "person.crop.rectangle.stack") }.tag("profiles")
            PopupTab().tabItem { Label("Popup", systemImage: "rectangle.portrait.on.rectangle.portrait") }.tag("popup")
            if device.settings.developerMode {
                DeveloperTab().tabItem { Label("Desenvolvedor", systemImage: "hammer") }.tag("developer")
            }
        }
        .frame(width: 560, height: 520)
        .keepsChannelOpen()
        .deviceAlerts()
        .overlay(alignment: .bottom) {
            if let e = device.lastError {
                Text(e).font(.caption).padding(6).background(.red.opacity(0.15), in: .rect(cornerRadius: 6)).padding(8)
            }
        }
    }
}

/// Seção que só aparece com o fone pronto.
struct DeviceSection<Content: View>: View {
    @Environment(DeviceController.self) private var device
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section(title) {
            if device.isReady { content() } else { Text("Conecte o fone para ver estes ajustes.").foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Geral

struct GeneralTab: View {
    @Environment(DeviceController.self) private var device
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmPowerOff = false

    var body: some View {
        @Bindable var device = device
        @Bindable var settings = device.settings
        let s = device.state
        Form {
            Section {
                if s.capabilities.isEarbuds, CustomMedia.modelURL == nil {
                    EarbudsVisual().frame(height: 170)
                } else {
                    HeadphoneView(battery: s.primaryBattery.map { Double($0.level) / 100 }, mode: s.noiseControl?.soundMode,
                                  accent: settings.ringAccent, customModel: CustomMedia.modelURL, lightRing: settings.modelLightRing)
                        .frame(height: 170)
                        .id(settings.modelLightRing)
                }
            }
            Section("Fone") {
                Picker("Dispositivo", selection: $device.selectedAddress) {
                    if device.devices.isEmpty { Text("Nenhum fone Sony pareado").tag(String?.none) }
                    ForEach(device.devices) { Text("\($0.name) (\($0.address))").tag(String?.some($0.address)) }
                }
                LabeledContent("Nome", value: device.selectedDevice?.name ?? "—")
                LabeledContent("Modelo", value: s.modelName ?? "—")
                LabeledContent("Firmware", value: s.firmwareVersion ?? "—")
                LabeledContent("Endereço", value: s.macAddress ?? device.selectedAddress ?? "—")
                LabeledContent("Codec", value: s.codec?.description ?? "—")
                LabeledContent("Bateria", value: batteryText(s))
                LabeledContent("Status") {
                    switch device.snapshot.phase {
                    case .ready: Text("Conectado").foregroundStyle(.green)
                    case .connecting: Text("Conectando…")
                    case .disconnected: Text("Desconectado")
                    case .failed(let m): Text(m).foregroundStyle(.red)
                    }
                }
                if s.capabilities.isFallback {
                    Text("O fone não informou as funções suportadas; usando o perfil conhecido do WH-1000XM5.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Bateria") {
                Toggle("Avisar com bateria fraca", isOn: $settings.lowBatteryAlert)
                    .onChange(of: settings.lowBatteryAlert) { _, on in
                        if on { Notifier.requestAuthorization() }
                        device.scheduleBatteryCheck()
                    }
                Stepper("Avisar abaixo de \(settings.lowBatteryThreshold)%", value: $settings.lowBatteryThreshold, in: 5...50, step: 5)
                Stepper("Conferir a cada \(settings.batteryCheckMinutes) min com a janela fechada",
                        value: $settings.batteryCheckMinutes, in: 5...120, step: 5)
                    .onChange(of: settings.batteryCheckMinutes) { device.scheduleBatteryCheck() }
            }
            Section("App") {
                Toggle("Mostrar a % da bateria ao lado do ícone", isOn: $settings.menuBarShowsPercent)
                Toggle("Mostrar a aba Desenvolvedor", isOn: $settings.developerMode)
                Toggle("Abrir ao iniciar sessão", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            device.lastError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Stepper("Liberar o fone \(settings.idleReleaseSeconds) s após fechar a janela",
                        value: $settings.idleReleaseSeconds, in: 5...300, step: 5)
                Toggle("Gravar tráfego do protocolo (para relatar bugs)", isOn: $settings.logTraffic)
                Button("Mostrar log no Finder") { NSWorkspace.shared.activateFileViewerSelecting([TrafficLog.url]) }
            }
            if device.isReady, s.capabilities.powerOff {
                Section {
                    Button("Desligar o fone…", role: .destructive) { confirmPowerOff = true }
                        .confirmationDialog("Desligar o fone?", isPresented: $confirmPowerOff) {
                            Button("Desligar", role: .destructive) { device.perform { try await $0.powerOff() } }
                        }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Som

struct SoundTab: View {
    @Environment(DeviceController.self) private var device

    var body: some View {
        let s = device.state
        Form {
            DeviceSection(title: "Controle de som ambiente") {
                if let n = s.noiseControl {
                    Picker("Modo", selection: deviceBinding(n.soundMode, default: .off) { m in device.perform { try await $0.setSoundMode(m) } }) {
                        ForEach(SoundMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DeviceSlider(value: Int(n.ambientLevel), range: 1...20, label: "Nível do ambiente") { v in
                        device.perform { try await $0.setAmbientLevel(v) }
                    }
                    Toggle("Focus on Voice", isOn: deviceBinding(n.focusOnVoice, default: false) { v in
                        device.perform { try await $0.setFocusOnVoice(v) }
                    })
                } else {
                    Text("O fone não informou o controle de som ambiente.").foregroundStyle(.secondary)
                }
            }
            if s.capabilities.dsee {
                DeviceSection(title: "DSEE") {
                    Toggle(s.dseeType == 0x03 ? "DSEE Extreme" : "DSEE", isOn: deviceBinding(s.dsee, default: false) { v in
                        device.perform { try await $0.setDSEE(v) }
                    })
                    .disabled(s.dseeAvailable == false)
                    if s.dseeAvailable == false {
                        Text("Indisponível no momento (o fone recusa com este codec ou modo).").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if s.capabilities.speakToChat {
                DeviceSection(title: "Speak-to-Chat") {
                    Toggle("Ativado", isOn: deviceBinding(s.speakToChat, default: false) { v in
                        device.perform { try await $0.setSpeakToChat(v) }
                    })
                    if let c = s.speakToChatConfig {
                        Picker("Sensibilidade", selection: deviceBinding(c.sensitivity, default: 0) { v in
                            device.perform { try await $0.setSpeakToChatConfig(SpeakToChatConfig(sensitivity: v, modeOutTime: c.modeOutTime)) }
                        }) {
                            Text("Automática").tag(UInt8(0)); Text("Alta").tag(UInt8(1)); Text("Baixa").tag(UInt8(2))
                        }
                        Picker("Voltar ao modo anterior", selection: deviceBinding(c.modeOutTime, default: 1) { v in
                            device.perform { try await $0.setSpeakToChatConfig(SpeakToChatConfig(sensitivity: c.sensitivity, modeOutTime: v)) }
                        }) {
                            Text("Curto").tag(UInt8(0)); Text("Padrão").tag(UInt8(1)); Text("Longo").tag(UInt8(2))
                            Text("Não voltar sozinho").tag(UInt8(3))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Controles e conexão

struct ControlsTab: View {
    @Environment(DeviceController.self) private var device

    var body: some View {
        let s = device.state
        Form {
            DeviceSection(title: "Botões e toque") {
                if s.capabilities.ncAmbButton, let f = s.ncAmbButton {
                    Picker("Botão NC/AMB alterna", selection: deviceBinding(f, default: .ncAmbientOff) { v in
                        device.perform { try await $0.setNcAmbButton(v) }
                    }) {
                        ForEach(NcAmbButtonFunction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                if let presets = s.assignableButtons, s.capabilities.assignableType != nil {
                    LabeledContent("Botão personalizável", value: presets.map(AssignablePreset.label).joined(separator: " / "))
                }
                ForEach(generalSettings(s, excluding: ["MULTIPOINT_SETTING"]), id: \.inquiredType) { cap in
                    Toggle(gsLabel(cap.subject), isOn: deviceBinding(s.generalSettings[cap.inquiredType], default: false) { v in
                        device.perform { try await $0.setGeneralSetting(cap.inquiredType, on: v) }
                    })
                }
            }
            DeviceSection(title: "Uso") {
                if s.capabilities.autoPause {
                    Toggle("Pausar ao tirar o fone", isOn: deviceBinding(s.autoPause, default: false) { v in
                        device.perform { try await $0.setAutoPause(v) }
                    })
                }
                if let a = s.autoPowerOff {
                    Picker("Desligamento automático", selection: deviceBinding(a.current, default: 0x11) { v in
                        device.perform { try await $0.setAutoPowerOff(v) }
                    }) {
                        ForEach(s.autoPowerOffOptions.isEmpty ? [a.current] : s.autoPowerOffOptions, id: \.self) {
                            Text(AutoPowerOff.label($0)).tag($0)
                        }
                    }
                }
            }
            DeviceSection(title: "Conexão") {
                if s.capabilities.connectionPriority, let p = s.connectionPriority {
                    Picker("Prioridade", selection: deviceBinding(p, default: .soundQuality) { v in
                        device.perform { try await $0.setConnectionPriority(v) }
                    }) {
                        Text("Qualidade de som").tag(ConnectionPriority.soundQuality)
                        Text("Estabilidade da conexão").tag(ConnectionPriority.stability)
                    }
                }
                if let mp = s.generalSetting(subject: "MULTIPOINT_SETTING") {
                    Toggle("Conectar a 2 dispositivos (multiponto)", isOn: deviceBinding(mp.on, default: false) { v in
                        device.perform { try await $0.setGeneralSetting(mp.type, on: v) }
                    })
                    Text("O fone pode pedir confirmação e reconectar ao mudar.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func generalSettings(_ s: MDRDeviceState, excluding: Set<String>) -> [GeneralSettingCapability] {
        s.generalSettingCapabilities.values.filter { $0.isBoolean && !excluding.contains($0.subject) }.sorted { $0.inquiredType < $1.inquiredType }
    }

    private func gsLabel(_ subject: String) -> String {
        switch subject {
        case "TOUCH_PANEL_SETTING": "Painel de toque"
        case "SIDETONE_SETTING": "Ouvir a própria voz em chamadas"
        case "MULTIPOINT_SETTING": "Multiponto"
        default: subject
        }
    }
}

// MARK: - Popup

struct PopupTab: View {
    @Environment(DeviceController.self) private var device
    @State private var importing: Importing?
    @State private var mediaVersion = 0
    @State private var error: String?

    enum Importing { case model, image }

    var body: some View {
        @Bindable var settings = device.settings
        Form {
            Section("Popup de conexão") {
                Toggle("Mostrar quando o fone conectar", isOn: $settings.popupEnabled)
                Picker("Posição", selection: $settings.popupPosition) {
                    ForEach(PopupPosition.allCases) { Text($0.label).tag($0.rawValue) }
                }
                LabeledContent("Duração") {
                    Stepper("\(Int(settings.popupDuration)) s", value: $settings.popupDuration, in: 2...20, step: 1)
                }
                Button("Mostrar agora") { PopupController.shared.present() }.disabled(!settings.popupEnabled)
            }
            Section("Visual") {
                Toggle("Modelo 3D (desligado: ilustração 2D)", isOn: $settings.popupUse3D)
                Toggle("Anel de luz no modelo (bateria e modo)", isOn: $settings.modelLightRing)
                if settings.modelLightRing {
                    LabeledContent("Cor do anel") {
                        HStack {
                            ColorPicker("", selection: Binding(get: { Color(nsColor: settings.ringNSColor) }, set: { c in
                                let n = NSColor(c).usingColorSpace(.sRGB) ?? .systemBlue
                                settings.ringColor = [n.redComponent, n.greenComponent, n.blueComponent].map(Double.init)
                            })).labelsHidden()
                            Button("Usar a do sistema") { settings.ringColor = nil }.disabled(settings.ringColor == nil)
                        }
                    }
                }
                mediaRow("Modelo 3D próprio (.usdz, até 20 MB)", file: CustomMedia.modelURL, kind: .model, remove: CustomMedia.modelFile)
                mediaRow("Imagem própria (no lugar da ilustração 2D)", file: CustomMedia.image == nil ? nil : CustomMedia.imageFile,
                         kind: .image, remove: CustomMedia.imageFile)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .id(mediaVersion)
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing == .model ? [.usdz] : [.image]) { result in
            do {
                let url = try result.get()
                if importing == .model { try CustomMedia.importModel(from: url) } else { try CustomMedia.importImage(from: url) }
                error = nil
            } catch { self.error = error.localizedDescription }
            importing = nil
            mediaVersion += 1
        }
    }

    private func mediaRow(_ title: String, file: URL?, kind: Importing, remove: URL) -> some View {
        LabeledContent(title) {
            HStack {
                Button(file == nil ? "Escolher…" : "Trocar…") { importing = kind }
                if file != nil {
                    Button("Remover", role: .destructive) { CustomMedia.remove(remove); mediaVersion += 1 }
                }
            }
        }
    }
}

/// Bateria em texto: única (over-ear) ou esquerdo/direito/estojo (earbuds).
func batteryText(_ s: MDRDeviceState) -> String {
    func pct(_ b: BatteryStatus) -> String { "\(b.level)%\(b.isCharging ? " ⚡︎" : "")" }
    if let lr = s.batteryLR {
        var parts: [String] = []
        if lr.left.level > 0 { parts.append(String(localized: "E") + " " + pct(lr.left)) }
        if lr.right.level > 0 { parts.append(String(localized: "D") + " " + pct(lr.right)) }
        if let c = s.batteryCase, c.level > 0 { parts.append(String(localized: "Estojo") + " " + pct(c)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
    return s.battery.map(pct) ?? "—"
}
