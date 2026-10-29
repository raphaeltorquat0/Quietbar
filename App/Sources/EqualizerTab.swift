import MDRKit
import SwiftUI

struct EqualizerTab: View {
    @Environment(DeviceController.self) private var device
    @State private var draft: [Int]?
    @State private var newName = ""

    private let labels = ["Clear Bass"] + EqualizerParam.fiveBandLabels

    var body: some View {
        let s = device.state
        let eq = s.equalizer
        let values = draft ?? eq.flatMap { e in e.clearBass.map { [$0] + e.bands } } ?? Array(repeating: 0, count: 6)
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
                if eq?.isFiveBand == true {
                    EqualizerCurve(values: Array(values.dropFirst())).frame(height: 80)
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(0..<6, id: \.self) { i in
                            VStack(spacing: 4) {
                                Text(values[i] > 0 ? "+\(values[i])" : "\(values[i])").monospacedDigit().font(.caption)
                                VerticalSlider(value: values[i]) { v in
                                    var d = values
                                    d[i] = v
                                    draft = d
                                } onCommit: { commit() }
                                Text(labels[i]).font(.caption2).foregroundStyle(i == 0 ? .blue : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 190)
                    HStack {
                        Button("Zerar") { draft = Array(repeating: 0, count: 6); commit() }
                        Spacer()
                        Text("Editar aplica no preset Custom (ou no User Setting selecionado).").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Este fone não expõe o equalizador de 5 bandas.").foregroundStyle(.secondary)
                }
            }
            Section("Presets salvos neste Mac") {
                ForEach(device.settings.savedEqualizers) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Text(([p.clearBass] + p.bands).map(String.init).joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button("Aplicar") { device.perform { try await $0.setEqualizer(clearBass: p.clearBass, bands: p.bands) } }
                            .disabled(!device.isReady)
                        Button(role: .destructive) { device.settings.savedEqualizers.removeAll { $0.id == p.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Nome", text: $newName)
                    Button("Salvar curva atual") {
                        device.settings.savedEqualizers.append(SavedEqualizer(name: newName, clearBass: values[0], bands: Array(values.dropFirst())))
                        newName = ""
                    }
                    .disabled(newName.isEmpty || eq?.isFiveBand != true)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: eq) { draft = nil } // o fone respondeu: volta a mostrar o valor dele
    }

    private func commit() {
        guard let d = draft else { return }
        device.perform { try await $0.setEqualizer(clearBass: d[0], bands: Array(d.dropFirst())) }
    }
}

struct VerticalSlider: View {
    let value: Int
    let onChange: (Int) -> Void
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { g in
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }), in: -10...10, step: 1) { editing in
                if !editing { onCommit() }
            }
            .rotationEffect(.degrees(-90))
            .frame(width: g.size.height)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
    }
}

/// Curva suave pelas 5 bandas (−10…+10 dB).
struct EqualizerCurve: View {
    let values: [Int]

    var body: some View {
        Canvas { ctx, size in
            let pts = values.enumerated().map { i, v in
                CGPoint(x: size.width * (CGFloat(i) + 0.5) / CGFloat(values.count),
                        y: size.height / 2 - CGFloat(v) / 10 * (size.height / 2 - 4))
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
