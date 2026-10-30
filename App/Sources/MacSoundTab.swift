import MDRKit
import QuietAudio
import SwiftUI
import UniformTypeIdentifiers

/// Aba "Som no Mac": curva, A/B, importar/exportar e os dois EQs lado a lado.
struct MacSoundTab: View {
    @Environment(DeviceController.self) private var device
    @State private var selected = 0
    @State private var importing = false
    @State private var message: String?
    private var sound: MacSound { .shared }

    var body: some View {
        @Bindable var sound = sound
        Form {
            if !sound.available {
                Text("O processamento de áudio exige macOS 14.2 ou mais novo.").foregroundStyle(.secondary)
            } else {
                if !sound.onboarded { onboarding }
                control
                editor
                headphoneEQ
                source
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .json]) { importCurve($0) }
    }

    private var onboarding: some View {
        Section("Antes de ligar") {
            Text("O Som no Mac melhora o som do seu fone no Mac: ele corrige a resposta de frequência e aplica um EQ com mais bandas que o do fone.")
            Text("Para isso, o Quietbar pede a permissão **Gravação de Áudio do Sistema**. O macOS usa esse nome porque o app precisa receber o áudio antes de ele chegar ao fone. Nada é gravado, salvo nem enviado: o som é processado na memória e sai direto para o fone.")
            Text("Vale só para o áudio do Mac. Não altera o cancelamento de ruído nem o som no celular.")
            Text("Responda ao pedido do macOS assim que ele aparecer: enquanto ele estiver aberto, outros apps podem não conseguir começar a tocar som.")
                .foregroundStyle(.orange)
            Button("Ligar o Som no Mac") {
                sound.onboarded = true
                sound.enabled = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var control: some View {
        @Bindable var sound = sound
        Section {
            Toggle("Som no Mac", isOn: $sound.enabled).disabled(!sound.onboarded)
            LabeledContent("Estado", value: sound.statusText)
            if case .failed(let reason) = sound.engine?.phase {
                Text(reason).font(.caption).foregroundStyle(.orange)
                Text("Se você negou a permissão, libere em Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Preset", selection: $sound.preset) {
                ForEach(MacPreset.allCases) { p in
                    Text(p.label).tag(p).disabled(p == .correction && sound.correction == nil)
                }
            }
            HStack {
                Button(sound.engine?.bypass == true ? "Ouvindo: original (B)" : "Ouvindo: processado (A)") {
                    sound.engine?.setBypass(!(sound.engine?.bypass ?? false))
                }
                .disabled(sound.engine?.phase != .active)
                Spacer()
                LevelMeter(level: sound.engine?.outputLevel ?? 0).frame(width: 180, height: 8)
            }
        } footer: {
            Text("Melhora o som do seu fone no Mac. Vale só para o áudio do Mac: não altera o cancelamento de ruído nem o som no celular.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var editor: some View {
        Section("Curva") {
            CurveEditor(curve: sound.curve, selected: $selected) { i, frequency, gain in
                sound.edit {
                    $0.filters[i].frequency = frequency
                    $0.filters[i].gain = gain
                }
            }
            .frame(height: 190)
            if sound.curve.filters.indices.contains(selected) { filterControls(selected) }
            HStack {
                Button("Adicionar filtro") {
                    sound.edit { $0.filters.append(EQFilter(.peak, frequency: 1000, gain: 0, q: 1)) }
                    selected = sound.curve.filters.count - 1
                }
                .disabled(sound.curve.filters.count >= EQCurve.maxFilters)
                Button("Remover") {
                    sound.edit { $0.filters.remove(at: selected) }
                    selected = max(0, selected - 1)
                }
                .disabled(!sound.curve.filters.indices.contains(selected))
                Spacer()
                Text(String(format: String(localized: "Pré-amplificação automática: %.1f dB"), sound.curve.autoPreampDB() + 0))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Button("Importar…") { importing = true }
                Button("Exportar…") { exportCurve() }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func filterControls(_ i: Int) -> some View {
        let f = sound.curve.filters[i]
        return Group {
            Picker("Filtro \(i + 1)", selection: Binding(get: { f.kind }, set: { k in sound.edit { $0.filters[i].kind = k } })) {
                Text("Pico").tag(EQFilter.Kind.peak)
                Text("Shelf grave").tag(EQFilter.Kind.lowShelf)
                Text("Shelf agudo").tag(EQFilter.Kind.highShelf)
            }
            .pickerStyle(.segmented)
            LabeledContent("Frequência") {
                TextField("Hz", value: Binding(get: { f.frequency }, set: { v in
                    sound.edit { $0.filters[i].frequency = min(EQFilter.frequencyRange.upperBound, max(EQFilter.frequencyRange.lowerBound, v)) }
                }), format: .number.precision(.fractionLength(0))).frame(width: 80).multilineTextAlignment(.trailing)
            }
            LabeledContent("Ganho") {
                Stepper(String(format: "%.1f dB", f.gain), value: Binding(get: { f.gain }, set: { v in sound.edit { $0.filters[i].gain = v } }),
                        in: -12...12, step: 0.5)
            }
            LabeledContent("Q") {
                Slider(value: Binding(get: { f.q }, set: { v in sound.edit { $0.filters[i].q = v } }), in: 0.3...10).frame(width: 180)
                Text(String(format: "%.2f", f.q)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }

    /// Os dois EQs na mesma tela; a troca para plano só acontece com o clique do usuário.
    private var headphoneEQ: some View {
        DeviceSection(title: "EQ do fone") {
            if let eq = device.state.equalizer {
                LabeledContent("Preset do fone", value: PresetNames.name(eq.presetID, custom: device.settings.presetNames))
                EqualizerCurve(values: eq.isFiveBand ? Array(eq.values.dropFirst()) : eq.values, limit: eq.range.upperBound).frame(height: 50)
                if sound.enabled, eq.presetID != 0x00 {
                    HStack {
                        Text("Com a correção ligada, o ideal é deixar o EQ do fone em plano, para não somar as duas curvas.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Deixar em plano") { device.perform { try await $0.setEqualizerPreset(0x00) } }
                    }
                }
            } else {
                Text("Este fone não informou um equalizador.").foregroundStyle(.secondary)
            }
        }
    }

    private var source: some View {
        Section("Curva de correção") {
            Text("O Quietbar não traz uma curva pronta: a licença das medições não permite redistribuí-la (veja docs/AUDIO.md). Para usar o preset Correção:")
            Text("1. Abra autoeq.app e escolha o seu fone.\n2. Em Equalizer, escolha Parametric e baixe o `ParametricEQ.txt`.\n3. Clique em Importar… e selecione o arquivo.")
            if let c = sound.correction {
                LabeledContent("Importada", value: "\(c.name) · \(c.filters.count) filtros")
            }
        }
        .font(.callout)
    }

    private func importCurve(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 256_000 else {
                throw CurveError.invalidFile("arquivo grande demais")
            }
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            let curve = url.pathExtension.lowercased() == "json"
                ? try EQCurve.parseJSON(data)
                : try EQCurve.parseAutoEQ(String(decoding: data, as: UTF8.self), name: name)
            sound.correction = curve
            sound.preset = .correction
            selected = 0
            message = String(localized: "Importada.")
        } catch { message = error.localizedDescription }
    }

    private func exportCurve() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(sound.curve.name).json"
        p.allowedContentTypes = [.json, .plainText]
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let data = url.pathExtension.lowercased() == "txt" ? Data(sound.curve.autoEQText().utf8) : try sound.curve.jsonData()
            try data.write(to: url)
            message = String(localized: "Exportada.")
        } catch { message = error.localizedDescription }
    }
}

/// Pontos arrastáveis sobre a resposta combinada. Eixo em log, 20 Hz a 20 kHz, ±15 dB.
struct CurveEditor: View {
    let curve: EQCurve
    @Binding var selected: Int
    let onDrag: (Int, Double, Double) -> Void

    @State private var dragging: Int?
    private static let limit = 15.0

    private func x(_ f: Double, _ w: CGFloat) -> CGFloat { CGFloat(log10(f / 20) / 3) * w }
    private func y(_ db: Double, _ h: CGFloat) -> CGFloat { h / 2 - CGFloat(db / Self.limit) * (h / 2 - 6) }
    private func frequency(_ px: CGFloat, _ w: CGFloat) -> Double { 20 * pow(1000, Double(min(max(px / w, 0), 1))) }
    private func gain(_ py: CGFloat, _ h: CGFloat) -> Double {
        ((Double((h / 2 - py) / (h / 2 - 6)) * Self.limit) * 2).rounded() / 2
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Canvas { ctx, size in
                for f in [100.0, 1000, 10000] {
                    var p = Path()
                    p.move(to: CGPoint(x: x(f, w), y: 0))
                    p.addLine(to: CGPoint(x: x(f, w), y: h))
                    ctx.stroke(p, with: .color(.secondary.opacity(0.2)))
                    ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000)) kHz" : "\(Int(f)) Hz").font(.caption2).foregroundColor(.secondary),
                             at: CGPoint(x: x(f, w) + 3, y: h - 2), anchor: .bottomLeading)
                }
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: h / 2))
                zero.addLine(to: CGPoint(x: w, y: h / 2))
                ctx.stroke(zero, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3]))

                var line = Path()
                for (i, f) in EQCurve.grid(max(Int(w), 2)).enumerated() {
                    let p = CGPoint(x: x(f, w), y: y(curve.responseDB(at: f), h))
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                }
                ctx.stroke(line, with: .color(.accentColor), lineWidth: 2)

                for (i, f) in curve.filters.enumerated() {
                    let c = CGPoint(x: x(f.frequency, w), y: y(f.gain, h))
                    let r: CGFloat = i == selected ? 6 : 4.5
                    let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    ctx.fill(dot, with: .color(i == selected ? .accentColor : .primary.opacity(0.7)))
                    ctx.stroke(dot, with: .color(.white.opacity(0.8)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if dragging == nil {
                    dragging = curve.filters.indices.min { hypot(x(curve.filters[$0].frequency, w) - v.startLocation.x, y(curve.filters[$0].gain, h) - v.startLocation.y)
                        < hypot(x(curve.filters[$1].frequency, w) - v.startLocation.x, y(curve.filters[$1].gain, h) - v.startLocation.y) }
                    if let dragging { selected = dragging }
                }
                if let dragging { onDrag(dragging, frequency(v.location.x, w), min(Self.limit, max(-Self.limit, gain(v.location.y, h)))) }
            }.onEnded { _ in dragging = nil })
            .accessibilityLabel("Curva do equalizador")
            .accessibilityValue(curve.filters.isEmpty ? "Plana" : "\(curve.filters.count) filtros")
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { g in
            // -60 a 0 dBFS
            let db = 20 * log10(max(level, 1e-4))
            let fraction = CGFloat(max(0, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.2))
                Capsule().fill(db > -1.5 ? Color.orange : .accentColor).frame(width: g.size.width * fraction)
            }
        }
        .accessibilityLabel("Nível de saída")
        .accessibilityValue(String(format: "%.0f dB", 20 * log10(max(level, 1e-4))))
    }
}

/// Bloco da aba Desenvolvedor.
struct MacSoundDeveloperSection: View {
    private var engine: AudioEngine? { MacSound.shared.engine }
    @State private var cpu = 0.0

    var body: some View {
        Section("Som no Mac") {
            if let engine {
                LabeledContent("Estado da tap", value: "\(engine.phase)")
                LabeledContent("Dispositivo", value: engine.device?.name ?? "—")
                LabeledContent("Sample rate", value: engine.device.map { "\(Int($0.sampleRate)) Hz · \($0.channels) canais" } ?? "—")
                LabeledContent("Latência medida", value: String(format: "%.1f ms", engine.latency * 1000))
                LabeledContent("Carga do render", value: String(format: "%.2f %%", engine.load * 100))
                LabeledContent("CPU do app", value: String(format: "%.1f %%", cpu))
                Toggle("Tom de teste (1 kHz, −20 dBFS)", isOn: Binding(get: { engine.toneOn }, set: { engine.setTone($0) }))
                    .disabled(engine.device == nil || engine.phase == .callMode)
            } else {
                Text("Exige macOS 14.2 ou mais novo.").foregroundStyle(.secondary)
            }
        }
        .task {
            var last = AudioProbe.cpuSeconds(), t = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = AudioProbe.cpuSeconds(), d = Date()
                cpu = (now - last) / d.timeIntervalSince(t) * 100
                last = now
                t = d
            }
        }
    }
}
