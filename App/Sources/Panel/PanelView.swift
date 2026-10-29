import AppKit
import HeadphoneModel
import MDRKit
import SwiftUI

/// Tudo que o painel mostra, já traduzido para a UI (sem termos do protocolo).
struct PanelState {
    enum Phase: Equatable { case ready, loading, disconnected(message: LocalizedStringKey) }
    struct Preset: Identifiable, Hashable { let id: UInt8; let name: String }

    var phase: Phase = .ready
    var name = ""
    var subtitle = ""
    var link: Link = .ready
    var battery: Int?
    var charging = false
    /// Earbuds (WF-*, LinkBuds): nível de cada lado e do estojo; `nil` = lado ausente.
    var earbuds: EarbudsLevels?

    struct EarbudsLevels: Equatable {
        var left: Int?
        var right: Int?
        var caseLevel: Int?
    }

    var mode: SoundMode?
    /// Modos que o fone oferece (só ambiente em alguns modelos, ex.: WF-C510).
    var modes: [SoundMode] = SoundMode.allCases
    var ambientLevel = 10
    var focusOnVoice = false

    var presets: [Preset] = []
    var presetID: UInt8?
    var bands: [Int] = []
    /// Limite em dB da curva (10 no layout Clear Bass + 5, 6 no de 10 bandas).
    var bandsLimit = 10

    var speakToChat: Bool?
    var dsee: Bool?
    var dseeTitle = "DSEE Extreme"
    var dseeAvailable = true

    var showPlayback = false
    var isPlaying = false
    var volume: Int?
    var nowPlaying: (title: String, artist: String?)?

    var accent = HeadphoneSpec.default.accent
    var use3D = true
    var lightRing = false
    var customModel: URL?
    var customImage: NSImage?
    /// Imagem fixa do modelo (previews renderizados; o ImageRenderer não desenha a view 3D).
    var modelSnapshot: NSImage?

    enum Link { case ready, bluetoothOnly, off }
}

struct PanelActions {
    var setMode: @MainActor @Sendable (SoundMode) -> Void = { _ in }
    var setAmbient: @MainActor @Sendable (Int) -> Void = { _ in }
    var setFocusOnVoice: @MainActor @Sendable (Bool) -> Void = { _ in }
    var setPreset: @MainActor @Sendable (UInt8) -> Void = { _ in }
    var setSpeakToChat: @MainActor @Sendable (Bool) -> Void = { _ in }
    var setDSEE: @MainActor @Sendable (Bool) -> Void = { _ in }
    var previous: @MainActor @Sendable () -> Void = {}
    var playPause: @MainActor @Sendable () -> Void = {}
    var next: @MainActor @Sendable () -> Void = {}
    var setVolume: @MainActor @Sendable (Int) -> Void = { _ in }
    var connect: @MainActor @Sendable () -> Void = {}
    var disconnect: @MainActor @Sendable () -> Void = {}
    var openSettings: @MainActor @Sendable () -> Void = {}
    var quit: @MainActor @Sendable () -> Void = {}
}

struct PanelView: View {
    let state: PanelState
    var actions = PanelActions()
    var entranceID = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            header
            switch state.phase {
            case .ready:
                if state.mode != nil { soundModule }
                if !state.presets.isEmpty || state.speakToChat != nil || state.dsee != nil { audioModule }
                if state.showPlayback { playbackModule }
            case .loading:
                LoadingModules()
            case .disconnected(let message):
                disconnectedModule(message)
            }
            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(PanelBackground())
        .animation(panelAnimation(reduceMotion), value: state.mode)
        .animation(panelAnimation(reduceMotion), value: state.phase)
    }

    // MARK: 1. Cabeçalho

    private var header: some View {
        PanelModule {
            HStack(spacing: 10) {
                HeaderVisual(state: state, entranceID: entranceID)
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        // Nome longo (ex.: "Fone do Raphael"): tenta title3, depois headline, por fim quebra em 2 linhas.
                        ViewThatFits(in: .horizontal) {
                            Text(verbatim: state.name).font(.title3.weight(.semibold)).lineLimit(1)
                            Text(verbatim: state.name).font(.headline).lineLimit(1)
                            Text(verbatim: state.name).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Circle().fill(dotColor).frame(width: 7, height: 7)
                            .accessibilityLabel(linkLabel)
                    }
                    if !state.subtitle.isEmpty {
                        Text(verbatim: state.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let e = state.earbuds, state.phase == .ready {
                        EarbudsBatteryRow(levels: e).padding(.top, 2)
                    }
                }
                Spacer(minLength: 2)
                if state.earbuds == nil, let b = state.battery, state.phase == .ready {
                    BatteryRing(level: b, charging: state.charging)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var dotColor: Color {
        switch state.link {
        case .ready: .green
        case .bluetoothOnly: .yellow
        case .off: .secondary.opacity(0.6)
        }
    }

    private var linkLabel: LocalizedStringKey {
        switch state.link {
        case .ready: "Conectado"
        case .bluetoothOnly: "Conectado ao Mac, controle em pausa"
        case .off: "Desconectado"
        }
    }

    // MARK: 2. Modo de som

    private var soundModule: some View {
        PanelModule {
            ModeButtons(mode: state.mode, modes: state.modes, select: actions.setMode)
            if state.mode == .ambient {
                VStack(spacing: 8) {
                    CapsuleSlider(value: state.ambientLevel, range: 1...20, icon: "ear", label: "Nível do som ambiente",
                                  commit: actions.setAmbient)
                    ToggleRow(title: "Foco na voz", subtitle: "Deixa vozes mais claras que o resto",
                              isOn: state.focusOnVoice, set: actions.setFocusOnVoice)
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: 3. Áudio

    private var audioModule: some View {
        PanelModule {
            if !state.presets.isEmpty {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Equalizador")
                        PanelMenu(title: state.presets.first { $0.id == state.presetID }?.name ?? "—") {
                            ForEach(state.presets) { p in
                                Button { actions.setPreset(p.id) } label: {
                                    if p.id == state.presetID { Label(p.name, systemImage: "checkmark") } else { Text(verbatim: p.name) }
                                }
                            }
                        }
                        .accessibilityLabel("Equalizador")
                    }
                    Spacer()
                    if !state.bands.isEmpty { EqualizerSparkline(bands: state.bands, limit: state.bandsLimit) }
                }
            }
            if let stc = state.speakToChat {
                ToggleRow(title: "Falar para conversar", subtitle: "Pausa a música quando você fala", isOn: stc, set: actions.setSpeakToChat)
            }
            if let dsee = state.dsee {
                ToggleRow(title: LocalizedStringKey(state.dseeTitle), subtitle: "Melhora áudio comprimido", isOn: dsee, set: actions.setDSEE)
                    .disabled(!state.dseeAvailable)
            }
        }
    }

    // MARK: 4. Reprodução

    private var playbackModule: some View {
        PanelModule {
            if let np = state.nowPlaying {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: np.title).font(.callout.weight(.medium)).lineLimit(1)
                    if let a = np.artist { Text(verbatim: a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 18) {
                Spacer()
                transport("backward.fill", size: 15, label: "Faixa anterior", action: actions.previous)
                transport(state.isPlaying ? "pause.fill" : "play.fill", size: 22, label: state.isPlaying ? "Pausar" : "Tocar",
                          action: actions.playPause)
                transport("forward.fill", size: 15, label: "Próxima faixa", action: actions.next)
                Spacer()
            }
            if let v = state.volume {
                CapsuleSlider(value: v, range: 0...30, icon: "speaker.wave.2.fill", label: "Volume", commit: actions.setVolume)
            }
        }
    }

    private func transport(_ symbol: String, size: CGFloat, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(HoverButtonStyle(shape: AnyShape(Circle()), padding: 2))
        .accessibilityLabel(label)
    }

    // MARK: Desconectado

    private func disconnectedModule(_ message: LocalizedStringKey) -> some View {
        PanelModule {
            VStack(spacing: 10) {
                Image(systemName: "headphones")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Conectar", action: actions.connect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    // MARK: Rodapé

    private var footer: some View {
        HStack {
            Button(action: actions.openSettings) {
                Label("Configurações…", systemImage: "gearshape")
            }
            .buttonStyle(HoverButtonStyle(padding: 6))
            Spacer()
            PanelMenu(icon: "ellipsis") {
                if state.link != .off { Button("Desconectar", action: actions.disconnect) }
                Button("Sair do Quietbar", action: actions.quit)
            }
            .accessibilityLabel("Mais opções")
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Peças

/// Modelo 3D (ou ilustração) de 84 pt, sem glow; só a sombra de contato do próprio modelo.
private struct HeaderVisual: View {
    let state: PanelState
    let entranceID: Int
    @State private var failed3D = false
    @Environment(\.panelSnapshot) private var snapshot

    var body: some View {
        if let img = state.modelSnapshot, snapshot, state.earbuds == nil {
            Image(nsImage: img).resizable().scaledToFit()
        } else if state.earbuds != nil, state.customModel == nil, state.customImage == nil {
            // Earbuds: o 3D é de um fone over-ear; até existir um modelo de earbuds, vai o símbolo.
            EarbudsVisual()
        } else if failed3D || !state.use3D {
            HeadphoneIllustration(battery: Double(state.battery ?? 0) / 100,
                                  accent: Color(red: Double(state.accent.x), green: Double(state.accent.y), blue: Double(state.accent.z)),
                                  image: state.customImage)
        } else {
            HeadphoneView(battery: state.battery.map { Double($0) / 100 }, mode: state.mode, accent: state.accent,
                          customModel: state.customModel, entranceID: entranceID, idleRotation: false,
                          lightRing: state.lightRing) { failed3D = true }
        }
    }
}

/// Três botões circulares de 44 pt; o preenchimento de destaque desliza entre eles.
struct ModeButtons: View {
    let mode: SoundMode?
    var modes: [SoundMode] = SoundMode.allCases
    let select: (SoundMode) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(modes, id: \.self) { m in
                Button { select(m) } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(Color.primary.opacity(0.10))
                            if m == mode {
                                Circle().fill(Color.accentColor).matchedGeometryEffect(id: "active", in: ns)
                            }
                            Image(systemName: m.panelSymbol)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(m == mode ? Color.white : Color.primary)
                        }
                        .frame(width: 44, height: 44)
                        Text(m.panelLabel).font(.caption).foregroundStyle(m == mode ? .primary : .secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(HoverButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 10)), padding: 4))
                .accessibilityLabel(m.panelLabel)
                .accessibilityAddTraits(m == mode ? .isSelected : [])
            }
        }
    }
}

struct ToggleRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let isOn: Bool
    let set: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PanelSwitch(isOn: isOn, set: set)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? Text("Ligado") : Text("Desligado"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { set(!isOn) }
    }
}

/// Toggle switch nativo; no snapshot (ImageRenderer não desenha AppKit) vira um desenho equivalente.
struct PanelSwitch: View {
    let isOn: Bool
    let set: @MainActor @Sendable (Bool) -> Void
    @Environment(\.panelSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
                .frame(width: 32, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).shadow(radius: 0.5).padding(2)
                }
        } else {
            Toggle("", isOn: Binding(get: { isOn }, set: { v in MainActor.assumeIsolated { set(v) } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// Menu sem borda; no snapshot vira o rótulo desenhado.
struct PanelMenu<Items: View>: View {
    var title: String? = nil
    var icon: String? = nil
    @ViewBuilder let items: () -> Items
    @Environment(\.panelSnapshot) private var snapshot

    private var label: some View {
        HStack(spacing: 3) {
            if let title { Text(verbatim: title).foregroundStyle(.secondary).lineLimit(1) }
            if let icon { Image(systemName: icon).frame(width: 24, height: 20) }
            if title != nil { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .font(title != nil ? .caption : .body)
    }

    var body: some View {
        if snapshot {
            label
        } else {
            Menu { items() } label: { label }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }
}

/// Esqueleto com brilho enquanto o canal abre.
private struct LoadingModules: View {
    var body: some View {
        VStack(spacing: 8) {
            PanelModule {
                HStack {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(spacing: 6) { SkeletonBlock(width: 44, height: 44, radius: 22); SkeletonBlock(width: 56, height: 9) }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            PanelModule {
                SkeletonBlock(height: 14)
                SkeletonBlock(width: 180, height: 14)
                SkeletonBlock(width: 140, height: 14)
            }
        }
        .modifier(Shimmer())
        .accessibilityElement()
        .accessibilityLabel("Carregando os ajustes do fone")
    }
}

extension SoundMode {
    var panelLabel: LocalizedStringKey {
        switch self {
        case .noiseCanceling: "Cancelar ruído"
        case .ambient: "Ambiente"
        case .off: "Desligado"
        }
    }

    var panelSymbol: String {
        switch self {
        case .noiseCanceling: "person.wave.2.fill"
        case .ambient: "ear.fill"
        case .off: "circle.slash"
        }
    }
}

/// Nomes de preset em PT-BR (o fone manda só IDs); "User Setting N" vira "Personalizado N"
/// ou o nome que o usuário deu nas Configurações.
enum PresetNames {
    static func name(_ id: UInt8, custom: [String: String] = [:]) -> String {
        if let c = custom[String(id)], !c.isEmpty { return c }
        switch id {
        case 0x00: return String(localized: "Desligado")
        case 0x10: return String(localized: "Brilhante")
        case 0x11: return String(localized: "Animado")
        case 0x12: return String(localized: "Suave")
        case 0x13: return String(localized: "Relaxado")
        case 0x14: return String(localized: "Vocal")
        case 0x15: return String(localized: "Agudos realçados")
        case 0x16: return String(localized: "Graves realçados")
        case 0x17: return String(localized: "Fala")
        case 0x30: return String(localized: "Pesado")
        case 0x31: return String(localized: "Claro")
        case 0x32: return String(localized: "Forte")
        case 0x33: return String(localized: "Leve")
        case 0xA0: return String(localized: "Personalizado")
        case 0xA1...0xA5: return String(localized: "Personalizado \(Int(id - 0xA0))")
        default: return String(localized: "Predefinição \(Int(id))")
        }
    }
}

/// Símbolo de earbuds no lugar do modelo 3D over-ear.
struct EarbudsVisual: View {
    var body: some View {
        Image(systemName: "earbuds")
            .resizable()
            .scaledToFit()
            .fontWeight(.light)
            .foregroundStyle(.primary.opacity(0.85))
            .padding(14)
    }
}

/// Esquerdo, direito e estojo em uma linha compacta; lado ausente some.
struct EarbudsBatteryRow: View {
    let levels: PanelState.EarbudsLevels

    var body: some View {
        HStack(spacing: 10) {
            item("earbud.left", levels.left, label: "Esquerdo")
            item("earbud.right", levels.right, label: "Direito")
            item("earbuds.case", levels.caseLevel, label: "Estojo")
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder
    private func item(_ symbol: String, _ level: Int?, label: LocalizedStringKey) -> some View {
        if let level {
            HStack(spacing: 3) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(verbatim: "\(level)%").foregroundStyle(level <= 10 ? .red : level <= 20 ? .orange : .primary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(Text(verbatim: "\(level)%"))
        }
    }
}
