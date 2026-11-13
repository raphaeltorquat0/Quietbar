#if DEBUG
import AppKit
import HeadphoneModel
import MDRKit
import MDRSimulator
import SwiftUI

/// `Quietbar --press-kit <pasta>`, só em Debug: imagens de divulgação sem capturar a área de trabalho.
/// Cada imagem é uma janela opaca do próprio app, com o gradiente dentro dela: o vidro amostra o
/// gradiente, e `screencapture -l` pega só essa janela. O `demo.mov` grava o retângulo exato de uma
/// janela acima de tudo; `scripts/press-kit.sh` o converte em GIF.
@MainActor enum PressKit {
    private static let panels: [(String, PanelState)] = [
        ("nc", PanelFixtures.connected(.noiseCanceling)),
        ("ambiente", PanelFixtures.connected(.ambient)),
        ("desconectado", PanelFixtures.disconnected),
        ("carregando", PanelFixtures.loading),
        ("wf", PanelFixtures.wf1000xm5),
        ("clip", PanelFixtures.linkBudsClip),
    ]

    static func run(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Imagem de prévia do repositório (Settings › Social preview), 1280×640 com a margem do `Backdrop`.
        if CommandLine.arguments.contains("--social-preview") {
            await shot(SocialPreview(), dark: true, to: dir.appending(path: "social-preview.png"))
            exit(0)
        }
        // Só o GIF, no idioma do processo: o script grava uma vez por idioma (`-AppleLanguages`).
        if CommandLine.arguments.contains("--demo-only") {
            await record(to: dir.appending(path: "demo.mov"))
            exit(0)
        }
        for dark in [true, false] {
            let suffix = dark ? "escuro" : "claro"
            for (name, state) in panels {
                await shot(PanelView(state: state), dark: dark, to: dir.appending(path: "painel-\(name)-\(suffix).png"))
            }
            // Um painel por modelo, pelo mesmo caminho do app, com o fone simulado.
            for profile in Profiles.all {
                await Simulation.shared.start(profile)
                await DeviceController.shared.ensureConnected()
                try? await Task.sleep(for: .seconds(0.5)) // as respostas do sync chegam depois do handshake
                var state = PanelState.from(DeviceController.shared)
                state.simulated = nil
                await shot(PanelView(state: state), dark: dark, to: dir.appending(path: "modelo-\(profile.id)-\(suffix).png"))
            }
            await Simulation.shared.stop()
            await shot(popup(PopupModel()), dark: dark, to: dir.appending(path: "popup-\(suffix).png"))
            await shot(model, dark: dark, to: dir.appending(path: "modelo-3d-\(suffix).png"))
        }
        await record(to: dir.appending(path: "demo.mov"))
        exit(0)
    }

    private static func popup(_ m: PopupModel, seconds: Double = 60) -> some View {
        m.demo = PopupDemo(name: String(localized: "Meu fone"), level: 72)
        m.reset(duration: seconds)
        return PopupView(model: m) {}.environment(DeviceController.shared)
    }

    private static var model: some View {
        Image(nsImage: HeadphoneExport.snapshotImage(size: CGSize(width: 900, height: 900)))
            .resizable().frame(width: 420, height: 420)
    }

    private static func shot(_ content: some View, dark: Bool, to url: URL) async {
        let w = window(content, dark: dark)
        try? await Task.sleep(for: .seconds(2.5)) // modelo 3D e animações de entrada
        await focus(w)
        if !w.isKeyWindow { print("sem foco: \(url.lastPathComponent)") }
        await screencapture(["-x", "-o", "-l\(w.windowNumber)", url.path])
        w.orderOut(nil)
        print(url.path)
    }

    /// Insiste até a janela receber o foco: outro app pode tomá-lo enquanto o script roda.
    private static func focus(_ w: NSWindow) async {
        for _ in 0..<40 where !w.isKeyWindow {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.25))
        }
    }

    private static func record(to url: URL) async {
        let height = DemoScene.panelHeight
        let w = window(DemoScene(panelHeight: height).environment(DeviceController.shared), dark: true)
        // O hosting view só conhece a altura final depois da troca de modo; o tamanho é o do roteiro.
        w.setContentSize(NSSize(width: 776, height: height + 72))
        w.center()
        // A gravação é de um retângulo da tela e pega o cursor: a janela vai para o lado sem ele.
        let mouse = NSEvent.mouseLocation, screen = NSScreen.screens[0].visibleFrame
        if w.frame.insetBy(dx: -40, dy: -40).contains(mouse) {
            let x = mouse.x < screen.midX ? screen.maxX - w.frame.width - 20 : screen.minX + 20
            w.setFrameOrigin(NSPoint(x: x, y: w.frame.minY))
        }
        await focus(w)
        try? FileManager.default.removeItem(at: url)
        // `-R` usa a origem no canto superior esquerdo da tela principal.
        let f = w.frame, top = NSScreen.screens[0].frame.maxY - f.maxY
        await screencapture(["-x", "-v", "-V", "18", "-R", "\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))", url.path])
        w.orderOut(nil)
        print(url.path)
    }

    private static func window(_ content: some View, dark: Bool) -> NSWindow {
        let w = KeyLookPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.level = .screenSaver
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Backdrop(dark: dark, content: content))
        host.sizingOptions = [] // ver DECISIONS #63
        w.contentView = host
        w.setContentSize(NSSize(width: host.fittingSize.width.rounded(.up), height: host.fittingSize.height.rounded(.up)))
        w.center()
        w.makeKeyAndOrderFront(nil)
        return w
    }

    static func screencapture(_ args: [String]) async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in c.resume() }
            do { try p.run() } catch { c.resume() }
        }
    }
}

extension PressKit {
    /// Com foco, como o painel real: sem ele, os controles perdem a cor e ligado parece desligado.
    final class KeyLookPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

extension PressKit {
struct Backdrop<Content: View>: View {
    let dark: Bool
    let content: Content

    var body: some View {
        content
            .fixedSize()
            .padding(36)
            .background(LinearGradient(colors: dark ? [Color(red: 0.08, green: 0.13, blue: 0.32), Color(red: 0.30, green: 0.12, blue: 0.40)]
                                                    : [Color(red: 0.62, green: 0.78, blue: 0.98), Color(red: 0.95, green: 0.75, blue: 0.85)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
}

/// Prévia do repositório: nome, frase e os painéis do Sony e do JBL, só com o cabeçalho e os modos.
private struct SocialPreview: View {
    var body: some View {
        HStack(spacing: 48) {
            VStack(alignment: .leading, spacing: 18) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 128, height: 128)
                Text(verbatim: "Quietbar").font(.system(size: 64, weight: .bold))
                Text(verbatim: "Sony and JBL headphones, from the macOS menu bar.").font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 440, alignment: .leading)
            HStack(alignment: .top, spacing: 20) {
                PanelView(state: Self.compact(PanelFixtures.connected(.noiseCanceling)))
                PanelView(state: Self.compact(PanelFixtures.jblLiveBeam4, mode: .ambient))
            }
        }
        .frame(width: 1208, height: 568)
    }

    private static func compact(_ state: PanelState, mode: SoundMode? = nil) -> PanelState {
        var p = state
        if let mode { p.mode = mode }
        p.presets = []
        p.speakToChat = nil
        p.dsee = nil
        p.showPlayback = false
        p.macSound = nil
        return p
    }
}

/// Roteiro do GIF: o Sony conecta e troca de modo no painel; depois o JBL conecta e troca também.
/// O popup acompanha o painel: mesmo fone, mesma bateria, mesmo modo.
private struct DemoScene: View {
    let panelHeight: CGFloat
    @State private var state = PanelFixtures.connected(.noiseCanceling)
    @State private var popup = PopupModel()
    @State private var showPopup = false

    /// Altura do painel mais alto do roteiro: Sony no modo Ambiente, com Som no Mac.
    @MainActor static var panelHeight: CGFloat {
        let host = NSHostingView(rootView: PanelView(state: PanelFixtures.connected(.ambient)).environment(DeviceController.shared))
        return host.fittingSize.height.rounded(.up)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            PanelView(state: state).frame(height: panelHeight, alignment: .top)
            ZStack { if showPopup { PopupView(model: popup) {} } }.frame(width: 360, height: 190, alignment: .top)
        }
        .task {
            try? await Task.sleep(for: .seconds(2.5)) // o screencapture leva um tempo para começar a gravar
            connect(PopupDemo(name: state.name, level: UInt8(state.battery ?? 0), mode: .noiseCanceling), seconds: 6)
            for (delay, mode) in [(2.5, SoundMode.ambient), (2.0, .off), (1.6, .noiseCanceling)] {
                try? await Task.sleep(for: .seconds(delay))
                set(mode)
            }
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.snappy) { state = PanelFixtures.jblLiveBeam4 }
            let jbl = PanelFixtures.jblLiveBeam4
            connect(PopupDemo(name: jbl.name, level: UInt8(jbl.earbuds?.left ?? 0), mode: .noiseCanceling, earbuds: true), seconds: 5)
            for (delay, mode) in [(2.4, SoundMode.ambient), (2.0, .noiseCanceling)] {
                try? await Task.sleep(for: .seconds(delay))
                set(mode)
            }
        }
    }

    private func connect(_ demo: PopupDemo, seconds: Double) {
        popup.demo = demo
        popup.reset(duration: seconds)
        showPopup = true
    }

    private func set(_ mode: SoundMode) {
        withAnimation(.snappy) {
            state.mode = mode
            popup.demo?.mode = mode
        }
    }
}
#endif
