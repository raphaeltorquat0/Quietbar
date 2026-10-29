import AppKit
import HeadphoneModel
import MDRKit
import SwiftUI
import UniformTypeIdentifiers

enum PopupPosition: String, CaseIterable, Identifiable {
    case topRight, topLeft, bottomRight, bottomLeft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topRight: "Canto superior direito"
        case .topLeft: "Canto superior esquerdo"
        case .bottomRight: "Canto inferior direito"
        case .bottomLeft: "Canto inferior esquerdo"
        }
    }
}

/// Popup de conexão: painel flutuante sem foco, em todos os Spaces.
@MainActor final class PopupController {
    static let shared = PopupController()
    static let showNotification = Notification.Name("io.github.raphaeltorquat0.quietbar.showPopup")

    private var panel: NSPanel?
    private var presenting = false
    private let launchedAt = Date()
    private let model = PopupModel()

    func start() {
        // `mdr-cli popup` posta isto; sem userInfo, para funcionar também dentro do sandbox.
        DistributedNotificationCenter.default().addObserver(forName: Self.showNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PopupController.shared.present() }
        }
    }

    /// Chamado quando o fone selecionado conecta no Bluetooth.
    func deviceConnected() {
        // Na abertura do app o IOBluetooth avisa das conexões já existentes; isso não é "conectou agora".
        guard Date().timeIntervalSince(launchedAt) > 3 else { return }
        present()
    }

    /// Abre a sessão, espera bateria e modo (até 3 s) e só então mostra.
    /// `force` ignora a preferência (botão "Testar popup"); `demo` usa dados fictícios, sem o fone.
    func present(force: Bool = false, demo: PopupDemo? = nil) {
        let settings = AppSettings.shared
        guard settings.popupEnabled || force, !presenting else { return }
        presenting = true
        model.demo = demo
        let device = DeviceController.shared
        device.uiAppeared()
        if demo != nil { return show() }
        Task {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, device.state.battery == nil || device.state.noiseControl == nil {
                if !device.isReady { await device.ensureConnected() }
                try? await Task.sleep(for: .milliseconds(150))
            }
            show()
        }
    }

    private func show() {
        let p = panel ?? makePanel()
        panel = p
        model.reset(duration: AppSettings.shared.popupDuration)
        let host = NSHostingView(rootView: PopupView(model: model) { [weak self] in self?.dismiss() }
            .environment(DeviceController.shared))
        p.contentView = host
        p.setContentSize(host.fittingSize)
        place(p)
        p.orderFrontRegardless()
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        presenting = false
        DeviceController.shared.uiDisappeared()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isMovable = false
        return p
    }

    private func place(_ p: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame, s = p.frame.size, m: CGFloat = 12
        let pos = PopupPosition(rawValue: AppSettings.shared.popupPosition) ?? .topRight
        let x = pos == .topLeft || pos == .bottomLeft ? f.minX + m : f.maxX - s.width - m
        let y = pos == .topLeft || pos == .topRight ? f.maxY - s.height - m : f.minY + m
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Contagem regressiva do auto-dismiss; pausa com o cursor em cima.
@MainActor @Observable final class PopupModel {
    var remaining: Double = 5
    var hovering = false
    var entrance = 0
    var demo: PopupDemo?

    func reset(duration: Double) {
        remaining = duration
        hovering = false
        entrance += 1
    }
}

/// Dados fictícios para testar o popup sem o fone.
struct PopupDemo {
    var name = "Fone de demonstração"
    var level: UInt8 = 62
    var charging = false
    var mode: SoundMode = .noiseCanceling
}

struct PopupView: View {
    let model: PopupModel
    let close: () -> Void
    @Environment(DeviceController.self) private var device
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var shownBattery = 0.0
    @State private var failed3D = false

    var body: some View {
        let s = device.state
        let settings = device.settings
        let demo = model.demo
        let battery: (level: UInt8, isCharging: Bool)? = demo.map { ($0.level, $0.charging) } ?? s.battery.map { ($0.level, $0.isCharging) }
        let mode = demo?.mode ?? s.noiseControl?.soundMode
        let level = battery.map { Double($0.level) / 100 }
        HStack(spacing: 14) {
            visual(level: level, mode: mode, settings: settings)
                .frame(width: 118, height: 118)
            VStack(alignment: .leading, spacing: 8) {
                Text(demo?.name ?? device.selectedDevice?.name ?? s.modelName ?? "Fone").font(.headline).lineLimit(1)
                if let b = battery {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().stroke(.quaternary, lineWidth: 4)
                            Circle().trim(from: 0, to: shownBattery)
                                .stroke(Color(nsColor: settings.ringNSColor), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 26, height: 26)
                        Text("\(b.level)%\(b.isCharging ? " ⚡︎" : "")").font(.title3.monospacedDigit())
                    }
                    .onAppear { animateBattery(level ?? 0) }
                    .onChange(of: b.level) { animateBattery(level ?? 0) }
                }
                if let mode {
                    Button {
                        model.remaining = max(model.remaining, 3)
                        let next: SoundMode = mode == .noiseCanceling ? .ambient : .noiseCanceling
                        if model.demo != nil { model.demo?.mode = next; return }
                        device.perform { try await $0.setSoundMode(next) }
                    } label: {
                        Label(mode.label, systemImage: mode.symbol)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Alternar Cancelamento / Ambiente")
                    .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 160, alignment: .leading)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(18) // espaço para a sombra dentro do painel
        .scaleEffect(shown || reduceMotion ? 1 : 0.86)
        .offset(y: shown || reduceMotion ? 0 : -14)
        .opacity(shown ? 1 : 0)
        .onHover { model.hovering = $0 }
        .onTapGesture(count: 2) { hide() }
        .task(id: model.entrance) {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.72)) { shown = true }
            while model.remaining > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                if !model.hovering { model.remaining -= 0.1 }
            }
            hide()
        }
    }

    @ViewBuilder
    private func visual(level: Double?, mode: SoundMode?, settings: AppSettings) -> some View {
        if failed3D || !settings.popupUse3D {
            HeadphoneIllustration(battery: shownBattery, accent: Color(nsColor: settings.ringNSColor), image: CustomMedia.image)
        } else {
            HeadphoneView(battery: level, mode: mode, accent: settings.ringAccent, customModel: CustomMedia.modelURL,
                          entranceID: model.entrance, idleRotation: false, lightRing: settings.modelLightRing) { failed3D = true }
        }
    }

    private func animateBattery(_ v: Double) {
        if reduceMotion { shownBattery = v } else {
            shownBattery = 0
            withAnimation(.easeOut(duration: 1.1).delay(0.15)) { shownBattery = v }
        }
    }

    private func hide() {
        withAnimation(.easeIn(duration: 0.2)) { shown = false }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            close()
        }
    }
}

/// Ilustração 2D própria (fallback do 3D): arco, conchas e anel de bateria. Ou a imagem do usuário.
struct HeadphoneIllustration: View {
    var battery: Double
    var accent: Color
    var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sway = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Canvas { ctx, size in
                    let w = size.width, h = size.height
                    var band = Path()
                    band.addArc(center: CGPoint(x: w / 2, y: h * 0.52), radius: w * 0.33,
                                startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
                    ctx.stroke(band, with: .color(.gray), style: StrokeStyle(lineWidth: w * 0.045, lineCap: .round))
                    for x in [w * 0.2, w * 0.8] {
                        let cup = Path(roundedRect: CGRect(x: x - w * 0.12, y: h * 0.42, width: w * 0.24, height: h * 0.36),
                                       cornerRadius: w * 0.1)
                        ctx.fill(cup, with: .linearGradient(Gradient(colors: [Color(white: 0.32), Color(white: 0.12)]),
                                                            startPoint: CGPoint(x: x, y: h * 0.42), endPoint: CGPoint(x: x, y: h * 0.78)))
                    }
                    let c = CGPoint(x: w * 0.8, y: h * 0.6), r = w * 0.07
                    var ring = Path()
                    ring.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * battery), clockwise: false)
                    ctx.stroke(ring, with: .color(accent), style: StrokeStyle(lineWidth: w * 0.025, lineCap: .round))
                }
            }
        }
        .rotationEffect(.degrees(reduceMotion ? 0 : (sway ? 3 : -3)))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { sway = true }
        }
    }
}

/// Imagem e modelo .usdz do usuário, copiados para Application Support (nunca para o bundle).
enum CustomMedia {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Quietbar")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let modelFile = dir.appending(path: "custom-model.usdz")
    static let imageFile = dir.appending(path: "custom-image")
    static let maxModelBytes = 20 * 1024 * 1024

    static var modelURL: URL? { FileManager.default.fileExists(atPath: modelFile.path) ? modelFile : nil }
    static var image: NSImage? { NSImage(contentsOf: imageFile) }

    static func importModel(from url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxModelBytes else { throw CustomMediaError("O arquivo tem mais de 20 MB.") }
        try replace(modelFile, with: url)
    }

    static func importImage(from url: URL) throws {
        guard NSImage(contentsOf: url) != nil else { throw CustomMediaError("Não consegui abrir essa imagem.") }
        try replace(imageFile, with: url)
    }

    static func remove(_ file: URL) { try? FileManager.default.removeItem(at: file) }

    private static func replace(_ dest: URL, with src: URL) throws {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
    }
}

struct CustomMediaError: LocalizedError {
    let errorDescription: String?
    init(_ m: String) { errorDescription = m }
}
