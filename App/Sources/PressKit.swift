import AppKit
import HeadphoneModel
import MDRKit
import SwiftUI

/// `Quietbar --press-kit <pasta>`: imagens de divulgação sem capturar a área de trabalho.
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
        for dark in [true, false] {
            let suffix = dark ? "escuro" : "claro"
            for (name, state) in panels {
                await shot(PanelView(state: state), dark: dark, to: dir.appending(path: "painel-\(name)-\(suffix).png"))
            }
            await shot(popup(PopupModel()), dark: dark, to: dir.appending(path: "popup-\(suffix).png"))
            await shot(model, dark: dark, to: dir.appending(path: "modelo-3d-\(suffix).png"))
        }
        await record(to: dir.appending(path: "demo.mov"))
        exit(0)
    }

    private static func popup(_ m: PopupModel, seconds: Double = 60) -> some View {
        m.demo = PopupDemo(name: "Meu fone")
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
        let w = window(DemoScene(popup: popup(PopupModel(), seconds: 5)), dark: true)
        // O hosting view só conhece a altura final depois da troca de modo; o tamanho é o do roteiro.
        w.setContentSize(NSSize(width: 776, height: 642))
        w.center()
        await focus(w)
        try? FileManager.default.removeItem(at: url)
        // `-R` usa a origem no canto superior esquerdo da tela principal.
        let f = w.frame, top = NSScreen.screens[0].frame.maxY - f.maxY
        await screencapture(["-x", "-v", "-V", "10", "-R", "\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))", url.path])
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

    private static func screencapture(_ args: [String]) async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in c.resume() }
            do { try p.run() } catch { c.resume() }
        }
    }
}

/// Com foco, como o painel real: sem ele, os controles perdem a cor e ligado parece desligado.
private final class KeyLookPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct Backdrop<Content: View>: View {
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

/// Roteiro do GIF: popup de conexão seguido da troca de modo no painel.
private struct DemoScene<Popup: View>: View {
    let popup: Popup
    @State private var state = PanelFixtures.connected(.noiseCanceling)
    @State private var showPopup = false

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            PanelView(state: state).frame(height: 570, alignment: .top)
            ZStack { if showPopup { popup } }.frame(width: 360, height: 190, alignment: .top)
        }
        .task {
            try? await Task.sleep(for: .seconds(2.5)) // o screencapture leva um tempo para começar a gravar
            showPopup = true
            for (delay, mode) in [(2.5, SoundMode.ambient), (2.0, .off), (1.6, .noiseCanceling)] {
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(.snappy) { state.mode = mode }
            }
        }
    }
}
