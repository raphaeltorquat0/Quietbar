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

O aggregate com tap só começa a rodar quando algum app toca no dispositivo; antes disso, zero quadros é o normal. Depois de começar, ele segue durante as pausas, e o som volta com o mudo ativo.

**Se o processo morrer**, o áudio volta sozinho. `CoreAudioTests.killedProcessGivesTheAudioBack` prova isso de ponta a ponta num dispositivo com loopback: tom em um processo, tap com mudo em outro, `kill -9`, e o nível volta ao original em menos de 100 ms. Isso vale para a tap privada que o app usa. Uma tap **pública** sobrevive ao dono.

## Latência e CPU

| Medida | Resultado | Meta | Como |
|---|---|---|---|
| Latência adicional | **11,6 ms** | < 20 ms | Carimbos de tempo do HAL com tap real, buffer de 256 quadros a 44,1 kHz |
| CPU do processo | **1,2 a 1,35%** | < 2% | `mdr-cli` release com 10 filtros e tom tocando, 10 s |
| Carga do render | **0,75%**, máx. 1,1% | | Tempo de render sobre a duração do bloco |
| Cadeia sozinha, offline | **0,6% de um núcleo** | < 2% | `mdr-cli audio-probe --bench` |
| Original com a tap mutando | **0,0000** | zero | Teste de eco, com o tom a 0,1 |

Medido em 2026-10-30 num Apple M2 Pro, no dispositivo virtual `Steam Streaming Speakers`, pelo `mdr-cli`. **Falta medir no fone por Bluetooth**, onde o HAL pode impor um buffer maior, e num Apple Silicon base. A aba Desenvolvedor mostra os mesmos números ao vivo.

## Limitações

- Exige macOS 14.2; antes disso o recurso não aparece.
- O pedido de permissão só sai do botão do onboarding, com o áudio pausado. Quando o diálogo veio do `coreaudiod`, ele parou de atender clientes novos enquanto estava aberto. Agora o pedido vem do app (`DECISIONS.md` #106), mas isso só se confirma no primeiro clique real, por isso o aviso continua.
- Em build ad-hoc, cada atualização é uma identidade nova para o macOS: a permissão some e o Som no Mac espera o botão de novo.
- Modo chamada (HFP, mono) não é processado. O bloco mostra "Pausado durante chamadas".
- No começo de cada áudio, e depois de 5 s de silêncio, a primeira fração de segundo sai sem processamento.
- Com o Mac em outra saída, nada é processado.
- **Ainda não exercitado:** a tap dentro do App Sandbox e o diálogo pelo `TCCAccessRequest`. Fora do sandbox, tudo foi medido.
- O limitador tem teto em −1 dBFS, sem lookahead, para não somar latência. A rampa de A/B é de 10 ms.

## De onde vêm as curvas

O app **não traz curva medida**. "Mais grave", "Voz" e "Plano" são filtros simples, escritos à mão, sem pretensão de correção. "Correção" fica desativado até você importar uma.

O motivo está em `DECISIONS.md` #95: o MIT do [AutoEQ](https://github.com/jaakkopasanen/AutoEq) cobre o código, e os dados medidos não têm licença própria de redistribuição. O autor das medições oratory1990 já se opôs ao uso delas num app pago. O pedido de autorização está em `docs/launch/pedido-curva-oratory1990.md`.

Para usar: clique em **Obter curva de correção** e baixe o `ParametricEQ.txt`. Com o seu consentimento, o app espera esse arquivo em Downloads por 15 minutos, sem listar a pasta, e oferece importar e ativar. Também dá para usar **Importar…** com qualquer arquivo no mesmo formato.

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
