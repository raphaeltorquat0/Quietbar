import AppIntents
import SwiftUI
import WidgetKit

@main
struct SonyCtlControlsBundle: WidgetBundle {
    var body: some Widget { SoundModeControl() }
}

/// Botão na Central de Controle que alterna Cancelamento ↔ Ambiente.
/// Sem estado (toggle) porque a extensão não enxerga o fone; quem fala com ele é o app.
struct SoundModeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.sonyctl.SonyCtl.soundMode") {
            ControlWidgetButton(action: ToggleSoundModeIntent()) {
                Label("Cancelamento / Ambiente", systemImage: "headphones")
            }
        }
        .displayName("Modo de som do fone")
        .description("Alterna Cancelamento de ruído e Ambiente pelo SonyCtl (o app precisa estar aberto).")
    }
}

struct ToggleSoundModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Alternar modo de som do fone"

    func perform() async throws -> some IntentResult {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("io.github.sonyctl.toggleSoundMode" as CFString), nil, nil, true)
        return .result()
    }
}
