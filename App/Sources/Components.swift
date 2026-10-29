import MDRKit
import SwiftUI

/// Slider que mostra o valor do fone e só envia ao soltar; enquanto arrasta, mostra o rascunho.
struct DeviceSlider: View {
    let value: Int?
    let range: ClosedRange<Int>
    var label: String = ""
    let commit: (Int) -> Void

    @State private var draft: Double?

    var body: some View {
        HStack {
            if !label.isEmpty { Text(label).frame(minWidth: 70, alignment: .leading) }
            Slider(value: Binding(get: { draft ?? Double(value ?? range.lowerBound) }, set: { draft = $0 }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1) { editing in
                if !editing, let d = draft {
                    commit(Int(d.rounded()))
                    draft = nil
                }
            }
            .disabled(value == nil)
            Text(value.map { "\(Int(draft ?? Double($0)))" } ?? "—").monospacedDigit().frame(width: 26, alignment: .trailing)
        }
    }
}

/// Binding que lê do estado do fone e escreve mandando o comando (sem tocar no estado local).
func deviceBinding<T: Sendable>(_ value: T?, default d: T, _ write: @escaping @MainActor (T) -> Void) -> Binding<T> {
    Binding(get: { value ?? d }, set: { v in MainActor.assumeIsolated { write(v) } })
}

extension SoundMode {
    var label: String {
        switch self {
        case .noiseCanceling: "Cancelamento"
        case .ambient: "Ambiente"
        case .off: "Desligado"
        }
    }

    var symbol: String {
        switch self {
        case .noiseCanceling: "person.wave.2.fill"
        case .ambient: "ear.fill"
        case .off: "circle.slash"
        }
    }
}

extension NcAmbButtonFunction {
    var label: String {
        switch self {
        case .ncAmbientOff: "Cancelamento → Ambiente → Desligado"
        case .ncAmbient: "Cancelamento ↔ Ambiente"
        case .ncOff: "Cancelamento ↔ Desligado"
        case .ambientOff: "Ambiente ↔ Desligado"
        default: String(format: "0x%02X", rawValue)
        }
    }
}

/// Textos para os alertas de confirmação do fone (`AlertMessageType` em [M]).
func alertText(_ a: MDRAlert) -> String {
    switch a.messageType {
    case 0x00: "Mudar o modo de conexão vai desconectar o fone por um instante."
    case 0x06: "Ativar a conexão com 2 dispositivos desativa o LDAC e reconecta o fone."
    case 0x07: "Mudar a conexão com 2 dispositivos vai reconectar o fone."
    case 0x08: "Usar equalizador e DSEE juntos aumenta o consumo de bateria."
    case 0x0A, 0x0B, 0x0C, 0x0D: "Mudar o painel de toque pode reconectar o fone."
    case 0x1C, 0x2A: "Com prioridade em qualidade de som, a conexão pode ficar menos estável."
    case 0x70, 0x71, 0x72, 0x73: "Conectar 2 dispositivos com LDAC pode afetar a estabilidade."
    default: String(format: "O fone pediu confirmação (código 0x%02X).", a.messageType)
    }
}

/// Mostra a confirmação que o fone pede (ex.: ao alternar multiponto).
struct DeviceAlertModifier: ViewModifier {
    @Environment(DeviceController.self) private var device

    func body(content: Content) -> some View {
        let alert = device.state.pendingAlert
        content.alert("Confirmação do fone", isPresented: .constant(alert != nil), presenting: alert) { _ in
            Button("Continuar") { device.perform { try await $0.respondToAlert(positive: true) } }
            Button("Cancelar", role: .cancel) { device.perform { try await $0.respondToAlert(positive: false) } }
        } message: { Text(alertText($0)) }
    }
}

extension View {
    func deviceAlerts() -> some View { modifier(DeviceAlertModifier()) }

    /// Conta a view como "UI aberta" para a política de liberar o canal após 15 s.
    func keepsChannelOpen() -> some View {
        onAppear { DeviceController.shared.uiAppeared() }
            .onDisappear { DeviceController.shared.uiDisappeared() }
    }
}
