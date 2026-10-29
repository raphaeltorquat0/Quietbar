import AppKit
import SwiftUI

/// Quando true, o painel está sendo renderizado pelo ImageRenderer (que não desenha NSViews):
/// fundo e modelo 3D viram equivalentes estáticos.
struct PanelSnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var panelSnapshot: Bool {
        get { self[PanelSnapshotKey.self] }
        set { self[PanelSnapshotKey.self] = newValue }
    }
}

/// Animação curta do painel (≤ 250 ms); com Reduzir movimento vira um fade curto.
func panelAnimation(_ reduceMotion: Bool) -> Animation {
    reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.25, bounce: 0.15)
}

// MARK: - Fundo

/// Liquid Glass no macOS 26+, material `.popover` ativo antes disso, sólido com Reduzir transparência.
struct PanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.panelSnapshot) private var snapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if reduceTransparency || snapshot {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                .overlay(snapshot ? Rectangle().fill(scheme == .dark ? Color(white: 0.13) : Color(white: 0.95)) : nil)
        } else if #available(macOS 26, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            VisualEffect(material: .popover)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Módulo (card)

struct PanelModule<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(contrast == .increased ? 0.25 : 0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
                }
            }
    }
}

// MARK: - Botão com hover

/// Estilo para botões "sem chrome": fundo sutil no hover, leve escala ao pressionar.
struct HoverButtonStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(Capsule())
    var padding: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration, shape: shape, padding: padding) }

    private struct HoverBody: View {
        let configuration: Configuration
        let shape: AnyShape
        let padding: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(padding)
                .contentShape(shape)
                .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering && enabled ? 0.08 : 0)))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Slider cápsula (Central de Controle)

/// Cápsula grossa (28 pt) com ícone à esquerda, sem marcações nem número; o valor aparece num
/// balão só durante o arraste. Envia ao soltar. Setas do teclado ajustam de 1 em 1.
struct CapsuleSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    let icon: String
    let label: LocalizedStringKey
    let commit: (Int) -> Void

    @State private var draft: Double?
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    private var span: Double { Double(range.upperBound - range.lowerBound) }
    private var fraction: Double { ((draft ?? Double(value)) - Double(range.lowerBound)) / span }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h: CGFloat = 28
            let fillW = max(h, CGFloat(fraction) * w)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.30 : scheme == .dark ? 0.13 : 0.20))
                Capsule().fill(scheme == .dark ? Color.white : Color.white)
                    .frame(width: fillW)
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 1, y: 0.5)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(white: 0.35))
                    .frame(width: h, height: h)
            }
            .frame(height: h)
            .overlay(alignment: .topLeading) {
                if let d = draft {
                    Text(verbatim: "\(Int(d.rounded()))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .fixedSize()
                        .offset(x: min(max(0, fillW - 16), w - 32), y: -26)
                        .transition(.opacity)
                }
            }
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2).opacity(focused ? 1 : 0))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let f = min(1, max(0, g.location.x / w))
                    withAnimation(.easeOut(duration: 0.1)) { draft = Double(range.lowerBound) + f * span }
                }
                .onEnded { _ in
                    if let d = draft { commit(Int(d.rounded())) }
                    withAnimation(.easeOut(duration: 0.15)) { draft = nil }
                })
        }
        .frame(height: 28)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text(verbatim: "\(value)"))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: _ = step(1)
            case .decrement: _ = step(-1)
            @unknown default: break
            }
        }
    }

    private func step(_ d: Int) -> KeyPress.Result {
        commit(min(range.upperBound, max(range.lowerBound, value + d)))
        return .handled
    }
}

// MARK: - Anel de bateria

struct BatteryRing: View {
    let level: Int
    let charging: Bool

    private var color: Color { level <= 10 ? .red : level <= 20 ? .orange : .green }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3.5)
            Circle().trim(from: 0, to: CGFloat(level) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                if charging { Image(systemName: "bolt.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(color) }
                (Text(verbatim: "\(level)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    + Text(verbatim: "%").font(.system(size: 7, weight: .semibold)))
                    .fixedSize()
            }
        }
        .frame(width: 38, height: 38)
        .accessibilityElement()
        .accessibilityLabel("Bateria")
        .accessibilityValue(charging ? Text("\(level)%, carregando") : Text(verbatim: "\(level)%"))
    }
}

// MARK: - Mini curva do EQ

struct EqualizerSparkline: View {
    /// Clear Bass + 5 bandas (±10 dB) ou 10 bandas (±6 dB).
    let bands: [Int]
    var limit = 10

    var body: some View {
        Canvas { ctx, size in
            guard bands.count > 1 else { return }
            let pts = bands.enumerated().map { i, v in
                CGPoint(x: size.width * CGFloat(i) / CGFloat(bands.count - 1),
                        y: size.height / 2 - CGFloat(v) / CGFloat(limit) * (size.height / 2 - 2))
            }
            var mid = Path()
            mid.move(to: CGPoint(x: 0, y: size.height / 2))
            mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(mid, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            var p = Path()
            p.move(to: pts[0])
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                p.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
            }
            ctx.stroke(p, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        .frame(width: 52, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - Skeleton

struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.6)
                }
                .mask(content)
                .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 } }
            }
        }
    }
}

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var radius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.10))
            .frame(width: width, height: height)
    }
}
