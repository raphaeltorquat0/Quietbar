import AppKit
import Observation
import SwiftUI

/// Aba selecionada das Settings, para o menu poder abrir direto numa aba.
@MainActor @Observable final class SettingsRouter {
    static let shared = SettingsRouter()
    var tab = "general"
}

/// Ícone na barra de menus e o painel. `NSStatusItem` + `NSPanel` próprios em vez de `MenuBarExtra`:
/// o `MenuBarExtra` põe um vidro de fundo na janela (desenhado fora do processo, sem API para tirar),
/// e o painel no macOS 26+ são plataformas de vidro soltas, como a Central de Controle.
/// Clique: abre/fecha o painel. Clique direito ou Option-clique: menu curto.
@MainActor final class StatusBar: NSObject, NSWindowDelegate {
    static let shared = StatusBar()
    /// Preenchido pela primeira view SwiftUI que aparece (o `openSettings` só existe no ambiente SwiftUI).
    static var openSettings: (() -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var outsideClick: Any?

    func install() {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        refreshLabel()
    }

    /// Redesenha o ícone sempre que bateria, conexão ou a opção da % mudam.
    private func refreshLabel() {
        let d = DeviceController.shared
        withObservationTracking {
            item.button?.image = Self.icon(connected: d.isBluetoothConnected, lowBattery: d.isBatteryLow)
            let percent = d.settings.menuBarShowsPercent ? d.lastBattery.map { "\($0.level)%" } : nil
            item.button?.title = percent ?? ""
            item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            item.button?.setAccessibilityLabel("Quietbar")
        } onChange: {
            Task { @MainActor in StatusBar.shared.refreshLabel() }
        }
    }

    @objc private func clicked() {
        guard let e = NSApp.currentEvent else { return }
        // Estado global do teclado: o evento que chega do item de status (fora do processo no macOS 27)
        // pode vir sem os modificadores.
        let option = NSEvent.modifierFlags.contains(.option) || e.modifierFlags.contains(.option)
        if e.type == .rightMouseUp || option {
            closePanel()
            showMenu(developer: option)
        } else if panel != nil {
            closePanel()
        } else {
            openPanel()
        }
    }

    // MARK: Painel

    func openPanel() {
        guard panel == nil, let button = item.button, let buttonWindow = button.window else { return }
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        // No macOS 26+ o vidro já tem borda e sombra; antes, a sombra da janela contorna o painel arredondado.
        if #available(macOS 26, *) { p.hasShadow = false } else { p.hasShadow = true }
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        // Host novo a cada abertura: o `onDisappear` (canal liberado em 15 s) depende da view sair da janela.
        // O tamanho da janela é nosso (`fit`): com `sizingOptions` automático, certas alturas fracionárias
        // fazem o NSHostingView redimensionar a janela em laço até estourar a pilha (visto no macOS 27).
        let root = MenuBarView()
            .environment(DeviceController.shared)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: \.size) { StatusBar.shared.fit($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        p.contentViewController = host
        p.setContentSize(Self.rounded(host.view.fittingSize))

        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel = p
        place(p, under: anchor)
        button.highlight(true)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }

        // Clique em outro app ou na área de trabalho fecha, como um menu.
        // O próprio ícone fica de fora: no macOS 27 o item de status é desenhado fora do processo, então o
        // clique nele também chega aqui, e fechar agora faria o clique do botão reabrir o painel.
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated {
                guard !StatusBar.shared.anchor.contains(NSEvent.mouseLocation) else { return }
                StatusBar.shared.closePanel()
            }
        }
    }

    func closePanel() {
        guard let p = panel else { return }
        panel = nil
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        item.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; p.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                p.orderOut(nil)
                p.contentViewController = nil
            }
        }
    }

    /// Topo do painel 6 pt abaixo da barra, centrado no ícone, sem passar da borda da tela.
    private var anchor: NSRect = .zero
    private func place(_ p: NSPanel, under anchor: NSRect) {
        self.anchor = anchor
        let size = p.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        p.setFrameOrigin(NSPoint(x: x, y: anchor.minY - 6 - size.height))
    }

    /// O painel muda de altura (ex.: ajustes do modo Ambiente); mantém o topo preso sob a barra.
    func fit(_ size: CGSize) {
        guard let p = panel else { return }
        let s = Self.rounded(size)
        guard s != p.contentLayoutRect.size else { return }
        p.setContentSize(s)
        place(p, under: anchor)
    }

    private static func rounded(_ s: CGSize) -> NSSize { NSSize(width: s.width.rounded(.up), height: s.height.rounded(.up)) }

    func windowDidResignKey(_ n: Notification) {
        // Um alerta do fone abre como folha do painel; ela não pode fechar o painel.
        guard let p = n.object as? NSPanel, p == panel, p.attachedSheet == nil else { return }
        closePanel()
    }

    // MARK: Menu curto

    private func showMenu(developer: Bool) {
        let d = DeviceController.shared
        let connected = d.isBluetoothConnected
        let menu = NSMenu()
        menu.addItem(ClosureItem(connected ? "Desconectar" : "Conectar") {
            Task { connected ? await d.disconnectDevice() : await d.connectDevice() }
        })
        menu.addItem(ClosureItem("Configurações do fone…") { StatusBar.openSettingsWindow() })
        menu.addItem(ClosureItem("Procurar atualizações…") { Updates.shared.check() })
        if developer {
            menu.addItem(ClosureItem("Ferramentas de desenvolvedor…") {
                AppSettings.shared.developerMode = true
                StatusBar.openSettingsWindow(tab: "developer")
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureItem("Sair do Quietbar") { NSApp.terminate(nil) })
        // Padrão do AppKit para menu num item de status: liga o menu só durante este clique.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    static func openSettingsWindow(tab: String? = nil) {
        if let tab { SettingsRouter.shared.tab = tab }
        shared.closePanel()
        NSApp.activate()
        if let openSettings { openSettings() } else { openSettingsViaHiddenView() }
    }

    /// O `openSettings` só existe dentro de uma view SwiftUI numa janela. Se o painel ainda não abriu
    /// nesta sessão, uma janela de 1 pt fora da tela apresenta a view, que guarda e chama a ação.
    private static func openSettingsViaHiddenView() {
        let w = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsOpener { w.close() })
        w.orderFrontRegardless()
    }

    // MARK: Ícone

    /// Template do SF Symbol `headphones`; apagado quando desconectado, com ponto quando a bateria está baixa.
    static func icon(connected: Bool, lowBattery: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        let size = NSSize(width: symbol.size.width + 3, height: symbol.size.height)
        let img = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size), from: .zero, operation: .sourceOver, fraction: connected ? 1 : 0.35)
            if lowBattery {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: size.width - 6, y: 0, width: 6, height: 6)).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = connected ? (lowBattery ? "Fone conectado, bateria baixa" : "Fone conectado") : "Fone desconectado"
        return img
    }
}

/// Painel sem borda que aceita teclado (Tab, setas no slider, Esc fecha).
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { StatusBar.shared.closePanel() }
}

final class ClosureItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

private struct SettingsOpener: View {
    let done: @MainActor () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onAppear {
            StatusBar.openSettings = { openSettings() }
            openSettings()
            DispatchQueue.main.async(execute: done)
        }
    }
}
