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
| `SystemPermission.swift` | `QuietAudio` | Consulta e pedido da permissão pelo TCC, com o fluxo padrão como saída |
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

## Por que o app usa funções privadas

O macOS não tem API pública para consultar ou pedir a permissão de áudio do sistema. Sem consulta, o app não sabe se pode montar a tap. E, quando a tap inicia sem permissão, quem abre o diálogo é o `coreaudiod`, que para de atender clientes novos até a resposta: outros apps deixam de conseguir começar a tocar som.

Por isso o Quietbar usa duas funções privadas do `TCC.framework`, carregadas com `dlopen` e `dlsym` em tempo de execução:

| Função | Para quê |
|---|---|
| `TCCAccessPreflight` | Consulta sem abrir diálogo. A tap só sobe com a resposta "autorizado" |
| `TCCAccessRequest` | Abre o pedido pelo `tccd`, a partir do botão do onboarding |

Elas não fazem parte do contrato da Apple e podem mudar ou sumir em qualquer versão do macOS. Por usá-las, o app não pode ir para a Mac App Store.

### Se elas sumirem ou mudarem

O app passa para o **fluxo padrão do sistema**: o onboarding troca o botão por **Ligar e deixar o macOS pedir**, e a linha com o motivo aparece no log da aba Desenvolvedor.

| Situação | Como é percebida | Resultado |
|---|---|---|
| O framework ou um dos símbolos não existe | `dlopen` ou `dlsym` devolvem nulo | Nenhuma das funções é chamada |
| A consulta devolve um valor fora de 0, 1 e 2 | Teste do retorno | Fluxo padrão nessa consulta |
| A consulta não responde em 3 s | Limite de tempo, em outra thread | Fluxo padrão nessa consulta; a próxima consulta tenta de novo |
| A chamada derruba o app | Marca gravada antes de cada chamada, apagada depois | Na execução seguinte, as funções não são mais chamadas |

**O limite:** `dlsym` só informa se o símbolo existe, não a assinatura. Uma assinatura diferente, com o mesmo símbolo, só aparece na chamada e pode derrubar o processo. Isso custa **no máximo uma queda**: a marca impede a repetição, e sem ela o app ficaria caindo a cada abertura. A marca vale até o macOS ou o app mudarem de versão, quando as funções voltam a ser testadas.

No fluxo padrão, o diálogo vem do `coreaudiod`, quando o áudio começa a tocar com a tap montada, e o travamento de clientes novos volta enquanto ele estiver aberto. Por isso nada acontece sem o clique, que vale só para aquela execução: gravado, um update ad-hoc abriria o diálogo ao iniciar. Se a permissão for negada, a tap recebe só zeros e o estado fica em "Aguardando áudio". Nada é mutado, e o som segue normal.

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
- O pedido de permissão só sai do botão do onboarding. Quando o diálogo veio do `coreaudiod`, ele parou de atender clientes novos enquanto estava aberto. Agora o pedido vem do app (`DECISIONS.md` #106), mas isso só se confirma no primeiro clique real, por isso o aviso continua.
- **O app não confere se há som antes de pedir.** Só a tap lê o nível, e a tap sem permissão é o que abre o diálogo. O onboarding traz uma instrução fixa: pausar o áudio e responder ao diálogo na hora (`DECISIONS.md` #111).
- Em build ad-hoc, cada atualização é uma identidade nova para o macOS: a permissão some e o Som no Mac espera o botão de novo.
- Modo chamada (HFP, mono) não é processado. O bloco mostra "Pausado durante chamadas".
- No começo de cada áudio, e depois de 5 s de silêncio, a primeira fração de segundo sai sem processamento.
- Com o Mac em outra saída, nada é processado.
- **Ainda não exercitado:** a tap dentro do App Sandbox e o diálogo pelo `TCCAccessRequest`. Fora do sandbox, tudo foi medido.
- O limitador tem teto em −1 dBFS, sem lookahead, para não somar latência. A rampa de A/B é de 10 ms.

## De onde vêm as curvas

O app **não traz curva medida**. "Mais grave", "Voz" e "Plano" são filtros simples, escritos à mão, sem pretensão de correção. "Correção" fica desativado até você importar uma.

O motivo está em `DECISIONS.md` #95: o MIT do [AutoEQ](https://github.com/jaakkopasanen/AutoEq) cobre o código, e os dados medidos não têm licença própria de redistribuição. O autor das medições oratory1990 já se opôs ao uso delas num app pago. O pedido de autorização está em `docs/launch/pedido-curva-oratory1990.md`.

Para usar: clique em **Obter curva de correção**, baixe o `ParametricEQ.txt` e, de volta à aba, use **Importar curva…**, que abre em Downloads, ou arraste o arquivo para a área indicada. O app não lê a pasta Downloads por conta própria: só abre o arquivo que você escolher. **Importar…**, na seção Curva, aceita os mesmos arquivos.

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

`kind` é `peak`, `lowShelf` ou `highShelf`. Limites: até 10 filtros, 20 Hz a 20 kHz, ±24 dB, Q de 0,1 a 20. Um arquivo fora disso é recusado, não ajustado. Só `.txt` e `.json` são aceitos.

## Testes

`swift test --filter QuietAudioTests --skip CoreAudioTests`. Resposta de cada filtro contra a fórmula analógica, pré-amplificação, limitador, bypass, zipper, render offline de arquivo e máquina de estados com dispositivos falsos rodam sem hardware. `SystemPermissionTests` injeta símbolos ausentes e funções falsas, sem tocar no TCC. `CoreAudioTests` precisa de Core Audio real e de um dispositivo com loopback, e é pulado no CI com o motivo. Ele monta tap: rode só com a permissão já concedida ao terminal, porque sem ela o sistema abre o diálogo.

No app, em Debug, `Quietbar --simulate WH-1000XM5 --no-tcc-symbols --mac-sound-window` simula um macOS sem os símbolos, e `--demo-curve-import` mostra o import sem abrir a página no navegador.
