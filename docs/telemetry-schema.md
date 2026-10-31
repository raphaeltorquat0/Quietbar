# Schema das métricas

Pacote diário enviado pelo Quietbar **só com o opt-in ligado**. A política está em [`PRIVACY.md`](PRIVACY.md). Quem define o formato é `TelemetryPacket` (`Packages/QuietTelemetry`); quem o valida é `infra/telemetry/lambda/schema.ts`, que recusa qualquer chave fora desta lista.

## Versão 1

```json
{
  "v": 1,
  "installId": "3f2a1c9e-7b44-4d0e-9a53-1c0de5a1b2c3",
  "date": "2026-09-21",
  "appVersion": "1.4.0",
  "macOSMajor": 27,
  "arch": "arm64",
  "deviceModelFamily": "WH-1000XM5",
  "activeDay": true,
  "manualModeChanges": 2,
  "modeChangesBySource": { "panel": 1, "controlCenter": 0, "hotkey": 0, "intent": 0, "physicalButton": 1 },
  "automation": {
    "enabled": true,
    "trialDay": null,
    "triggersFired": { "call": 1, "focus": 0, "app": 0, "wifi": 0, "shortcut": 0 },
    "overridesManual": 1
  },
  "panelOpens": 50
}
```

| Campo | Tipo | Significado |
|---|---|---|
| `v` | int | Versão do schema |
| `installId` | UUID | Aleatório, gerado no Mac ao ligar as métricas. Muda a cada 90 dias e some ao desligar |
| `date` | `AAAA-MM-DD` | Dia do pacote, no fuso do Mac |
| `appVersion` | texto | Versão do Quietbar |
| `macOSMajor` | int | Só o número principal do macOS |
| `arch` | `arm64` ou `x86_64` | Arquitetura em que o app roda |
| `deviceModelFamily` | texto ou nulo | Modelo informado pelo fone, se estiver na lista conhecida; senão `other`. Nulo se nenhum fone respondeu no dia. Nunca o nome do Bluetooth |
| `activeDay` | bool | Houve troca de modo, gatilho, ajuste contra regra ou painel aberto no dia |
| `manualModeChanges` | int | Trocas de modo não feitas pela automação |
| `modeChangesBySource` | objeto de int | Mesmas trocas, por origem. Ver abaixo |
| `automation.enabled` | bool | Regra de chamada ligada, ou algum perfil ativo com gatilho, em algum momento do dia |
| `automation.trialDay` | int ou nulo | Dia do período de teste. Nulo durante o beta |
| `automation.triggersFired` | objeto de int | Vezes em que uma regra entrou em vigor. `shortcut` é "Aplicar perfil" nos Atalhos |
| `automation.overridesManual` | int | Ajustes manuais contra uma regra, incluindo os vistos ao reabrir o canal |
| `panelOpens` | int | Aberturas do painel |

## Contadores

Todo contador vai de 0 a 50, e **50 significa "50 ou mais"**. O total também é limitado, então `manualModeChanges` pode ser menor que a soma das origens.

## Origem das trocas

Só conta quando o fone informa um modo diferente do anterior. Pedir o modo atual não soma nada.

| Origem | O que entra |
|---|---|
| `panel` | Painel, popup e Configurações |
| `controlCenter` | Controle da Central de Controle |
| `hotkey` | Atalhos globais |
| `intent` | "Definir modo de ruído" no app Atalhos |
| `physicalButton` | Mudança sem pedido do app nos últimos 3 s, com o canal aberto |

`physicalButton` é, na prática, "fora do app": o Speak-to-Chat ou o celular em multiponto também caem aqui. Com o canal solto, o fone não avisa, então a troca não entra neste contador.

## Modelos conhecidos

`WH-1000XM6`, `WH-1000XM5`, `WH-CH720N`, `ULT WEAR`, `WF-1000XM6`, `WF-1000XM5`, `WF-1000XM4`, `WF-C710N`, `WF-C700N`, `WF-C510`, `WF-C500`, `LinkBuds Clip`, `LinkBuds Open`, `LinkBuds S`, `LinkBuds` e `other`.

## Mudar o schema

Campo novo exige `v` novo, e mudança em `TelemetryPacket`, em `lambda/schema.ts`, em `infra/telemetry/test/sample-v1.json`, neste arquivo e em `PRIVACY.md`, no mesmo commit.
