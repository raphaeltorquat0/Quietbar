# Som no Mac

Melhora o som do seu fone no Mac: EQ paramétrico de até 10 filtros, curvas de correção importadas e perfis que combinam o modo de som do fone com a curva do Mac. Vale só para o áudio do Mac. Não altera o cancelamento de ruído nem o som no celular.

## Arquitetura

```
apps ──► tap (escopada no fone, sem o próprio Quietbar)
              │
              ▼
   aggregate privado: tap + saída do fone
              │  qa_io_proc (C, thread de áudio)
              ▼
   preamp → até 10 biquads → limitador → A/B → fade ──► fone
```

| Parte | Onde | Papel |
|---|---|---|
| `CQuietAudio` | `Packages/QuietAudio/Sources/CQuietAudio` | Cadeia e IOProc, em C, sem alocação nem lock |
| `Curve.swift` | `QuietAudio` | Filtros (Audio EQ Cookbook), resposta, pré-amplificação, formatos |
| `Activation.swift` | `QuietAudio` | Regras de ativação, sem Core Audio |
| `AudioEngine.swift` | `QuietAudio` | Liga as regras ao backend e vigia a cadeia a 20 Hz |
| `CoreAudioBackend.swift` | `QuietAudio` | Tap, aggregate e listeners, numa fila própria |
| `MacSound.swift`, `MacSoundTab.swift` | `App/Sources` | Presets, preferências e interface |

### Regra de segurança: o áudio nunca fica para trás

O original só é silenciado com prova de que o caminho processado funciona.

1. A tap sobe **sem mudo**; o sistema continua tocando sozinho.
2. Com amostras reais chegando pela tap, ela passa a mutar e a saída processada abre em 30 ms.
3. Se o render parar por 1,5 s, tudo é desmontado. Sem tap, o som volta.
4. Com 5 s de silêncio digital e mudo ligado, ela tira o mudo e volta ao passo 2: limita o pior caso de uma tap que passou a entregar zeros.
5. Ao desmontar, o mudo sai antes do fade, para nunca haver um instante sem som.

Sem permissão, o macOS 27 nem chama o IOProc. O passo 2 não acontece e nada é mutado.

**Se o processo morrer**, o áudio volta sozinho. `CoreAudioTests.killedProcessGivesTheAudioBack` prova isso de ponta a ponta num dispositivo com loopback: tom em um processo, tap com mudo em outro, `kill -9`, e o nível volta ao original em menos de 100 ms. Isso vale para a tap privada que o app usa. Uma tap **pública** sobrevive ao dono.

## Latência e CPU

| Medida | Resultado | Meta | Como |
|---|---|---|---|
| Cadeia com 10 filtros | **0,6% de um núcleo** | < 2% | `mdr-cli audio-probe --bench`, build release, Apple M2 Pro, offline |
| Latência adicional real | **não medida** | < 20 ms | Depende da permissão (abaixo) |
| CPU do app com a tap real | **não medida** | < 2% | Depende da permissão (abaixo) |

O M2 Pro não é o Apple Silicon base pedido como referência. A conta da latência, que **não substitui a medição**: o buffer pedido ao aggregate é de 256 quadros (5,3 ms a 48 kHz) e o HAL aceitou esse valor no dispositivo virtual. Com um ciclo de captura e um de saída, a estimativa é de 11 ms mais os offsets do dispositivo. O Bluetooth pode impor um buffer maior.

**Por que não foi medido:** a permissão só é concedida por uma pessoa, no diálogo do macOS. A aba Desenvolvedor e `--audio-selftest` medem depois disso (`docs/HARDWARE_TEST.md`).

## Limitações

- Exige macOS 14.2; antes disso o recurso não aparece.
- **Enquanto o pedido de permissão está aberto, o `coreaudiod` não atende clientes novos**, e outros apps podem não conseguir começar a tocar som. O onboarding avisa. Em build ad-hoc, cada atualização é uma identidade nova para o macOS e pede a permissão outra vez.
- Modo chamada (HFP, mono) não é processado. O bloco mostra "Pausado durante chamadas".
- No começo de cada áudio, e depois de 5 s de silêncio, a primeira fração de segundo sai sem processamento.
- Com o Mac em outra saída, nada é processado.
- **Não confirmado com a tap autorizada:** o IO no sandbox e o mudo completo. Sem permissão, o loopback mostrou o original atenuado (0,100 → 0,063), não zerado. Se isso se repetir com o app autorizado, o usuário ouviria eco; a linha 14 do roteiro confere.
- O limitador tem teto em −1 dBFS, sem lookahead, para não somar latência. A rampa de A/B é de 10 ms.

## De onde vêm as curvas

O app **não traz curva medida**. "Mais grave", "Voz" e "Plano" são filtros simples, escritos à mão, sem pretensão de correção. "Correção" fica desativado até você importar uma.

O motivo está em `DECISIONS.md` #95: o MIT do [AutoEQ](https://github.com/jaakkopasanen/AutoEq) cobre o código, e os dados medidos não têm licença própria de redistribuição. O autor das medições oratory1990 já se opôs ao uso delas num app pago.

Para usar: em [autoeq.app](https://autoeq.app), escolha o fone, peça o formato paramétrico e importe o `ParametricEQ.txt` na aba Som no Mac.

### Formatos

`ParametricEQ.txt` do AutoEQ. A linha `Preamp` é ignorada, porque o app calcula a sua:

```
Preamp: -4.0 dB
Filter 1: ON LSC Fc 100 Hz Gain -2.5 dB Q 0.70
Filter 2: ON PK Fc 2000 Hz Gain 4.0 dB Q 1.50
Filter 3: ON HSC Fc 9000 Hz Gain 1.5 dB Q 0.71
```

JSON próprio:

```json
{
  "format": "quietbar-eq",
  "version": 1,
  "name": "Minha curva",
  "filters": [{ "kind": "peak", "frequency": 1000, "gain": 3, "q": 1 }]
}
```

`kind` é `peak`, `lowShelf` ou `highShelf`. Limites: até 10 filtros, 20 Hz a 20 kHz, ±24 dB, Q de 0,1 a 20. Um arquivo fora disso é recusado, não ajustado.

## Testes

`swift test --filter QuietAudioTests`. Resposta de cada filtro contra a fórmula analógica, pré-amplificação, limitador, bypass, zipper, render offline de arquivo e máquina de estados com dispositivos falsos rodam sem hardware. `CoreAudioTests` precisa de Core Audio real e de um dispositivo com loopback, e é pulado no CI com o motivo.
