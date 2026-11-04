# Teste interno (dogfood)

Registro local de uso da 1.4.0, para decidir se ela pode sair. Os dados ficam neste Mac: nada vai para a rede.
A telemetria remota continua desligada e `QuietbarTelemetryURL` continua vazio.

## Ligar e desligar

Configurações › Desenvolvedor › Teste interno › **Registrar o uso neste Mac**. A aba aparece com **Mostrar a aba
Desenvolvedor**, em Configurações › Geral. Desligar para de gravar e mantém o que já foi gravado.

Para o registro valer alguma coisa, ligue também o que ele observa:

- **Chamadas:** aba Automação, regra de chamada. Sem ela, o detector de microfone nem roda.
- **Foco:** um Filtro de Foco do Quietbar em Ajustes do Sistema › Foco. É o único jeito público de saber o Foco.
- **Som no Mac:** o botão da aba Som no Mac, que abre o pedido de permissão.

## Marcar um momento

**⌃⌥⌘M**, de qualquer app. O estado completo do app é gravado na hora, e abre um campo curto para escrever o que
aconteceu ("trocou para NC sem chamada", "não voltou para Ambiente"). O campo não tira o foco do app em uso.
Return salva, Esc fecha sem texto, e o estado continua gravado. É o principal sinal de bug.

## Onde estão os dados

`~/Library/Application Support/Quietbar/dogfood/`, um arquivo `AAAA-MM-DD.jsonl` por dia, com limite de 50 MB no
total. Passando disso, saem os dias mais antigos, com um evento `log.full` se o dia atual sozinho estourar.

Com sandbox, o app só escreve no contêiner, então esse caminho é um link para
`~/Library/Containers/io.github.raphaeltorquat0.Quietbar/Data/Library/Application Support/Quietbar/dogfood`
(DECISIONS.md #165). Sem o link, o relatório lê o contêiner direto. Para recriar o link:

```sh
mkdir -p ~/Library/Application\ Support/Quietbar
ln -s ~/Library/Containers/io.github.raphaeltorquat0.Quietbar/Data/Library/Application\ Support/Quietbar/dogfood \
      ~/Library/Application\ Support/Quietbar/dogfood
```

Os relatórios de falha do macOS ficam em `~/Library/Logs/DiagnosticReports`, nos arquivos `Quietbar-*.ips`. O
relatório lê essa pasta sozinho e ignora os de builds fora de `/Applications`.

Nunca são gravados áudio, conteúdo de janelas, nome de rede em texto, nome pareado do fone nem endereço Bluetooth. O
nome de um perfil de Wi-Fi costuma ser o da rede, então sai em hash com sal, como a rede atual.

## Gerar o relatório

```sh
scripts/dogfood-report                                # o período inteiro
scripts/dogfood-report --since 2026-11-02 --out r.md  # a partir de uma data, em arquivo
```

## Voltar para a 1.3.1

A 1.4.0 instalada veio de `make install`, sobre a 1.3.1 do Homebrew. Para voltar:

```sh
brew reinstall --cask quietbar
```

As preferências e os dados continuam no contêiner. Build ad-hoc é outra identidade para o macOS, então a permissão de
Bluetooth pode ser pedida de novo.

## Critérios para liberar a 1.4.0

O relatório calcula cada um e dá o veredito.

| Critério | Como é medido |
|---|---|
| 7 dias de uso real, com pelo menos 10 chamadas | Dia de uso: canal aberto, chamada, troca, ajuste ou momento. Abrir no login não conta. Chamada: `call.start` com o fone no Mac. |
| Zero falhas | Nenhum relatório de falha do Quietbar de `/Applications` e nenhum `protocol.error` no período. |
| Troca correta em pelo menos 95% das chamadas, com volta ao modo anterior no fim | Certa: a regra de chamada escreveu o modo e, até 30 s depois do fim, voltou ao anterior, ou o fone já estava no modo. Ajuste manual durante a chamada conta como errada. |
| No máximo 1 ajuste manual por dia logo após uma troca automática | Ajuste até 120 s depois de `rule.applied` ou `rule.undone`, ou visto ao reabrir o canal. |
| Zero SETs redundantes e nenhum fechamento pelo watchdog sem explicação | Redundante: SET igual ao último estado informado pelo fone, medido no tráfego. Explicado: um momento com a palavra "watchdog" até 30 min depois do fechamento. |

## Limites do que se mede

- Com o canal solto o fone não avisa nada. O botão físico só aparece ao reabrir o canal, como `manual` com `late`, e a
  hora é a da descoberta. Por isso esse evento sempre conta como ajuste depois de troca automática.
- `externalChange` é toda mudança de modo sem pedido do app: botão do fone, Speak-to-Chat ou celular em multiponto.
- O Foco só aparece com um Filtro de Foco configurado.
- `app.close` não sai em `kill` nem em queda de energia. O relatório conta esses casos à parte, sem reprovar: uma queda
  real deixa relatório do macOS.
- A latência do Som no Mac é a que o motor mede, e a CPU é a média do processo inteiro nos 5 minutos da amostra.
- Antes de a chave ser ligada, nada é registrado, nem de trás para frente.

## Eventos

`app.open`, `app.close`, `dogfood.on`, `dogfood.off`, `rule.applied`, `rule.undone`, `rule.noop`, `rule.pending`,
`rule.check`, `rule.divergence`, `manual`, `manual.applied`, `override.end`, `call.start`, `call.end`, `focus.change`,
`profile.applied`, `set.sent`, `set.redundant`, `link.up`, `link.down`, `channel.open`, `channel.close`,
`watchdog.close`, `protocol.error`, `macsound.set`, `macsound.sample`, `moment`, `moment.note`, `hotkey.failed`,
`update.check`, `log.full`.

## Build novo pede Bluetooth de novo

Build ad-hoc é outra identidade para o macOS. Depois de cada instalação, o sistema pede o Bluetooth, e o app fica
parado no início, sem ícone nem atalho, até a resposta: `IOBluetoothDevice.pairedDevices` não volta antes disso, e ele
é chamado no `init` do `DeviceController`. Só o `app.open` é gravado nesse meio-tempo.

## Verificação da instalação (2026-11-01)

| Evento | Onde foi visto |
|---|---|
| `app.open`, `update.check` (`newerThanFeed`, feed 1.3.1), `moment` por ⌃⌥⌘M, `link.up`, `protocol.error` | App instalado, no build anterior ao final, com a mesma versão. O app final só chegou ao `app.open`. |
| `call.start`, `call.end`, `rule.applied`, `rule.undone`, `rule.check`, `set.sent`, `channel.open`, `channel.close`, `app.close` | Build Debug no terminal, com o fone real e o microfone interno. |
| `moment.note`, Esc, foco no campo | Build Debug, com o código final do painel e fone simulado. |
| `manual` (atalho, Atalhos, externo, `late`), `profile.applied`, `rule.noop`, `rule.pending`, `override.end` | Build Debug, com fone simulado. |
| `focus.change`, `macsound.set`, `macsound.sample`, `watchdog.close`, `set.redundant`, `link.down`, `log.full`, `hotkey.failed`, `dogfood.on`, `dogfood.off` | Não ocorreram no app. Parte deles só passou pelo histórico inventado de `scripts/test_dogfood_report.py`. |

Os eventos dessa verificação estão em `verificacao-2026-11-01/`, fora da conta dos critérios.
