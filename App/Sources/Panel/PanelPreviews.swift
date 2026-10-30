import AppKit
import HeadphoneModel
import MDRKit
import SwiftUI

/// Estados de exemplo do painel: previews do Xcode e `--render-panel-previews <pasta>`.
@MainActor enum PanelFixtures {
    static func connected(_ mode: SoundMode, battery: Int = 72) -> PanelState {
        var p = PanelState()
        p.name = "Fone do Raphael"
        p.subtitle = "WH-1000XM5 · AAC"
        p.link = .ready
        p.battery = battery
        p.mode = mode
        p.ambientLevel = 14
        p.focusOnVoice = true
        p.presets = [0x00, 0x10, 0x11, 0x12, 0x16, 0xA0, 0xA1].map { .init(id: $0, name: PresetNames.name($0)) }
        p.presetID = 0x16
        p.bands = [7, 0, 0, 0, 0, 0]
        p.speakToChat = false
        p.dsee = true
        p.showPlayback = true
        p.isPlaying = true
        p.volume = 17
        return p
    }

    /// WF-1000XM5: earbuds com cancelamento de ruído, os dois lados e o estojo.
    static var wf1000xm5: PanelState {
        var p = connected(.noiseCanceling, battery: 64)
        p.name = "WF-1000XM5"
        p.subtitle = "WF-1000XM5 · LDAC"
        p.earbuds = .init(left: 64, right: 71, caseLevel: 45)
        return p
    }

    /// LinkBuds Clip: earbuds sem cancelamento de ruído, EQ de 10 bandas, só um lado no ouvido.
    static var linkBudsClip: PanelState {
        var p = connected(.off, battery: 78)
        p.name = "LinkBuds Clip"
        p.subtitle = "WF-LC900 · AAC"
        p.mode = nil
        p.earbuds = .init(left: 78, right: nil, caseLevel: 18)
        p.presets = [0x00, 0x30, 0x31, 0x32, 0x33, 0xA0].map { .init(id: $0, name: PresetNames.name($0)) }
        p.presetID = 0x30
        p.bands = [4, 4, -1, -1, 0, 0, 0, 0, 0, 0]
        p.bandsLimit = 6
        p.speakToChat = nil
        return p
    }

    static var disconnected: PanelState {
        var p = PanelState()
        p.name = "WH-1000XM5"
        p.link = .off
        p.phase = .disconnected(message: "O fone não está conectado ao Mac.")
        return p
    }

    static var loading: PanelState {
        var p = PanelState()
        p.name = "WH-1000XM5"
        p.link = .bluetoothOnly
        p.phase = .loading
        return p
    }

    /// (arquivo, estado, esquema de cor, contraste alto)
    static var cases: [(String, PanelState, ColorScheme, Bool)] {
        [("1-nc-claro", connected(.noiseCanceling), .light, false),
         ("2-nc-escuro", connected(.noiseCanceling), .dark, false),
         ("3-ambiente-expandido-escuro", connected(.ambient), .dark, false),
         ("4-ambiente-expandido-claro", connected(.ambient), .light, false),
         ("5-bateria-baixa-escuro", connected(.off, battery: 8), .dark, false),
         ("6-bateria-20-claro", connected(.noiseCanceling, battery: 18), .light, false),
         ("7-desconectado-claro", disconnected, .light, false),
         ("8-desconectado-escuro", disconnected, .dark, false),
         ("9-carregando-escuro", loading, .dark, false),
         ("10-contraste-alto-claro", connected(.ambient), .light, true),
         ("12-wf1000xm5-escuro", wf1000xm5, .dark, false),
         ("13-linkbuds-clip-claro", linkBudsClip, .light, false)]
    }

    static func withModel(_ p: PanelState) -> PanelState {
        var p = p
        var st = HeadphoneExport.State()
        st.mode = p.mode ?? .off
        st.battery = Double(p.battery ?? 0) / 100
        p.modelSnapshot = HeadphoneExport.snapshotImage(size: CGSize(width: 252, height: 252), state: st)
        return p
    }
}

@MainActor enum PanelPreviewRenderer {
    /// Renderiza cada caso com o ImageRenderer em `dir` e encerra o processo.
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let all = PanelFixtures.cases.map { ($0.0, $0.1, $0.2, $0.3, "pt-BR") }
            + [("11-ingles-ambiente-escuro", PanelFixtures.connected(.ambient), .dark, false, "en")]
        for (name, state, scheme, contrast, lang) in all {
            let view = PanelView(state: PanelFixtures.withModel(state))
                .environment(\.locale, Locale(identifier: lang))
                .environment(\.panelSnapshot, true)
                .environment(\.colorScheme, scheme)
                .environment(\._colorSchemeContrast, contrast ? .increased : .standard)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { print("falhou: \(name)"); continue }
            try? png.write(to: dir.appending(path: "\(name).png"))
            print(dir.appending(path: "\(name).png").path)
        }
        exit(0)
    }
}

#Preview("Conectado — Cancelar ruído") { PanelView(state: PanelFixtures.connected(.noiseCanceling)) }
#Preview("Conectado — Ambiente expandido") { PanelView(state: PanelFixtures.connected(.ambient)) }
#Preview("Bateria baixa") { PanelView(state: PanelFixtures.connected(.off, battery: 8)) }
#Preview("Desconectado") { PanelView(state: PanelFixtures.disconnected) }
#Preview("Carregando") { PanelView(state: PanelFixtures.loading) }
#Preview("Modo claro") { PanelView(state: PanelFixtures.connected(.noiseCanceling)).preferredColorScheme(.light) }
#Preview("Modo escuro") { PanelView(state: PanelFixtures.connected(.noiseCanceling)).preferredColorScheme(.dark) }

/// `Quietbar --demo-panel <caso>`: o painel real da barra mostra um estado de exemplo e abre sozinho.
/// Casos: nc (padrão), ambiente, desconectado, carregando, wf, clip.
/// Serve para conferir o Liquid Glass (que o ImageRenderer não desenha) com `screencapture`.
@MainActor enum DemoPanel {
    static let state: PanelState? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--demo-panel") else { return nil }
        let name = CommandLine.arguments.dropFirst(i + 1).first ?? "nc"
        return switch name {
        case "ambiente": PanelFixtures.connected(.ambient)
        case "desconectado": PanelFixtures.disconnected
        case "carregando": PanelFixtures.loading
        case "wf": PanelFixtures.wf1000xm5
        case "clip": PanelFixtures.linkBudsClip
        default: PanelFixtures.connected(.noiseCanceling)
        }
    }()

    /// `--demo-popup` mostra o popup de conexão com dados fictícios.
    static func openIfRequested() {
        let popup = CommandLine.arguments.contains("--demo-popup")
        guard state != nil || popup else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            if popup { PopupController.shared.present(force: true, demo: PopupDemo()) } else { StatusBar.shared.openPanel() }
        }
    }
}
