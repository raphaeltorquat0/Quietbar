import AppKit
import MDRKit
import QuietAudio
import SwiftUI

struct AutomationTab: View {
    @Environment(DeviceController.self) private var device
    private var automation = Automation.shared

    var body: some View {
        @Bindable var settings = device.settings
        Form {
            Section {
                LabeledContent("Regra ativa", value: automation.indicator ?? String(localized: "Nenhuma"))
            } footer: {
                Text("Prioridade: ajuste manual › chamada › Foco › perfil por app › perfil por Wi-Fi › padrão. Um ajuste manual vale até a regra em vigor mudar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Chamadas") {
                Toggle("Mudar o modo de som em chamadas", isOn: $settings.callRuleEnabled)
                Picker("Modo na chamada", selection: $settings.callMode) {
                    ForEach(SoundMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.callRuleEnabled)
                Stepper("Esperar \(settings.callDelaySeconds) s antes de reagir", value: $settings.callDelaySeconds, in: 1...15)
                    .disabled(!settings.callRuleEnabled)
                Text("Funciona com qualquer app: o Quietbar observa se o microfone está em uso, sem ouvir o áudio e sem pedir permissão. No fim da chamada, o modo anterior volta.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apps ignorados") {
                ForEach(settings.micIgnoredApps) { app in
                    LabeledContent(app.name) {
                        Button("Remover", role: .destructive) { settings.micIgnoredApps.removeAll { $0 == app } }
                    }
                }
                ForEach(usingMicNow, id: \.self) { id in
                    LabeledContent(String(localized: "Usando o microfone: \(id)")) {
                        Button("Ignorar") { settings.micIgnoredApps.append(IgnoredApp(bundleID: id, name: id)) }
                    }
                }
                Button("Adicionar app…", action: addIgnored)
                Text("O microfone usado por estes apps, como ditado e gravadores, não conta como chamada. Exige macOS 14.2.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!settings.callRuleEnabled)
            Section("Foco") {
                Toggle("Aplicar o perfil de cada Foco", isOn: $settings.focusRuleEnabled)
                Button("Abrir os Ajustes de Foco") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
                }
                Text("Em Ajustes do Sistema › Foco, escolha um Foco e adicione o Quietbar em Filtros de Foco para associar um perfil a ele.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Perfis") {
                Toggle("Perfis por app", isOn: $settings.appRulesEnabled)
                Toggle("Perfis por Wi-Fi", isOn: $settings.wifiRulesEnabled)
                Text("O modo de cada um é definido no próprio perfil, na aba Perfis.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.callRuleEnabled) { automation.settingsChanged() }
        .onChange(of: settings.callMode) { automation.settingsChanged() }
        .onChange(of: settings.callDelaySeconds) { automation.settingsChanged() }
        .onChange(of: settings.micIgnoredApps) { automation.settingsChanged() }
        .onChange(of: settings.focusRuleEnabled) { automation.settingsChanged() }
        .onChange(of: settings.appRulesEnabled) { automation.settingsChanged() }
        .onChange(of: settings.wifiRulesEnabled) { automation.settingsChanged() }
    }

    /// Daemons de sistema não têm `.app` para escolher no seletor: ficam oferecidos aqui enquanto usam o microfone.
    private var usingMicNow: [String] {
        let ignored = device.settings.micIgnoredApps.map(\.bundleID)
        return (automation.micUsage.processes ?? []).filter { !ignored.contains($0) }
    }

    private func addIgnored() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        guard !device.settings.micIgnoredApps.contains(where: { $0.bundleID == id }) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        device.settings.micIgnoredApps.append(IgnoredApp(bundleID: id, name: name))
    }
}
