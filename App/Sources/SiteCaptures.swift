#if DEBUG
import AppKit
import MDRKit
import MDRSimulator
import SwiftUI

/// `Quietbar --site-captures <pasta> --simulate WH-1000XM5`, só em Debug: imagens da página do site.
/// Cada imagem é uma janela do próprio app, capturada pelo ID. O fundo e a barra de menus são
/// desenhados aqui, dentro da janela, e o vidro amostra esse fundo. As janelas ficam abaixo do nível
/// da mesa, então não cobrem o Mac em uso, e nada aqui clica em nada.
@MainActor enum SiteCaptures {
    static let heroSize = CGSize(width: 1440, height: 900)
    static let menuBarHeight: CGFloat = 24
    /// Largura útil do painel: os 320 pt menos os 14 pt de margem de cada lado.
    private static let tilesWidth: CGFloat = 292
    private static let tilesMargin: CGFloat = 24

    static func run(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--simulate"), let name = args.dropFirst(i + 1).first, let profile = Profiles.find(name) else {
            print("use --simulate <modelo>")
            exit(2)
        }
        let device = DeviceController.shared
        await Simulation.shared.start(profile)
        await device.ensureConnected()
        try? await Task.sleep(for: .seconds(0.5)) // as respostas do sync chegam depois do handshake
        await Simulation.shared.transport?.event(.battery(BatteryStatus(level: 72)))
        // Só os valores: o preset Personalizado aceita a curva, e nenhuma tela mostra o que veio antes.
        try? await device.run { try await $0.setEqualizerPreset(0xA0) }
        try? await device.run { try await $0.setEqualizer(values: [5, 7, 3, -3, 2, 6], presetID: 0xA0) }

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

            try? await device.run { try await $0.setSoundMode(.ambient) }
            try? await device.run { try await $0.setAmbientLevel(10) }
            try? await device.run { try await $0.setFocusOnVoice(true) }
            try? await Task.sleep(for: .seconds(0.3))
            await shot(HeroScene(dark: dark, panel: panelState()), size: heroSize, dark: dark, to: dir, "hero-\(suffix)")

            try? await device.run { try await $0.setSoundMode(.noiseCanceling) }
            try? await Task.sleep(for: .seconds(0.3))
            let modes = panelState().modes
            let tiles = ModeTiles(mode: .noiseCanceling, modes: modes) { _ in }.frame(width: tilesWidth).fixedSize(horizontal: false, vertical: true)
            let height = tilesHeight(tiles)
            await shot(tiles.frame(maxWidth: .infinity, maxHeight: .infinity).background(NeutralBackdrop(dark: dark)),
                       size: CGSize(width: tilesWidth + 2 * tilesMargin, height: height + 2 * tilesMargin), dark: dark, to: dir, "feature-sound-\(suffix)")
            cutOutTiles(dir.appending(path: "feature-sound-\(suffix)@2x.png"), count: modes.count, height: height)

            await equalizer(dark: dark, to: dir, "feature-eq-\(suffix)")

            let popup = PopupModel()
            popup.demo = PopupDemo(name: profile.modelName, level: 72, mode: .noiseCanceling) // o nome real do Bluetooth é dado pessoal
            popup.reset(duration: 60)
            await shot(PopupView(model: popup) {}.environment(device).frame(maxWidth: .infinity, maxHeight: .infinity).background(NeutralBackdrop(dark: dark)),
                       size: CGSize(width: 720, height: 360), dark: dark, to: dir, "feature-battery-\(suffix)", settle: 4)
        }
        exit(0)
    }

    /// O painel real, sem a faixa do simulador nem blocos que dependem da saída de áudio deste Mac.
    private static func panelState() -> PanelState {
        var state = PanelState.from(DeviceController.shared)
        state.simulated = nil
        state.subtitle = "" // o simulador não tem codec, e sem ele a linha só repetiria o modelo
        state.macSound = nil
        state.automation = nil
        return state
    }

    private static func tilesHeight(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height.rounded(.up)
    }

    private static func shot(_ content: some View, size: CGSize, dark: Bool, to dir: URL, _ name: String, settle: Double = 2.5) async {
        let w = PressKit.KeyLookPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.colorSpace = .sRGB
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content.environment(\.controlActiveState, .key))
        host.sizingOptions = [] // ver DECISIONS #63
        w.contentView = host
        w.setContentSize(size)
        behindEverything(w)
        w.makeKey() // painel sem ativação: os controles ganham a cor, e o app em uso não perde o foco
        try? await Task.sleep(for: .seconds(settle)) // modelo 3D e animações de entrada
        await PressKit.screencapture(["-x", "-o", "-l\(w.windowNumber)", dir.appending(path: "\(name)@2x.png").path])
        w.orderOut(nil)
        print(name)
    }

    private static func behindEverything(_ w: NSWindow) {
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.setFrameOrigin(.zero)
        w.orderFrontRegardless()
    }

    /// Janela de título própria com a aba real: a janela de Configurações não abre sem o menu da barra.
    private static func equalizer(dark: Bool, to dir: URL, _ name: String) async {
        let size = CGSize(width: 560, height: 640)
        let w = PressKit.KeyLookPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel], backing: .buffered, defer: false)
        w.title = String(localized: "Equalizador")
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.colorSpace = .sRGB
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: EqualizerTab().environment(DeviceController.shared).environment(\.controlActiveState, .key))
        host.sizingOptions = [] // ver DECISIONS #63
        w.contentView = host
        behindEverything(w)
        w.makeKey()
        w.makeFirstResponder(nil) // sem anel de foco no campo de nome
        try? await Task.sleep(for: .seconds(2))
        await PressKit.screencapture(["-x", "-o", "-l\(w.windowNumber)", dir.appending(path: "\(name)@2x.png").path])
        w.orderOut(nil)
        print(name)
    }

    /// Deixa só os blocos de modo no PNG: o resto fica transparente, sem o fundo da janela.
    private static func cutOutTiles(_ url: URL, count: Int, height: CGFloat) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let scale = CGFloat(image.width) / (tilesWidth + 2 * tilesMargin)
        let spacing: CGFloat = 8
        let tile = (tilesWidth - spacing * CGFloat(count - 1)) / CGFloat(count)
        var mask = Path()
        for i in 0..<count {
            let rect = CGRect(x: tilesMargin + CGFloat(i) * (tile + spacing), y: tilesMargin, width: tile, height: height)
            mask.addRoundedRect(in: rect.applying(.init(scaleX: scale, y: scale)),
                                cornerSize: CGSize(width: panelPlatterRadius * scale, height: panelPlatterRadius * scale), style: .continuous)
        }
        ctx.addPath(mask.cgPath)
        ctx.clip()
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// Mesa de Mac neutra, sem papel de parede.
private struct NeutralBackdrop: View {
    let dark: Bool

    var body: some View {
        LinearGradient(colors: dark ? [Color(red: 0.20, green: 0.24, blue: 0.30), Color(red: 0.09, green: 0.11, blue: 0.15)]
                                    : [Color(red: 0.84, green: 0.87, blue: 0.91), Color(red: 0.64, green: 0.70, blue: 0.77)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Barra neutra com o ícone real no estado aberto, e o painel real ancorado como em `StatusBar.place`.
private struct HeroScene: View {
    let dark: Bool
    let panel: PanelState

    private static let iconWidth: CGFloat = 34
    private static let clockWidth: CGFloat = 92
    private static let edge: CGFloat = 12

    var body: some View {
        let ink: Color = dark ? .white : .black.opacity(0.85)
        let size = SiteCaptures.heroSize
        // 6 pt abaixo da barra, centrado no ícone e a 8 pt da borda da tela, como no app.
        let iconX = size.width - Self.edge - Self.clockWidth - 6 - Self.iconWidth / 2
        let panelX = min(iconX - 160, size.width - 320 - 8)
        ZStack(alignment: .topLeading) {
            NeutralBackdrop(dark: dark)
            HStack(spacing: 6) {
                Image(nsImage: StatusBar.icon(connected: true, lowBattery: false))
                    .renderingMode(.template)
                    .foregroundStyle(ink)
                    .frame(width: Self.iconWidth, height: 20)
                    .background(ink.opacity(0.14), in: .rect(cornerRadius: 6, style: .continuous))
                Text(verbatim: "Sun 9:41 AM")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ink)
                    .frame(width: Self.clockWidth, alignment: .trailing)
            }
            .padding(.trailing, Self.edge)
            .frame(width: size.width, height: SiteCaptures.menuBarHeight, alignment: .trailing)
            .background((dark ? Color.black : .white).opacity(dark ? 0.28 : 0.38))
            PanelView(state: panel)
                .fixedSize()
                .offset(x: panelX, y: SiteCaptures.menuBarHeight + 6)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
#endif
