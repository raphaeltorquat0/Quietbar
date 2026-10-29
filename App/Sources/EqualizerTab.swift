import MDRKit
import SwiftUI

struct EqualizerTab: View {
    @Environment(DeviceController.self) private var device
    @State private var draft: [Int]?
    @State private var newName = ""

    var body: some View {
        let s = device.state
        let eq = s.equalizer
        let labels = eq?.labels ?? []
        let range = eq?.range ?? -10...10
        let values = draft ?? eq?.values ?? []
        // No layout de 6, o 1º valor é o Clear Bass (fora da curva de frequências).
        let hasClearBass = eq?.isFiveBand == true
        Form {
            DeviceSection(title: "Preset") {
                if let eq {
                    Picker("Preset do fone", selection: deviceBinding(eq.presetID, default: 0) { id in
                        device.perform { try await $0.setEqualizerPreset(id) }
                    }) {
                        ForEach(s.equalizerPresets) { Text(PresetNames.name($0.id, custom: device.settings.presetNames)).tag($0.id) }
                    }
                    if (0xA1...0xA5).contains(eq.presetID) {
                        TextField("Nome deste preset", text: Binding(
                            get: { device.settings.presetNames[String(eq.presetID)] ?? "" },
                            set: { device.settings.presetNames[String(eq.presetID)] = $0.isEmpty ? nil : $0 }),
                                  prompt: Text(PresetNames.name(eq.presetID)))
                    }
                    if s.equalizerAvailable == false {
                        Text("O fone desativou o equalizador agora (ex.: em chamada).").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DeviceSection(title: "Curva (dB)") {
                if eq?.isEditable == true, values.count == labels.count {
                    EqualizerCurve(values: hasClearBass ? Array(values.dropFirst()) : values, limit: range.upperBound).frame(height: 80)
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(0..<values.count, id: \.self) { i in
                            VStack(spacing: 4) {
                                Text(values[i] > 0 ? "+\(values[i])" : "\(values[i])").monospacedDigit().font(.caption)
                                VerticalSlider(value: values[i], range: range) { v in
                                    var d = values
                                    d[i] = v
                                    draft = d
                                } onCommit: { commit() }
                                Text(labels[i]).font(.caption2).foregroundStyle(hasClearBass && i == 0 ? Color.accentColor : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 190)
                    HStack {
                        Button("Zerar") { draft = Array(repeating: 0, count: values.count); commit() }
                        Spacer()
                        Text("Editar aplica no preset Custom (ou no User Setting selecionado).").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Este fone não expõe um equalizador editável.").foregroundStyle(.secondary)
                }
            }
            Section("Presets salvos neste Mac") {
                // Só as curvas com o mesmo número de bandas deste fone.
                ForEach(device.settings.savedEqualizers.filter { $0.curve.count == values.count }) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Text(p.curve.map(String.init).joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button("Aplicar") { let c = p.curve; device.perform { try await $0.setEqualizer(values: c) } }
                            .disabled(!device.isReady)
                        Button(role: .destructive) { device.settings.savedEqualizers.removeAll { $0.id == p.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Nome", text: $newName)
                    Button("Salvar curva atual") {
                        device.settings.savedEqualizers.append(SavedEqualizer(name: newName, clearBass: 0, bands: [], values: values))
                        newName = ""
                    }
                    .disabled(newName.isEmpty || eq?.isEditable != true)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: eq) { draft = nil } // o fone respondeu: volta a mostrar o valor dele
    }

    private func commit() {
        guard let d = draft else { return }
        device.perform { try await $0.setEqualizer(values: d) }
    }
}

struct VerticalSlider: View {
    let value: Int
    var range: ClosedRange<Int> = -10...10
    let onChange: (Int) -> Void
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { g in
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }), in: Double(range.lowerBound)...Double(range.upperBound), step: 1) { editing in
                if !editing { onCommit() }
            }
            .rotationEffect(.degrees(-90))
            .frame(width: g.size.height)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
    }
}

/// Curva suave pelas bandas (±`limit` dB).
struct EqualizerCurve: View {
    let values: [Int]
    var limit: Int = 10

    var body: some View {
        Canvas { ctx, size in
            let pts = values.enumerated().map { i, v in
                CGPoint(x: size.width * (CGFloat(i) + 0.5) / CGFloat(values.count),
                        y: size.height / 2 - CGFloat(v) / CGFloat(limit) * (size.height / 2 - 4))
            }
            var mid = Path()
            mid.move(to: CGPoint(x: 0, y: size.height / 2))
            mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(mid, with: .color(.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3]))
            guard let first = pts.first else { return }
            var p = Path()
            p.move(to: CGPoint(x: 0, y: first.y))
            p.addLine(to: first)
            for (a, b) in zip(pts, pts.dropFirst()) {
                let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                p.addQuadCurve(to: c, control: a)
            }
            if let last = pts.last {
                p.addQuadCurve(to: last, control: last)
                p.addLine(to: CGPoint(x: size.width, y: last.y))
            }
            ctx.stroke(p, with: .color(.accentColor), lineWidth: 2)
            for pt in pts { ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)), with: .color(.accentColor)) }
        }
    }
}
