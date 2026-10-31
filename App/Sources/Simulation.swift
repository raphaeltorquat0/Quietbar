#if DEBUG
import AppKit
import MDRKit
import MDRSession
import MDRSimulator
import Observation
import QuietAudio
import QuietAutomation
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
            if args.contains("--headless") {
                // Sem painel: o canal é solto como no uso real.
            } else if args.contains("--mac-sound-window") || args.contains("--automation-window") { // a aba numa janela própria, para conferir com `screencapture -l`
                let automation = args.contains("--automation-window")
                let w = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 560, height: automation ? 760 : 1250), styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = automation ? NSHostingView(rootView: AnyView(AutomationTab().environment(DeviceController.shared)))
                                           : NSHostingView(rootView: AnyView(MacSoundTab().environment(DeviceController.shared)))
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
        Validation.start()
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
            // Sem janela o canal é solto como no uso real: uma janela aberta o manteria aberto.
            guard !CommandLine.arguments.contains("--headless") else { return }
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

    static func trace(_ event: AutomationEvent) { Validation.write(event) }
    static func trace(mic usage: MicUsage) { Validation.write(["kind": "mic", "running": "\(usage.deviceRunning)", "processes": (usage.processes ?? []).joined(separator: ",")]) }
    static func trace(front id: String?) { Validation.write(["kind": "front", "app": id ?? "-"]) }
    static func trace(call active: Bool) { Validation.write(["kind": "call", "active": "\(active)"]) }

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

/// Instrumentação dos experimentos de `scripts/validation/`: grava cada evento em JSONL (`--automation-trace <arquivo>`)
/// e recebe comandos por um FIFO (`--control <fifo>`). O comando vem por dentro porque o app e o `mdr-cli` não dividem o RFCOMM.
@MainActor enum Validation {
    private static var file: FileHandle?

    static func start() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--automation-trace"), let path = args.dropFirst(i + 1).first {
            FileManager.default.createFile(atPath: path, contents: nil)
            file = FileHandle(forWritingAtPath: path)
        }
        if let i = args.firstIndex(of: "--control"), let path = args.dropFirst(i + 1).first {
            Thread.detachNewThread {
                guard let stream = fopen(path, "r+") else { return } // r+: o FIFO não dá EOF quando o script fecha
                var line: UnsafeMutablePointer<CChar>?
                var size = 0
                while getline(&line, &size, stream) > 0 {
                    let text = String(cString: line!).trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async { MainActor.assumeIsolated { handle(text) } }
                }
            }
        }
    }

    static func write(_ event: AutomationEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        append(data, fallback: "{}")
    }

    static func write(_ fields: [String: String]) {
        guard let data = try? JSONEncoder().encode(fields) else { return }
        append(data, fallback: "{}")
    }

    private static func append(_ json: Data, fallback: String) {
        guard let file else { return }
        let body = String(decoding: json, as: UTF8.self).dropFirst()
        let t = Int(Date().timeIntervalSince1970 * 1000)
        file.write(Data("{\"t\":\(t),\(body)\n".utf8))
    }

    private static func handle(_ line: String) {
        let w = line.split(separator: " ").map(String.init)
        let d = DeviceController.shared, engine = Automation.shared.engine
        switch w.first {
        case "mode": // comando direto à sessão, fora do motor, com a releitura do fone
            guard w.count > 1, let mode = SoundMode(rawValue: w[1]) else { return }
            Task {
                let started = ContinuousClock.now
                do {
                    try await d.run { s in
                        try await s.setSoundMode(mode)
                        for _ in 0..<300 where await s.state.noiseControl?.soundMode != mode {
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    }
                    let c = started.duration(to: .now).components
                    write(["kind": "direct", "mode": mode.rawValue, "ok": "\(d.state.noiseControl?.soundMode == mode)",
                           "ms": "\(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)"])
                } catch {
                    write(["kind": "direct", "mode": mode.rawValue, "ok": "false", "error": error.localizedDescription])
                }
            }
        case "mode_read": d.perform { _ in } // só abre o canal, como a checagem de bateria
        case "rule": // rule <call|focus|app|wifi> <modo|none>
            guard w.count > 2, let kind = RuleKind.allCases.first(where: { "\($0)" == w[1] }) else { return }
            engine.set(kind, SoundMode(rawValue: w[2]).map { Rule(id: "validation.\(w[1])", name: w[1], settings: [.soundMode: .mode($0)]) })
        case "shortcut": // shortcut <noiseCanceling|ambient|off|toggleNcAmbient>: o caminho do atalho global e da Central de Controle
            if w.count > 1, let action = ShortcutAction(rawValue: w[1]) { action.run(d) }
        case "intent": // intent <noiseCanceling|ambient|off>: o perform do App Intent, no processo do app
            guard w.count > 1, let option = NoiseModeOption(rawValue: w[1]) else { return }
            Task {
                let intent = SetNoiseModeIntent()
                intent.mode = option
                _ = try? await intent.perform()
            }
        case "button": // button <modo>: botão físico do fone simulado; com o canal solto, nada chega ao app
            guard w.count > 1, let mode = SoundMode(rawValue: w[1]), var n = d.state.noiseControl, let t = Simulation.shared.transport else { return }
            n.soundMode = mode
            Task { await t.event(.noiseControl(n)) }
        case "no_mode_reply": AutomationBridge.simulateNoModeReply = w.dropFirst().first == "on"
        case "front": if w.count > 1 { ProfileEngine.shared.injectFront(w[1]) }
        case "mark": write(["kind": "mark", "text": w.dropFirst().joined(separator: " ")])
        case "unavailable": AutomationBridge.simulateUnavailable = w.dropFirst().first == "on"
        case "sleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        case "wake": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        case "state":
            let c = engine.counters
            write(["kind": "state", "phase": "\(d.snapshot.phase)", "openUIs": "\(d.openUIs)", "watchdogCloses": "\(d.watchdogCloses)", "mode": d.state.noiseControl?.soundMode.rawValue ?? "-",
                   "rule": Automation.shared.indicator ?? "-", "writes": "\(c.writes)", "confirmed": "\(c.confirmed)", "divergent": "\(c.divergent)", "failed": "\(c.failed)", "redundantBlocked": "\(c.redundantBlocked)", "overridesKept": "\(c.overridesKept)", "unverified": "\(c.unverified)"])
        default: break
        }
    }
}
#endif
