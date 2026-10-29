import AppKit
import Observation

/// Aba selecionada das Settings, para o menu poder abrir direto numa aba.
@MainActor @Observable final class SettingsRouter {
    static let shared = SettingsRouter()
    var tab = "general"
}

/// Clique direito ou Option-clique no ícone da barra: menu curto em vez do painel.
/// O `MenuBarExtra` não expõe o `NSStatusItem`, então um monitor local reconhece cliques na janela
/// do item de status (do próprio app) e mostra o menu ali.
@MainActor enum StatusItemMenu {
    static var openSettings: (() -> Void)?
    private static var monitor: Any?

    static func install() {
        // Monitores locais rodam na thread principal.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { e in
            nonisolated(unsafe) let e = e
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let w = e.window, String(describing: type(of: w)).contains("StatusBarWindow") else { return false }
                let option = e.modifierFlags.contains(.option)
                guard e.type == .rightMouseDown || option else { return false }
                show(in: w, developer: option)
                return true
            }
            return handled ? nil : e
        }
    }

    static func openSettingsWindow(tab: String? = nil) {
        if let tab { SettingsRouter.shared.tab = tab }
        NSApp.activate()
        if let openSettings { openSettings() } else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }

    private static func show(in w: NSWindow, developer: Bool) {
        let d = DeviceController.shared
        let connected = d.isBluetoothConnected
        let menu = NSMenu()
        menu.addItem(ClosureItem(connected ? "Desconectar" : "Conectar") {
            Task { connected ? await d.disconnectDevice() : await d.connectDevice() }
        })
        menu.addItem(ClosureItem("Configurações do fone…") { openSettingsWindow() })
        if developer {
            menu.addItem(ClosureItem("Ferramentas de desenvolvedor…") {
                AppSettings.shared.developerMode = true
                openSettingsWindow(tab: "developer")
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureItem("Sair do Quietbar") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: w.contentView)
    }
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
