<p align="center"><img src="docs/screenshots/icone.png" width="128" alt="Ícone do Quietbar"></p>

<h1 align="center">Quietbar</h1>

<p align="center">
Controle seus fones <b>Sony</b> (WH-1000XM5, WF-1000XM5, LinkBuds…) pela barra de menus do macOS, sem o app da Sony no celular.<br>
<i>Control your Sony headphones from the macOS menu bar — native, private, no phone app needed.</i> <a href="README.en.md">Read in English</a>
</p>

<p align="center">
<a href="https://github.com/raphaeltorquat0/Quietbar/releases/latest"><b>⬇︎ Baixar a última versão (.dmg)</b></a>
</p>

<p align="center">
<img src="docs/media/demo.gif" width="640" alt="Popup de conexão e troca do modo de som no painel">
</p>

<p align="center">
<img src="docs/screenshots/painel-nc-claro.png" width="300" alt="Painel no modo claro">
&nbsp;&nbsp;
<img src="docs/screenshots/painel-ambiente-escuro.png" width="300" alt="Painel no modo escuro, com os ajustes do modo Ambiente">
</p>

App nativo em Swift/SwiftUI que fala o protocolo Sony MDR v2 direto pelo Bluetooth (RFCOMM).
Seus ajustes ficam no Mac: a única conexão com a internet é a procura de atualizações, que dá para desligar.

> Projeto independente. **Não é afiliado, endossado nem suportado pela Sony.**
> "Sony", "WH-1000XM5", "WF-1000XM5", "LinkBuds" e os demais nomes de modelos são marcas de seus respectivos donos, citadas só para indicar compatibilidade.

## O que faz

- Modo de som (cancelamento de ruído / ambiente / desligado), nível do ambiente, foco na voz
- Equalizador (presets e curva de 5 bandas + Clear Bass), DSEE, Falar para conversar, pausa e desligamento automáticos
- Multiponto, painel de toque, prioridade de conexão, volume e controle de mídia
- Bateria na barra de menus, com alerta de bateria baixa
- Atalhos globais e perfis automáticos por app em primeiro plano ou rede Wi-Fi
- Popup animado ao conectar, com um modelo 3D do fone gerado em código
- Liquid Glass no macOS 26+, no estilo da Central de Controle
- Modo claro e escuro, cor de destaque do sistema, VoiceOver, PT-BR e inglês

O app só mostra o que o fone anuncia na conexão. macOS 14 ou mais novo, Apple Silicon e Intel.

## Compatibilidade

| Status | Fones | O que isso significa |
|---|---|---|
| **Testado em hardware** | WH-1000XM5 (firmware 2.5.1) | Sessão completa de leitura num fone real. Os comandos de escrita ainda seguem o roteiro de [`docs/HARDWARE_TEST.md`](docs/HARDWARE_TEST.md) |
| **Validado com tráfego real** | WF-1000XM5 (fw 6.1.0), LinkBuds Clip / WF-LC900 (fw 2.0.3) | O app entende capturas públicas desses fones, mas não foi usado com eles |
| **Experimental** (protocolo conhecido, sem teste) | WH-1000XM6, WH-CH720N, ULT WEAR, WF-1000XM6, WF-C510, WF-C700N, WF-C710N, LinkBuds S, LinkBuds Open | Fontes públicas indicam MDR v2, mas o Quietbar nunca rodou com eles |
| **Não verificado** (pode ser MDR v1) | WF-1000XM4, WF-C500, LinkBuds | Nenhuma fonte confirma a versão do protocolo. Podem não funcionar |
| **No roadmap** (MDR v1) | WH-1000XM4/XM3/XM2, WF-1000XM3, WF-SP800N | Usam a versão antiga do protocolo, ainda não implementada |

**Tem um desses fones?** Teste e [envie um relatório](https://github.com/raphaeltorquat0/Quietbar/issues/new?template=relatorio-de-fone.yml); é o que tira um modelo de "experimental" ou "não verificado".

Os perfis de referência do [simulador](docs/SIMULATOR.md) testam só a interface, porque os frames são gerados pelo próprio MDRKit. Eles não mostram que um fone funciona.

## Instalar

**Homebrew:**

```sh
brew install --cask raphaeltorquat0/tap/quietbar
```

**Download:** baixe o `Quietbar-<versão>.dmg` em [Releases](https://github.com/raphaeltorquat0/Quietbar/releases/latest) e arraste o Quietbar para **Aplicativos**.

Nos dois casos, o macOS bloqueia a primeira abertura porque o app ainda não é notarizado pela Apple:

1. Tente abrir o Quietbar. No aviso "O Item Quietbar Não Foi Aberto", clique em **OK**, não em **Mover para o Lixo**.
2. Vá em **Ajustes do Sistema › Privacidade e Segurança** e role até **Segurança**.
3. Clique em **Abrir Mesmo Assim** ao lado do Quietbar e confirme com a sua senha.

No macOS 14, também funciona Control-clique no app › **Abrir**; desde o macOS 15, só os Ajustes do Sistema liberam. Isso só é preciso uma vez.

Depois, permita o acesso ao **Bluetooth** quando o macOS pedir. O fone precisa estar pareado com o Mac.

O ícone de fone aparece na barra de menus. Para abrir junto com o Mac: Configurações › Geral › "Abrir ao iniciar sessão".

### Compilar do código

```sh
git clone https://github.com/raphaeltorquat0/Quietbar.git && cd Quietbar
make install
```

Compila, assina localmente, instala em `/Applications/Quietbar.app` (fechando a versão anterior), liga
"abrir ao iniciar sessão" e abre o app. Requisitos: macOS 14+ e Xcode 26+;
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) só se você mudar o `project.yml`.

Para desenvolver: `make dev` (roda o app em Debug no terminal), `make test` (todos os testes),
`make release` (gera o `.dmg`; veja [`docs/RELEASING.md`](docs/RELEASING.md)). `make` sozinho lista os alvos.

## Barra de menus

Clique no ícone para abrir o painel (modo de som, nível de ambiente, equalizador, Speak-to-Chat,
DSEE). Clique direito: Conectar/Desconectar, Configurações, Procurar atualizações, Sair. **Option-clique** adiciona
"Ferramentas de desenvolvedor…". No macOS 26+ há também um botão "Modo de som do fone" para a
Central de Controle (com o app aberto).

## Permissões

| Permissão | Por quê |
|---|---|
| Bluetooth | falar com o fone. Na CLI, quem pede é o Terminal — reinicie o Terminal depois de autorizar. |
| Localização (opcional) | o macOS só revela o nome da rede Wi-Fi a apps com localização; usado apenas nos perfis por Wi-Fi |
| Notificações (opcional) | alerta de bateria baixa |

## Atualizações

O app procura uma versão nova uma vez por dia pelo [Sparkle](https://sparkle-project.org). Essa consulta lê um arquivo no GitHub Pages, que vê o seu IP como em qualquer acesso, e nenhum dado do fone ou do Mac é enviado. Cada atualização é verificada por uma assinatura EdDSA. Para desligar: Configurações › Geral › "Procurar atualizações automaticamente". Clique direito no ícone › "Procurar atualizações…" faz a verificação na hora.

## Ferramentas de debug: aba Desenvolvedor

Em **Configurações › Desenvolvedor** (ative em Configurações › Geral › "Mostrar a aba Desenvolvedor",
ou Option-clique no ícone da barra › "Ferramentas de desenvolvedor…"):

- **Diagnóstico**: versão do app, macOS, firmware, capacidades detectadas e "Copiar diagnóstico"
  para colar em issues.
- **Testar popup**: com os dados do fone, ou fictícios se ele estiver desconectado.
- **Modelo 3D ao vivo**: estado NC/Ambiente/Off, bateria, reduzir movimento, "Repetir entrada" e
  "Exportar USDZ…".
- **Procurar fone em modo de pareamento**: instruções, 20 s de busca BLE com resultados ao vivo
  (nome, RSSI, Fast Pair) e "Copiar resultado".
- **Log do protocolo MDR** em tempo real (hex + mensagem decodificada), com filtro, pausar, copiar
  e exportar.

O modelo 3D é gerado em Swift (`Packages/HeadphoneModel`), sem arquivos de malha, com proporções
tiradas de vistas de referência do WH-1000XM5 (não incluídas no repositório). Os testes renderizam
cada estado offscreen e conferem o resultado.

### `mdr-cli` (CI e uso avançado)

Nada do dia a dia precisa dele. `swift build -c release` gera `.build/release/mdr-cli`, com
`list`, `dump`, `get`, `set`, `send`, `sniff`, `popup`, `ble-scan` e `model` (export/snapshot).
`--log-hex` imprime cada frame em stderr. O ícone do app é gerado do modelo 3D com
`mdr-cli model --icon App/Resources/Assets.xcassets/AppIcon.appiconset`. `mdr-cli` sem argumentos mostra a ajuda.

## Limitações

- Detecção "fone por perto" não existe: o XM5 não anunciou um model ID Fast Pair conectado (ver `DECISIONS.md` #18).
- O modelo 3D existe para WH-1000XM5, WH-1000XM6 e LinkBuds S. Outros fones de arco usam a forma do XM5, e outros earbuds usam um símbolo.
- O XM5 não tem botão personalizável (função `0xF3`) nem envia nomes de presets de EQ.
- Os comandos de escrita foram validados contra um fone simulado; o roteiro de conferência
  em aparelho real está em [`docs/HARDWARE_TEST.md`](docs/HARDWARE_TEST.md).

## Fora de escopo

| Item | Por quê |
|---|---|
| Atualização de firmware | O pacote vem dos servidores da Sony e a gravação usa um fluxo não documentado; um erro pode deixar o fone inutilizável. Use o app oficial. |
| Idioma do guia de voz | A troca é feita junto com a atualização de firmware (o fone baixa o pacote de voz), não por um comando simples. |
| 360 Reality Audio | Depende de perfil acústico gerado na nuvem da Sony e de apps de streaming compatíveis. |
| Funções de conta Sony | Exigem login e API privada da Sony; não há nada local para controlar. |

## Documentação

- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — protocolo consolidado, com a origem de cada item
- [`DECISIONS.md`](DECISIONS.md) — escolhas feitas onde a especificação era ambígua
- [`docs/HARDWARE_TEST.md`](docs/HARDWARE_TEST.md) — o que já foi e o que falta verificar no fone
- [`docs/RELEASING.md`](docs/RELEASING.md) — como assinar, notarizar e publicar
- [`docs/GATEKEEPER_TEST.md`](docs/GATEKEEPER_TEST.md) — roteiro da primeira abertura após um download real
- [`Packages/MDRKit`](Packages/MDRKit/README.md) — o protocolo como pacote Swift independente
- [`docs/SIMULATOR.md`](docs/SIMULATOR.md) — simulador de fones para desenvolver sem hardware, com a fidelidade de cada modelo
- [`CONTRIBUTING.md`](CONTRIBUTING.md) e [`SECURITY.md`](SECURITY.md) — como contribuir e reportar vulnerabilidades

## Créditos

O protocolo foi estudado a partir de projetos abertos, citados item a item em [`docs/PROTOCOL.md`](docs/PROTOCOL.md):
[SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT; os testes usam frames
capturados publicados nele), [sony-headphones-linux](https://github.com/vyomjain6904/sony-headphones-linux) (MIT)
e [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) (AGPL — usado só como referência de
comportamento, nenhum código copiado).

O [Sparkle](https://github.com/sparkle-project/Sparkle) (licença MIT) cuida das atualizações; o aviso de licença acompanha o app.

## Licença

[MIT](LICENSE) © Raphael Torquato
