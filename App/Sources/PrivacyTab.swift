import QuietTelemetry
import SwiftUI

struct PrivacyTab: View {
    private let telemetry = Telemetry.shared
    @State private var showing = false

    var body: some View {
        Form {
            Section {
                Toggle("Enviar métricas anônimas de uso", isOn: Binding(
                    get: { telemetry.recorder.enabled },
                    set: { telemetry.recorder.setEnabled($0) }))
                Button("Ver o que é enviado") { showing = true }
                Link("Política de privacidade", destination: URL(string: "https://github.com/raphaeltorquat0/Quietbar/blob/main/docs/PRIVACY.md")!)
            } header: {
                Text("Métricas")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Métricas anônimas, opt-in, desligadas por padrão. No máximo um resumo por dia, com contadores, modelo do fone e versões. Nunca inclui nomes de fone, de rede, de app ou de Foco. Desligar apaga o que está guardado no Mac.")
                    if telemetry.endpoint == nil {
                        Text("Esta versão não tem servidor configurado: nada é enviado.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Internet") {
                Text("Além das métricas, se você ligar, o Quietbar só usa a internet para procurar atualizações.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showing) { PayloadSheet(next: telemetry.recorder.nextPayload()) }
    }
}

private struct PayloadSheet: View {
    let next: (json: Data, isExample: Bool, isPartial: Bool)
    @Environment(\.dismiss) private var dismiss

    private var note: LocalizedStringKey {
        if next.isExample { return "Exemplo do formato: com as métricas desligadas, nada é contado nem enviado." }
        if next.isPartial { return "Próximo envio, com o dia de hoje até agora. Ele sai depois que o dia terminar." }
        return "Próximo envio, exatamente como sairá."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note).font(.callout)
            ScrollView {
                Text(String(decoding: next.json, as: UTF8.self))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary, in: .rect(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460, height: 460)
    }
}
