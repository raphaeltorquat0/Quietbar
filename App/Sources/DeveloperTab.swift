import AppKit
import HeadphoneModel
import MDRKit
import MDRTransport
import SwiftUI
import UniformTypeIdentifiers

/// Ferramentas de debug: popup, modelo 3D ao vivo, busca Fast Pair, log do protocolo e diagnóstico.
struct DeveloperTab: View {
    var body: some View {
        Form {
            DiagnosticsSection()
            PopupTestSection()
            ModelViewerSection()
            PairingScanSection()
            ProtocolLogSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Diagnóstico

private struct DiagnosticsSection: View {
    @Environment(DeviceController.self) private var device

    var body: some View {
        Section("Diagnóstico") {
            LabeledContent("SonyCtl", value: Diagnostics.appVersion)
            LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            LabeledContent("Fone", value: device.state.modelName ?? "—")
            LabeledContent("Firmware", value: device.state.firmwareVersion ?? "—")
            LabeledContent("Canal", value: "\(device.snapshot.phase)")
            DisclosureGroup("Capacidades e estado detectados") {
                ForEach(Array(device.state.diagnosticFields.enumerated()), id: \.offset) { _, f in
                    LabeledContent(f.0) { Text(f.1).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            Button("Copiar diagnóstico") { Diagnostics.copy(Diagnostics.report(device)) }
        }
    }
}

@MainActor enum Diagnostics {
    static var appVersion: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }

    static func report(_ d: DeviceController) -> String {
        var lines = ["SonyCtl \(appVersion)", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "canal: \(d.snapshot.phase)", "bluetooth conectado: \(d.isBluetoothConnected)"]
        if let e = d.lastError { lines.append("último erro: \(e)") }
        lines += d.state.diagnosticFields.map { "\($0.0): \($0.1)" }
        return lines.joined(separator: "\n")
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Salva texto escolhendo o destino pelo NSSavePanel.
    static func save(_ text: String, name: String) {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.allowedContentTypes = [.plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Popup

private struct PopupTestSection: View {
    @Environment(DeviceController.self) private var device

    var body: some View {
        Section("Popup") {
            HStack {
                Button("Testar popup") {
                    PopupController.shared.present(force: true, demo: device.isBluetoothConnected ? nil : PopupDemo())
                }
                Text(device.isBluetoothConnected ? "com os dados do fone" : "fone desconectado: dados fictícios")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Modelo 3D

private struct ModelViewerSection: View {
    @Environment(DeviceController.self) private var device
    @State private var mode: SoundMode = .noiseCanceling
    @State private var battery = 0.62
    @State private var reduceMotion = false
    @State private var idle = true
    @State private var entrance = 0
    @State private var message: String?

    var body: some View {
        Section("Modelo 3D") {
            HeadphoneView(battery: battery, mode: mode, accent: device.settings.ringAccent, customModel: CustomMedia.modelURL,
                          entranceID: entrance, idleRotation: idle, reduceMotion: reduceMotion,
                          lightRing: device.settings.modelLightRing)
                .frame(height: 240)
                .id("\(reduceMotion)\(device.settings.modelLightRing)") // recria o rig ao trocar o modo de movimento
            Picker("Estado", selection: $mode) {
                ForEach(SoundMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Bateria \(Int(battery * 100))%") { Slider(value: $battery, in: 0...1) }
            Toggle("Reduzir movimento", isOn: $reduceMotion)
            Toggle("Girar devagar", isOn: $idle)
            HStack {
                Button("Repetir entrada") { entrance += 1 }
                Button("Exportar USDZ…") { export() }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "SonyCtl.usdz"
        p.allowedContentTypes = [.usdz]
        guard p.runModal() == .OK, let url = p.url else { return }
        var st = HeadphoneExport.State()
        st.mode = mode
        st.battery = battery
        do {
            try HeadphoneExport.exportUSDZ(to: url, state: st)
            message = "Salvo."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Busca Fast Pair

private struct PairingScanSection: View {
    @State private var scanner = FastPairScanner()
    @State private var results: [BLEAdvertisement] = []
    @State private var remaining = 0
    @State private var error: String?
    @State private var onlyFastPair = true

    private var shown: [BLEAdvertisement] {
        results.filter { !onlyFastPair || $0.fastPair != nil || $0.name.localizedCaseInsensitiveContains("WH-") }
            .sorted { $0.rssi > $1.rssi }
    }

    var body: some View {
        Section("Procurar fone em modo de pareamento") {
            Text("1. Desligue o fone. 2. Segure o botão de ligar por 7 s, até a luz piscar em azul. 3. Clique em Procurar.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(remaining > 0 ? "Procurando… \(remaining) s" : "Procurar (20 s)") { start() }.disabled(remaining > 0)
                Toggle("Só Fast Pair e fones", isOn: $onlyFastPair)
                Spacer()
                Button("Copiar resultado") { Diagnostics.copy(report) }.disabled(results.isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            ForEach(shown) { a in
                HStack {
                    Text("\(a.rssi) dBm").monospacedDigit().frame(width: 64, alignment: .leading)
                    Text(a.name).lineLimit(1)
                    Spacer()
                    if let id = a.fastPairModelID {
                        Text("Fast Pair · model ID \(id)").foregroundStyle(.green)
                    } else if a.fastPair != nil {
                        Text("Fast Pair (sem model ID)").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
            if remaining == 0, !results.isEmpty, shown.isEmpty {
                Text("Nenhum anúncio Fast Pair encontrado.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { scanner.stop() }
    }

    private var report: String {
        "Busca BLE (\(Date().formatted())) — \(results.count) anunciantes\n" + shown.map(\.summary).joined(separator: "\n")
    }

    private func start() {
        results = []
        error = nil
        scanner.onUpdate = { a in
            if let i = results.firstIndex(where: { $0.id == a.id }) { results[i] = a } else { results.append(a) }
        }
        scanner.onError = { error = $0 }
        scanner.start()
        remaining = 20
        Task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
            scanner.stop()
        }
    }
}

// MARK: - Log do protocolo

private struct ProtocolLogSection: View {
    @State private var filter = ""
    @State private var frozen: [ProtocolLog.Entry]?
    private let log = ProtocolLog.shared

    private var visible: [ProtocolLog.Entry] {
        let all = frozen ?? log.entries
        guard !filter.isEmpty else { return all }
        return all.filter { $0.hex.localizedCaseInsensitiveContains(filter) || $0.decoded.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        Section("Log do protocolo MDR") {
            HStack {
                TextField("Filtrar (hex ou mensagem)", text: $filter).textFieldStyle(.roundedBorder)
                Button(frozen == nil ? "Pausar" : "Continuar") { frozen = frozen == nil ? log.entries : nil }
                Button("Limpar") { log.clear(); frozen = nil }
                Button("Copiar") { Diagnostics.copy(text) }
                Button("Exportar…") { Diagnostics.save(text, name: "sonyctl-mdr.log") }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { e in
                            Text(e.line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(e.outgoing ? Color.accentColor : .primary)
                                .textSelection(.enabled)
                                .id(e.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
                .onChange(of: visible.last?.id) { _, id in if frozen == nil, let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Text(log.entries.isEmpty ? "Sem tráfego ainda. Abra o painel da barra para conectar." : "\(visible.count) de \(log.entries.count) frames · >> enviado, << recebido")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var text: String { visible.map(\.line).joined(separator: "\n") }
}
