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
            StatusBar.shared.openPanel()
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
