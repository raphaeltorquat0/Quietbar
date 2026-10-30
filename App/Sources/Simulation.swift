#if DEBUG
import AppKit
import MDRKit
import MDRSimulator
import Observation
import SwiftUI

/// Fone simulado, só em builds Debug: `Quietbar --simulate <modelo> [--scenario <nome>]` ou a aba
/// Desenvolvedor. O `DeviceController` usa o transporte virtual no lugar do RFCOMM (docs/SIMULATOR.md).
@MainActor @Observable final class Simulation {
    static let shared = Simulation()

    private(set) var profile: DeviceProfile?
    private(set) var transport: VirtualTransport?
    private(set) var running: Scenario?
    private(set) var result: String?
    @ObservationIgnored private var window: NSWindow?

    func start(_ profile: DeviceProfile) async {
        self.profile = profile
        transport = VirtualTransport(profile: profile)
        result = nil
        await DeviceController.shared.restartSession()
    }

    func stop() async {
        profile = nil
        transport = nil
        running = nil
        await DeviceController.shared.restartSession()
    }

    func run(_ scenario: Scenario) async {
        guard let transport else { return }
        running = scenario
        let outcome = await scenario.run(on: transport) { event in await DeviceController.shared.simulated(event) }
        running = nil
        if case .notApplicable(let reason) = outcome { result = reason } else { result = "\(scenario.title): concluído" }
    }

    /// Lê `--simulate` e `--scenario`, abre o painel e roda o cenário pedido.
    func startIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--simulate") else { return }
        guard let name = args.dropFirst(i + 1).first, let profile = Profiles.find(name) else {
            print("modelos: " + Profiles.all.map(\.id).joined(separator: " "))
            exit(2)
        }
        var scenario: Scenario?
        if let j = args.firstIndex(of: "--scenario") {
            guard let raw = args.dropFirst(j + 1).first, let s = Scenario(rawValue: raw) else {
                print("cenários: " + Scenario.allCases.map(\.rawValue).joined(separator: " "))
                exit(2)
            }
            scenario = s
        }
        Task {
            await start(profile)
            try? await Task.sleep(for: .seconds(1))
            NSApp.activate() // aberto pelo terminal: sem isso, o painel perde o foco e fecha
            if args.contains("--mac-sound-window") { // a aba numa janela própria, para conferir com `screencapture -l`
                let w = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 560, height: 1250), styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = NSHostingView(rootView: MacSoundTab().environment(DeviceController.shared))
                w.level = .floating
                w.makeKeyAndOrderFront(nil)
                window = w
            } else {
                StatusBar.shared.openPanel()
            }
            try? await Task.sleep(for: .seconds(1))
            if let scenario { await run(scenario) }
        }
    }
}

/// Faixa no topo do painel: em modo simulado, nada do que aparece veio de um fone.
struct SimulatedBadge: View {
    let profile: DeviceProfile

    var body: some View {
        Label("SIMULADO · \(profile.isCapture ? "captura real" : "referência")", systemImage: "waveform.badge.exclamationmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.orange, in: Capsule())
            .accessibilityLabel("Fone simulado")
    }
}

/// Seletor "Fone simulado" da aba Desenvolvedor.
struct SimulatorSection: View {
    private var simulation: Simulation { .shared }
    @State private var scenario = Scenario.buttonMode

    var body: some View {
        Section("Simulador") {
            Picker("Fone simulado", selection: Binding(
                get: { simulation.profile?.id ?? "" },
                set: { id in
                    Task {
                        if let p = Profiles.find(id) { await simulation.start(p) } else { await simulation.stop() }
                    }
                })) {
                Text("Nenhum").tag("")
                ForEach(Profiles.all) { Text($0.modelName).tag($0.id) }
            }
            if let p = simulation.profile {
                LabeledContent("Origem", value: p.isCapture ? "Captura real" : "Referência")
                Picker("Cenário", selection: $scenario) {
                    ForEach(Scenario.allCases) { Text($0.title).tag($0) }
                }
                Button(simulation.running == nil ? "Rodar cenário" : "Rodando…") { Task { await simulation.run(scenario) } }
                    .disabled(simulation.running != nil)
                if let r = simulation.result { Text(r).font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Lacunas deste perfil") {
                    ForEach(p.gaps, id: \.self) { Text($0).font(.caption) }
                }
            }
        }
    }
}
#endif

#if DEBUG
/// `Quietbar --hw-test`, com um fone real: mostra o painel numa janela, imprime o estado do app a cada mudança e alterna
/// o A/B a cada SIGUSR1. Serve ao roteiro de `docs/HARDWARE_TEST.md`, feito sem clicar no app.
@MainActor enum HardwareTest {
    private static let enabled = CommandLine.arguments.contains("--hw-test")
    private static var last = ""
    private static var signals: DispatchSourceSignal?
    private static var window: NSWindow?

    static func startIfRequested() {
        guard enabled else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                guard let engine = MacSound.shared.engine else { return }
                engine.setBypass(!engine.bypass)
                log()
            }
        }
        source.resume()
        signals = source
        Task {
            try? await Task.sleep(for: .seconds(1))
            // O painel da barra não abre sem o clique no item de status: o mesmo conteúdo, numa janela capturável por ID.
            let w = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 400, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: MenuBarView().environment(DeviceController.shared))
            w.level = .floating
            w.makeKeyAndOrderFront(nil)
            window = w
            while true {
                log()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    static func log() {
        guard enabled else { return }
        let d = DeviceController.shared, s = d.state, e = MacSound.shared.engine
        let keys = ["mode", "ambient", "voice", "eq", "eq-bands", "dsee", "stc", "stc-config", "autopause", "autooff", "volume", "playback", "priority"]
        let fields = keys.compactMap { k in s.diagnosticFields.first { $0.0 == k }.map { "\(k)=\($0.1)" } }.joined(separator: " ")
        let line = "fase=\(d.snapshot.phase) \(fields) | som=\(e.map { "\($0.phase)" } ?? "-") status=\(MacSound.shared.statusText) bypass=\(e?.bypass ?? false) saida=\(e?.outputIsTarget ?? false)"
        guard line != last else { return }
        last = line
        print(Date().formatted(.dateTime.hour().minute().second()), line)
    }
}
#endif
