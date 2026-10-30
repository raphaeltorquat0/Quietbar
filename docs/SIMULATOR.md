# Simulador de fones

O simulador permite desenvolver e testar o Quietbar sem fone. Ele fica no pacote `MDRSimulator` e só entra em builds Debug: `scripts/check-release-clean.sh` falha o build de release se encontrar o simulador no executável.

## Como usar

```sh
make dev   # compila em Debug
.build/xcode-debug/Build/Products/Debug/Quietbar.app/Contents/MacOS/Quietbar --simulate wh1000xm5
.build/xcode-debug/Build/Products/Debug/Quietbar.app/Contents/MacOS/Quietbar --simulate wfc510 --scenario bateria
```

`--simulate` aceita o id ou o nome do fone. Com um nome inválido, o app lista os modelos. O painel mostra a faixa **SIMULADO**, com a origem do perfil, e nada do Bluetooth real é usado.

Na aba **Desenvolvedor**, a seção **Simulador** tem o seletor **Fone simulado**, os cenários e as lacunas do perfil.

| Cenário | `--scenario` | O que acontece |
|---|---|---|
| Botão físico | `botao` | O fone notifica a troca do modo de som |
| Bateria | `bateria` | A bateria desce até 5%, passando pelo alerta |
| Estojo | `estojo` | Um fone sai e volta (só earbuds) |
| Reconexão | `reconexao` | O fone some e volta |
| Sono | `sono` | O Mac dorme e acorda |
| Resposta lenta | `lento` | O fone atrasa, depois para de confirmar |
| Frame corrompido | `corrompido` | Chegam frames inválidos, depois um válido |

Cenários que não se aplicam ao modelo informam o motivo.

No código, `VirtualTransport` implementa `MDRChannel` e entra no `MDRSession` sem mudar a sessão:

```swift
let transport = VirtualTransport(profile: Profiles.wfC510)
let session = MDRSession(channel: transport)
try await session.connect()
await Scenario.buttonMode.run(on: transport)
```

`make press-kit` gera um painel por modelo com o simulador, num build Debug, em `docs/screenshots/modelo-<id>-{claro,escuro}.png`.

## Adicionar um modelo a partir de um `mdr-cli dump`

1. **Guarde a captura em `captures/`**, que nunca vai para o Git:
   ```sh
   mkdir -p captures/wf-c710n
   mdr-cli dump --log-hex --trace 2> captures/wf-c710n/dump.log
   ```
   `dump` é somente leitura: só GET sai para o fone, e a inscrição em alertas do handshake é pulada.
2. **Sanitize.** O script troca MAC, nomes e faixas por valores falsos determinísticos e falha se sobrar algo que pareça identificador:
   ```sh
   scripts/sanitize-capture.sh captures/wf-c710n/dump.log wf-c710n-1.0.0 \
     --model WF-C710N --firmware 1.0.0 --source "mdr-cli dump de um usuário, issue #123"
   ```
   Com `--deny arquivo`, ele também recusa os textos reais listados nesse arquivo, que fica fora do Git.
3. **Leia a fixture** em `Packages/MDRSimulator/Tests/Fixtures/` antes de commitar.
4. **Mude o perfil** em `Profiles.swift` para `.capture(fixtures:source:)`, com firmware, versão do protocolo e lacunas reais.
5. **Rode `make test`.** Os testes de contrato pegam a fixture sozinhos, e o perfil passa pelo fluxo da UI.
6. **Atualize a tabela abaixo** e a compatibilidade do README.

`scripts/sanitize-capture.sh --check` confere todas as fixtures e regenera `CapturedFrames.generated.swift`.

## Fidelidade por modelo

**Verificação comum a todos os perfis:** handshake e fluxo da UI pelo `MDRSession`, em que cada recurso anunciado é lido e alterado. Isso prova que o app e o simulador concordam, não que o fone real se comporta assim.

**Perfis de referência testam só a interface.** Os frames são gerados pelo próprio MDRKit, então decodificá-los de volta não prova nada sobre o protocolo do modelo. A lista de funções é derivada dos recursos citados em `Profiles.swift`, e nenhum desses bytes foi visto vindo do fone.

Tem um desses modelos? [Envie um relatório](https://github.com/raphaeltorquat0/Quietbar/issues/new?template=relatorio-de-fone.yml).

| Modelo | Status | Origem | Verificado além do comum | Lacunas |
|---|---|---|---|---|
| WH-1000XM5 | Testado em hardware | Captura real: sessão do `mdr-cli dump` somente leitura, com 116 frames, mais 12 frames anteriores | Replay e respostas byte a byte | Só leitura: a reação real a cada SET não foi observada |
| WF-1000XM5 | Validado com tráfego real | Captura real, `SonyHeadphonesClient` `tests/WF-1000XM5-6.1.0` (MIT) | Replay de 72 frames e respostas byte a byte | Só frames recebidos: a reação real a cada SET não foi observada. Lista de presets não capturada |
| LinkBuds Clip | Validado com tráfego real | Captura real, `SonyHeadphonesClient` `tests/WF-LC900-2.0.3` e `-equalizer` (MIT) | Replay de 171 frames e respostas byte a byte | Só frames recebidos. Modos de escuta não modelados |
| WH-1000XM6 | Experimental | Referência: `docs/device-support/WH-1000XM6.md` da libmdr (MIT) | Só o comum | Protocolo, firmware e presets desconhecidos. Tipo de NC pode não ser `0x17`. Posição dos ajustes gerais presumida |
| WH-CH720N | Experimental | Referência: libmdr e Gadgetbridge | Só o comum | Protocolo, firmware e presets desconhecidos. Multiponto fora do perfil |
| ULT WEAR | Experimental | Referência: Gadgetbridge | Só o comum | Protocolo, firmware, presets e nome por MDR desconhecidos. Posição dos ajustes gerais presumida |
| WF-1000XM4 | Não verificado (pode ser MDR v1) | Referência: Gadgetbridge | Só o comum | Protocolo, firmware, presets e tipos de bateria desconhecidos. MDR v2 não confirmado |
| WF-1000XM6 | Experimental | Referência: libmdr | Só o comum | Protocolo, firmware, presets e tipos de bateria desconhecidos. EQ incompleto na referência |
| WF-C500 | Não verificado (pode ser MDR v1) | Referência: Gadgetbridge | Só o comum | Protocolo, firmware, presets e tipos de bateria desconhecidos. MDR v2 não confirmado |
| WF-C510 | Experimental | Referência: libmdr e Gadgetbridge | Só o comum | Protocolo, firmware, presets e tipos de bateria desconhecidos. Posição do multiponto presumida |
| WF-C700N | Experimental | Referência: libmdr, com protocolo `0x03000015`, firmware 2.0.7 e NC `0x17` | Só o comum | Lista de funções, presets e tipos de bateria desconhecidos. Não reproduz o defeito de NC do firmware 2.0.5 |
| WF-C710N | Experimental | Referência: Gadgetbridge | Só o comum | Protocolo, firmware, presets e tipos de bateria desconhecidos |
| LinkBuds | Não verificado (pode ser MDR v1) | Referência: Gadgetbridge | Só o comum | Protocolo, firmware, presets e tipos de bateria desconhecidos. Suporte incompleto na referência. MDR v2 não confirmado |
| LinkBuds S | Experimental | Referência: libmdr e Gadgetbridge | Só o comum | Protocolo, firmware, presets e nome por MDR desconhecidos. A libmdr marca quase tudo como não testado |
| LinkBuds Open | Experimental | Referência: libmdr | Só o comum | Protocolo, firmware, presets e nome por MDR desconhecidos. Multiponto incompleto na referência |

O Gadgetbridge é AGPL: dele só foi lida a lista de recursos de cada modelo, como fato. Nenhum código foi copiado.

## Limites do simulador

- O multiponto pede confirmação como o WH-1000XM5, em todos os modelos.
- Escolher um preset mantém a curva anterior, porque as curvas por preset não foram capturadas.
- Ajustes gerais que não são liga/desliga, como a sensibilidade de toque do LinkBuds Clip, passam intactos nos testes, mas o MDRKit não os modela.
- Sem captura de TX completa, a ordem exata dos frames do fone depois de cada SET é aproximada: ACK, depois NOTIFY.
