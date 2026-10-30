import MDRKit

/// Um perfil por modelo da tabela de compatibilidade do README.
public enum Profiles {
    public static let all: [DeviceProfile] = [
        wh1000xm5, wh1000xm6, whCH720N, ultWear, wf1000xm4, wf1000xm5, wf1000xm6,
        wfC500, wfC510, wfC700N, wfC710N, linkBuds, linkBudsS, linkBudsOpen, linkBudsClip,
    ]

    /// Aceita o id (`wh1000xm5`) ou o nome do fone (`WH-1000XM5`).
    public static func find(_ name: String) -> DeviceProfile? {
        let key = normalized(name)
        return all.first { normalized($0.id) == key || normalized($0.modelName) == key }
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let unknownBytes = "Lista de funções derivada dos recursos: os bytes nunca foram vistos num fone real, e a ordem e as prioridades são do simulador"
    private static let unknownProtocol = "Versão do protocolo não publicada: usa 0x03000000, e o suporte a MDR v2 neste modelo não foi confirmado"
    private static let unknownFirmware = "Firmware não publicado: usa 0.0.0"
    private static let unknownEqualizer = "Presets de EQ e seus nomes vêm do padrão do WH-1000XM5"
    private static let unknownBattery = "Valores de bateria e os tipos com limite (0x09/0x0A) seguem as capturas de earbuds"
    private static let standardGaps = [unknownBytes, unknownProtocol, unknownFirmware, unknownEqualizer]

    private static func features(_ change: (inout DeviceProfile.Features) -> Void) -> DeviceProfile.Features {
        var f = DeviceProfile.Features()
        change(&f)
        return f
    }

    private static let multipoint1 = DeviceProfile.GeneralSetting(inquiredType: 0xD1, subject: "MULTIPOINT_SETTING")
    private static let touch1 = DeviceProfile.GeneralSetting(inquiredType: 0xD1, subject: "TOUCH_PANEL_SETTING")
    private static let multipoint2 = DeviceProfile.GeneralSetting(inquiredType: 0xD2, subject: "MULTIPOINT_SETTING")

    // MARK: Captura real

    public static let wh1000xm5 = DeviceProfile(
        id: "wh1000xm5", modelName: "WH-1000XM5", firmware: "2.5.1", series: 0x30, protocolVersion: 0x0300_2016,
        features: features {
            $0.sound = .noiseCanceling
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.speakToChat = true
            $0.autoPause = true
            $0.autoPowerOff = true
            $0.ncAmbButton = true
            $0.connectionPriority = true
            $0.generalSettings = [touch1, multipoint2]
        },
        origin: .capture(fixtures: ["wh-1000xm5-2.5.1", "wh-1000xm5-2.5.1-sessao"],
                         source: "mdr-cli dump --log-hex somente leitura de um WH-1000XM5 fw 2.5.1, em 2026-10-29 e 2026-10-30"),
        gaps: ["Sessão somente leitura: a reação real a cada SET não foi observada",
               "O endereço e os nomes de aparelhos pareados foram trocados por valores falsos"])

    public static let wf1000xm5 = DeviceProfile(
        id: "wf1000xm5", modelName: "WF-1000XM5", firmware: "6.1.0", protocolVersion: 0x0300_3018,
        features: features {
            $0.battery = .earbuds(hasCase: true)
            $0.sound = .noiseCanceling
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.speakToChat = true
        },
        origin: .capture(fixtures: ["wf-1000xm5-6.1.0"], source: "SonyHeadphonesClient (MIT), tests/WF-1000XM5-6.1.0, commit 68dfced"),
        gaps: ["A captura só tem frames recebidos do fone (rx): a reação real a cada SET não foi observada",
               "Lista de presets de EQ não capturada: vem do padrão do WH-1000XM5"])

    public static let linkBudsClip = DeviceProfile(
        id: "linkbudsclip", modelName: "LinkBuds Clip", firmware: "2.0.3", series: 0x60, protocolVersion: 0x0300_3015,
        features: features {
            $0.battery = .earbuds(hasCase: true)
            $0.equalizer = .tenBands
            $0.dsee = true
        },
        origin: .capture(fixtures: ["linkbuds-clip-2.0.3", "linkbuds-clip-2.0.3-equalizer"],
                         source: "SonyHeadphonesClient (MIT), tests/WF-LC900-2.0.3 e -equalizer, commit 68dfced"),
        gaps: ["A captura só tem frames recebidos do fone (rx): a reação real a cada SET não foi observada",
               "Modos de escuta não são modelados pelo app"])

    // MARK: Referência

    public static let wh1000xm6 = DeviceProfile(
        id: "wh1000xm6", modelName: "WH-1000XM6",
        features: features {
            $0.sound = .noiseCanceling
            $0.equalizer = .clearBassFiveBands
            $0.speakToChat = true
            $0.ncAmbButton = true
            $0.generalSettings = [touch1, multipoint2]
        },
        origin: .reference([.libmdr("WH-1000XM6")]),
        gaps: standardGaps + ["O ajuste automático do nível de ambiente não foi modelado: o tipo de NC real pode não ser 0x17",
                              "A posição dos ajustes gerais em 0xD1/0xD2 repete a do WH-1000XM5",
                              "Modo de escuta não modelado"])

    public static let whCH720N = DeviceProfile(
        id: "whch720n", modelName: "WH-CH720N",
        features: features {
            $0.sound = .noiseCanceling
            $0.equalizer = .clearBassFiveBands
        },
        origin: .reference([.libmdr("WH-CH720N"), .gadgetbridge("SonyWHCH720NCoordinator")]),
        gaps: standardGaps + ["Multiponto é oficial, mas a referência não o implementa: ficou de fora",
                              "A referência não consegue escolher presets de EQ neste modelo"])

    public static let ultWear = DeviceProfile(
        id: "ultwear", modelName: "ULT WEAR",
        features: features {
            $0.sound = .noiseCanceling
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.autoPause = true
            $0.autoPowerOff = true
            $0.ncAmbButton = true
            $0.generalSettings = [touch1, multipoint2]
        },
        origin: .reference([.gadgetbridge("SonyWHULT900NCoordinator")]),
        gaps: standardGaps + ["O nome real informado por MDR não foi confirmado: o padrão da referência é só o nome Bluetooth",
                              "A posição dos ajustes gerais em 0xD1/0xD2 repete a do WH-1000XM5"])

    public static let wf1000xm4 = DeviceProfile(
        id: "wf1000xm4", modelName: "WF-1000XM4",
        features: features {
            $0.battery = .earbuds(hasCase: true)
            $0.sound = .noiseCanceling
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.speakToChat = true
            $0.autoPause = true
            $0.autoPowerOff = true
        },
        origin: .reference([.gadgetbridge("SonyWF1000XM4Coordinator")]),
        gaps: standardGaps + [unknownBattery])

    public static let wf1000xm6 = DeviceProfile(
        id: "wf1000xm6", modelName: "WF-1000XM6",
        features: features {
            $0.battery = .earbuds(hasCase: true)
            $0.sound = .noiseCanceling
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.speakToChat = true
            $0.generalSettings = [multipoint1]
        },
        origin: .reference([.libmdr("WF-1000XM6")]),
        gaps: standardGaps + [unknownBattery, "A referência marca o EQ como incompleto neste modelo",
                              "A posição do multiponto em 0xD1 repete a do WF-C700N"])

    public static let wfC500 = DeviceProfile(
        id: "wfc500", modelName: "WF-C500",
        features: features {
            $0.battery = .earbuds(hasCase: false)
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
        },
        origin: .reference([.gadgetbridge("SonyWFC500Coordinator")]),
        gaps: standardGaps + [unknownBattery])

    public static let wfC510 = DeviceProfile(
        id: "wfc510", modelName: "WF-C510",
        features: features {
            $0.battery = .earbuds(hasCase: true)
            $0.sound = .ambientOnly
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.generalSettings = [multipoint1]
        },
        origin: .reference([.libmdr("WF-C510"), .gadgetbridge("SonyWFC510Coordinator")]),
        gaps: standardGaps + [unknownBattery, "A posição do multiponto em 0xD1 repete a do WF-C700N"])

    public static let wfC700N = DeviceProfile(
        id: "wfc700n", modelName: "WF-C700N", firmware: "2.0.7", series: 0x00, protocolVersion: 0x0300_0015,
        features: features {
            $0.battery = .earbuds(hasCase: true)
            $0.sound = .noiseCanceling
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.autoPowerOff = true
            $0.generalSettings = [multipoint1]
        },
        origin: .reference([.libmdr("WF-C700N")]),
        gaps: [unknownBytes, unknownEqualizer, unknownBattery,
               "No firmware 2.0.5 o fone real aceita SET de NC e não age; o simulador segue o 2.0.7"])

    public static let wfC710N = DeviceProfile(
        id: "wfc710n", modelName: "WF-C710N",
        features: features {
            $0.battery = .earbuds(hasCase: true)
            $0.sound = .noiseCanceling
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.autoPowerOff = true
            $0.ncAmbButton = true
        },
        origin: .reference([.gadgetbridge("SonyWFC710NCoordinator")]),
        gaps: standardGaps + [unknownBattery])

    public static let linkBuds = DeviceProfile(
        id: "linkbuds", modelName: "LinkBuds",
        features: features {
            $0.battery = .earbuds(hasCase: true)
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.speakToChat = true
            $0.autoPause = true
            $0.autoPowerOff = true
        },
        origin: .reference([.gadgetbridge("SonyLinkBudsCoordinator")]),
        gaps: standardGaps + [unknownBattery, "A referência marca o suporte a este modelo como incompleto"])

    public static let linkBudsS = DeviceProfile(
        id: "linkbudss", modelName: "LinkBuds S",
        features: features {
            $0.battery = .earbuds(hasCase: true)
            $0.sound = .noiseCanceling
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.speakToChat = true
            $0.autoPause = true
            $0.autoPowerOff = true
            $0.ncAmbButton = true
        },
        origin: .reference([.libmdr("WF-LS900N"), .gadgetbridge("SonyLinkBudsSCoordinator")]),
        gaps: standardGaps + [unknownBattery, "A página da libmdr marca quase tudo como não testado",
                              "O nome por MDR pode ser WF-LS900N ou LinkBuds S: não confirmado"])

    public static let linkBudsOpen = DeviceProfile(
        id: "linkbudsopen", modelName: "LinkBuds Open",
        features: features {
            $0.battery = .earbuds(hasCase: true)
            $0.equalizer = .clearBassFiveBands
            $0.dsee = true
            $0.speakToChat = true
            $0.autoPause = true
        },
        origin: .reference([.libmdr("WF-L910")]),
        gaps: standardGaps + [unknownBattery, "A referência compara com o firmware 1.4.1, sem bytes publicados",
                              "O nome por MDR não foi confirmado, e o multiponto está incompleto na referência"])
}
