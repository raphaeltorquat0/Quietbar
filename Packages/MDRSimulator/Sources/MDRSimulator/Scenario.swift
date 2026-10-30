import MDRKit

/// Evento que o Mac percebe e o app trata, como o sono ou o Bluetooth avisando da conexão.
public enum HostEvent: Sendable {
    case connectionLost, connectionRestored, willSleep, didWake
}

/// Situações roteirizadas. Cada uma age no `VirtualTransport`, e o host reage pelo caminho normal.
public enum Scenario: String, CaseIterable, Sendable, Identifiable {
    case buttonMode = "botao"
    case batteryDrain = "bateria"
    case earbudCase = "estojo"
    case reconnect = "reconexao"
    case sleepWake = "sono"
    case slowResponse = "lento"
    case corruptFrame = "corrompido"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .buttonMode: "Botão físico troca o modo de som"
        case .batteryDrain: "Bateria desce até o alerta"
        case .earbudCase: "Fone sai e volta ao estojo"
        case .reconnect: "Desconexão e reconexão"
        case .sleepWake: "Sono e despertar do Mac"
        case .slowResponse: "Resposta lenta e timeout"
        case .corruptFrame: "Frame corrompido"
        }
    }

    public enum Outcome: Sendable, Equatable {
        case ran
        case notApplicable(String)
    }

    /// `step` separa as etapas: curto nos testes, visível no app.
    @discardableResult
    public func run(on t: VirtualTransport, step: Duration = .seconds(2),
                    host: @Sendable (HostEvent) async -> Void = { _ in }) async -> Outcome {
        let device = await t.device
        func pause() async { try? await Task.sleep(for: step) }
        switch self {
        case .buttonMode:
            guard case .noiseControl(var n)? = currentNoiseControl(device) else {
                return .notApplicable("\(device.profile.modelName) não tem modo de som")
            }
            let modes: [SoundMode] = n.inquiredType == 0x22 ? [.off, .ambient] : [.ambient, .off, .noiseCanceling]
            for mode in modes {
                n.soundMode = mode
                await t.event(.noiseControl(n))
                await pause()
            }
        case .batteryDrain:
            for level: UInt8 in [40, 25, 15, 10, 5] {
                await t.event(batteryMessage(device, level))
                await pause()
            }
        case .earbudCase:
            guard case .batteryLR(let b)? = device.current(.battery(0x09)) else {
                return .notApplicable("\(device.profile.modelName) não é um par de earbuds")
            }
            // Nível 0 = lado ausente, como na captura do LinkBuds Clip com um fone só.
            await t.event(.batteryLR(EarbudsBattery(left: b.left, right: BatteryStatus(level: 0, threshold: b.right.threshold))))
            await pause()
            await t.event(.batteryLR(b))
        case .reconnect:
            await t.configure { $0.reachable = false }
            await t.dropConnection()
            await host(.connectionLost)
            await pause()
            await t.configure { $0.reachable = true }
            await host(.connectionRestored)
        case .sleepWake:
            await host(.willSleep)
            await t.configure { $0.reachable = false }
            await pause()
            await t.configure { $0.reachable = true }
            await host(.didWake)
        case .slowResponse:
            await t.configure { $0.latency = .milliseconds(600) }
            await pause()
            await t.configure { $0.unresponsive = true }
            await pause()
            await t.configure {
                $0.unresponsive = false
                $0.latency = .zero
            }
        case .corruptFrame:
            var bad = MDRFrame(type: .mdr, seq: 0, payload: [0x25, 0x00, 50]).encoded()
            bad[bad.count - 2] &+= 1 // checksum errado
            await t.emit(raw: bad)
            await t.emit(raw: [0x3E, 0x0C, 0x3D, 0xFF, 0x3C]) // escape inválido
            await pause()
            await t.event(batteryMessage(device, 33))
        }
        return .ran
    }

    private func currentNoiseControl(_ d: VirtualDevice) -> MDRMessage? {
        d.current(.noiseControl(0x17)) ?? d.current(.noiseControl(0x22))
    }

    private func batteryMessage(_ d: VirtualDevice, _ level: UInt8) -> MDRMessage {
        if case .batteryLR(let b)? = d.current(.battery(0x09)) {
            return .batteryLR(EarbudsBattery(left: BatteryStatus(level: level, threshold: b.left.threshold),
                                             right: BatteryStatus(level: level, threshold: b.right.threshold)))
        }
        return .battery(BatteryStatus(level: level))
    }
}
