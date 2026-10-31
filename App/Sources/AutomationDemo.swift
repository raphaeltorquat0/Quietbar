#if DEBUG
import AppKit
import HeadphoneModel
import MDRKit
import QuietAutomation
import SwiftUI

/// `Quietbar --automation-demo <pasta>`, só em Debug: quadros da cena da automação em chamada, para `scripts/automation-demo.sh`.
/// Cada quadro é uma função do tempo, capturado com `screencapture -l` numa janela do app fora da área visível:
/// a duração e o loop são exatos, e a tela de quem usa o Mac não muda. O idioma é o do processo (`-AppleLanguages`).
@MainActor enum AutomationDemo {
    enum Format: String, CaseIterable {
        case wide = "16x10", square = "1x1", tall = "9x16"

        /// Em pontos: a janela é capturada a 2x.
        var size: CGSize {
            switch self {
            case .wide: CGSize(width: 800, height: 500)
            case .square: CGSize(width: 540, height: 540)
            case .tall: CGSize(width: 540, height: 960)
            }
        }
    }

    nonisolated static let duration = 7.0
    static let fps = 30

    /// Tudo que muda no painel durante a cena.
    struct Script {
        var before: PanelState, during: PanelState, after: PanelState
        var ambientModel: NSImage, cancelingModel: NSImage
    }

    /// `--demo-frames 0,45,51`: só estes quadros, para ajustar o enquadramento.
    private static let only: Set<Int>? = {
        let a = CommandLine.arguments
        return a.firstIndex(of: "--demo-frames").flatMap { a.dropFirst($0 + 1).first }.map { Set($0.split(separator: ",").compactMap { Int($0) }) }
    }()

    /// `--demo-format 9x16`: só este formato.
    private static let onlyFormat: String? = {
        let a = CommandLine.arguments
        return a.firstIndex(of: "--demo-format").flatMap { a.dropFirst($0 + 1).first }
    }()

    static func run(to dir: URL) async {
        let script = await makeScript()
        for dark in [true, false] {
            for format in Format.allCases where format.rawValue == onlyFormat || onlyFormat == nil {
                let out = dir.appending(path: "\(format.rawValue)-\(dark ? "dark" : "light")")
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let clock = DemoClock()
                let w = window(format, dark: dark, script: script, clock: clock)
                try? await Task.sleep(for: .seconds(1)) // o vidro desenha na primeira passada
                for frame in 0..<(Int(duration) * fps) where only.map({ $0.contains(frame) }) ?? true {
                    clock.t = Double(frame) / Double(fps)
                    try? await Task.sleep(for: .milliseconds(40))
                    await PressKit.screencapture(["-x", "-o", "-l\(w.windowNumber)", out.appending(path: String(format: "%04d.png", frame)).path])
                }
                w.orderOut(nil)
                print(out.path)
            }
        }
        exit(0)
    }

    private static func window(_ format: Format, dark: Bool, script: Script, clock: DemoClock) -> NSWindow {
        let w = PressKit.KeyLookPanel(contentRect: NSRect(origin: .zero, size: format.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.colorSpace = .sRGB
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        // O Backdrop soma 36 pt de cada lado.
        let content = CGSize(width: format.size.width - 72, height: format.size.height - 72)
        let scene = DemoScene(format: format, size: content, script: script, clock: clock)
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: PressKit.Backdrop(dark: dark, content: scene))
        host.sizingOptions = [] // ver DECISIONS #63
        w.contentView = host
        w.setContentSize(format.size)
        // Atrás das outras janelas: fora da tela o WindowServer não compõe a janela, e à frente ela cobriria o Mac em uso.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.setFrameOrigin(NSPoint(x: 0, y: 0))
        w.orderFrontRegardless()
        return w
    }

    /// Passa pelo motor real e pelo mesmo texto do indicador do app: a cena não escreve o estado à mão.
    private static func makeScript() async -> Script {
        let device = DemoDevice()
        let engine = AutomationEngine(device: device)
        func state() -> PanelState {
            var p = PanelFixtures.connected(device.mode)
            p.presets = []
            p.speakToChat = nil
            p.dsee = nil
            p.showPlayback = false
            p.macSound = nil
            p.name = String(localized: "Meu fone")
            p.subtitle = "AAC" // sem nome de modelo: a cena não mostra marca de terceiros
            p.automation = Automation.label(for: engine.active)
            return PanelFixtures.withModel(p)
        }
        func settle() async { for _ in 0..<40 { await Task.yield() } }
        let before = state()
        engine.set(.call, Rule(id: "call", name: "Chamada", settings: [.soundMode: .mode(.noiseCanceling)])) // como `Automation.refreshCall`
        await settle()
        let during = state()
        engine.set(.call, nil)
        await settle()
        let after = state()
        func model(_ mode: SoundMode) -> NSImage {
            var s = HeadphoneExport.State()
            s.mode = mode
            s.battery = 0.72
            return HeadphoneExport.snapshotImage(size: CGSize(width: 520, height: 520), state: s)
        }
        return Script(before: before, during: during, after: after, ambientModel: model(.ambient), cancelingModel: model(.noiseCanceling))
    }
}

/// O fone da cena: lê e escreve o que o motor pede, como a ponte do app faz com o fone real.
@MainActor private final class DemoDevice: AutomationDevice {
    var mode = SoundMode.ambient
    var heldMode: SoundMode?

    func read(headphone: Bool) async -> DeviceReading? {
        DeviceReading(settings: [.soundMode: .mode(mode)], check: .notNeeded)
    }

    func write(_ changes: QuietAutomation.Settings) async throws -> QuietAutomation.Settings {
        if case .mode(let m)? = changes[.soundMode] { mode = m }
        return changes
    }
}

@MainActor @Observable private final class DemoClock {
    var t = 0.0
}

/// 0 antes de `a`, 1 depois de `b`, com início e fim suaves.
private func rise(_ t: Double, _ a: Double, _ b: Double) -> Double {
    let x = min(1, max(0, (t - a) / (b - a)))
    return x * x * (3 - 2 * x)
}

/// `cycles` voltas inteiras nos 7 s da cena: é o que fecha o loop.
private func loop(_ t: Double, _ cycles: Int) -> Double { t / AutomationDemo.duration * Double(cycles) }

private struct DemoScene: View {
    let format: AutomationDemo.Format
    let size: CGSize
    let script: AutomationDemo.Script
    let clock: DemoClock

    private var t: Double { clock.t }
    /// A chamada na tela.
    private var call: Double { rise(t, 0.8, 1.2) * (1 - rise(t, 5.0, 5.4)) }
    /// 0 com ruído, 1 com a linha reta: 400 ms para colapsar, 600 ms para voltar.
    private var calm: Double { rise(t, 1.5, 1.9) * (1 - rise(t, 5.6, 6.2)) }
    private var canceling: Double { rise(t, 1.5, 1.7) }
    private var restored: Double { rise(t, 5.6, 5.8) }
    private var started: Double { rise(t, 1.5, 1.7) * (1 - rise(t, 4.9, 5.1)) }
    private var ended: Double { rise(t, 5.6, 5.8) * (1 - rise(t, 6.7, 6.9)) }

    /// Pelo menos 6% da altura do quadro, com os 72 pt do Backdrop de volta na conta.
    private var captionSize: CGFloat { ((size.height + 72) * 0.06).rounded(.up) }

    var body: some View {
        Group {
            switch format {
            case .wide: wide
            case .square: square
            case .tall: tall
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var wide: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                panel(scale: 0.95)
                ZStack(alignment: .topTrailing) {
                    stage(side: 236).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 34)
                    callWindow(width: 216).padding([.top, .trailing], 26).offset(x: (1 - call) * 420).opacity(call > 0 ? 1 : 0)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            captions.frame(height: 78)
        }
    }

    private var square: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                panel(scale: 0.74)
                VStack(spacing: 6) {
                    stage(side: 158)
                    callWindow(width: 188).padding(.trailing, 14).offset(x: (1 - call) * 330).opacity(call > 0 ? 1 : 0)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            captions.frame(height: 106)
        }
    }

    /// Recomposto, não recortado: a chamada em cima e o painel embaixo. Sem chamada, o fone cresce e ocupa o lugar dela.
    private var tall: some View {
        VStack(spacing: 5) {
            captions.frame(height: 290)
            callWindow(width: 262).offset(y: -(1 - call) * 560).opacity(call > 0 ? 1 : 0).frame(height: 178)
            stage(side: 142).scaleEffect(1 + (1 - call) * 0.8).offset(y: -(1 - call) * 150).frame(height: 110)
            panel(scale: 0.84).frame(height: 290, alignment: .top)
        }
    }

    // MARK: Painel real

    /// Duas `PanelView` reais, antes e depois, com fusão: a captura é por tempo e não pega a animação do app.
    private func panel(scale: CGFloat) -> some View {
        ZStack(alignment: .top) {
            PanelView(state: script.before).opacity(1 - canceling)
            PanelView(state: script.during).opacity(canceling * (1 - restored))
            PanelView(state: script.after).opacity(restored)
        }
        .scaleEffect(scale, anchor: .top)
        .frame(width: 320 * scale)
    }

    // MARK: Ruído

    private func stage(side: CGFloat) -> some View {
        ZStack {
            Canvas { c, s in drawWaves(c, s) }
            Image(nsImage: script.ambientModel).resizable().scaledToFit().opacity(1 - canceling + restored).padding(side * 0.22)
            Image(nsImage: script.cancelingModel).resizable().scaledToFit().opacity(canceling * (1 - restored)).padding(side * 0.22)
            bubble(x: -0.40, y: -0.30, cycle: 0, side: side)
            bubble(x: 0.40, y: -0.34, cycle: 1, side: side)
            bubble(x: 0.36, y: 0.34, cycle: 2, side: side)
        }
        .frame(width: side, height: side)
    }

    /// Anéis que achatam em `calm` até virar uma única linha reta.
    private func drawWaves(_ c: GraphicsContext, _ s: CGSize) {
        let center = CGPoint(x: s.width / 2, y: s.height / 2)
        let maxR = min(s.width, s.height) / 2 - 2, minR = maxR * 0.45
        let rings = 5
        for i in 0..<rings {
            let phase = (Double(i) / Double(rings) + loop(t, 3)).truncatingRemainder(dividingBy: 1)
            let r = (minR + (maxR - minR) * phase) * (1 - calm) + maxR * calm
            let alpha = sin(.pi * phase) * 0.7 * (1 - calm) + 0.9 * calm
            var path = Path()
            for step in 0...120 {
                let a = Double(step) / 120 * 2 * .pi
                let wobble = (1 - calm) * maxR * 0.03 * sin(6 * a + 2 * .pi * (loop(t, 2) + Double(i) / 3))
                let p = CGPoint(x: center.x + (r + wobble) * cos(a), y: center.y + (r + wobble) * sin(a) * (1 - calm))
                if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            c.stroke(path, with: .color(Color.accentColor.opacity(alpha)), lineWidth: 2)
        }
    }

    private func bubble(x: CGFloat, y: CGFloat, cycle: Int, side: CGFloat) -> some View {
        let visible = 1 - calm
        return Image(systemName: "ellipsis.bubble.fill")
            .font(.system(size: side * 0.15))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.primary)
            .scaleEffect(0.5 + 0.5 * visible)
            .opacity(visible)
            .offset(x: x * side, y: y * side + 5 * sin(2 * .pi * (loop(t, 2) + Double(cycle) / 3)))
    }

    // MARK: Chamada genérica

    private func callWindow(width: CGFloat) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.28)).frame(width: 8, height: 8) }
                Spacer()
                Circle().fill(.orange).frame(width: 7, height: 7)
            }
            .frame(height: 12)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                ForEach(0..<4, id: \.self) { i in avatar(i).frame(height: width * 0.27) }
            }
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                Image(systemName: "video.fill")
                Image(systemName: "phone.down.fill").foregroundStyle(.red)
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).frame(height: 14)
        }
        .padding(8)
        .frame(width: width)
        .background(Color(white: 0.11), in: .rect(cornerRadius: 12))
        .overlay(alignment: .topTrailing) { micHighlight.offset(x: 22, y: format == .tall ? 6 : -22) }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private func avatar(_ i: Int) -> some View {
        let tints: [(Color, Color)] = [(.teal, .indigo), (.pink, .purple), (.orange, .pink), (.mint, .blue)]
        let speaking = i == 1
        return GeometryReader { g in
            let h = g.size.height
            ZStack {
                LinearGradient(colors: [tints[i].0, tints[i].1], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.85)).frame(width: h * 0.40).offset(y: -h * 0.12)
                Ellipse().fill(.white.opacity(0.85)).frame(width: h * 0.78, height: h * 0.52).offset(y: h * 0.42)
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(.green, lineWidth: 2).opacity(speaking ? 0.5 + 0.5 * sin(2 * .pi * loop(t, 4)) : 0)
            }
        }
    }

    /// Destaque ampliado do ponto laranja de microfone em uso.
    private var micHighlight: some View {
        let pulse = 1 + 0.06 * sin(2 * .pi * loop(t, 4))
        return ZStack {
            Circle().fill(.orange.opacity(0.25)).frame(width: 58, height: 58).scaleEffect(pulse)
            Circle().fill(.orange).frame(width: 40, height: 40)
            Image(systemName: "mic.fill").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
        }
    }

    // MARK: Legendas

    private var captions: some View {
        ZStack {
            caption("Chamada começou. Cancelamento automático.").opacity(started)
            caption("Chamada acabou. De volta ao ambiente.").opacity(ended)
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: captionSize, weight: .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(5)
            .frame(maxWidth: .infinity)
            .foregroundStyle(.primary)
    }
}
#endif
