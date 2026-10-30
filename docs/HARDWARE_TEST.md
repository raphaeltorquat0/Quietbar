# Roteiro de teste em hardware (WH-1000XM5)

Os testes automáticos (`swift test`) cobrem framing, parser e sessão contra um fone falso.
Este roteiro cobre o que só o aparelho real confirma. Rode com `--log-hex` e anexe a saída
em caso de falha.

Instale com `make install`. Ative Configurações › Geral › "Mostrar a aba Desenvolvedor": ali ficam
o log do protocolo (para anexar em issues), "Copiar diagnóstico", "Testar popup" e a busca Fast Pair.
Os SETs abaixo podem ser feitos pelo app (painel/Configurações) ou, para quem preferir, pelo
`mdr-cli` (`swift build -c release`; `.build/release/mdr-cli set …`).

## Já verificado

| Item | Resultado | Data |
|---|---|---|
| `dump` (handshake, capacidades, estado) | OK — WH-1000XM5 fw 2.5.1 | 2026-10-29 |
| `dump --log-hex --trace` somente leitura: 58 frames recebidos, só GET enviado | OK, 8 de 8 rodadas | 2026-10-30 |
| App `--selftest` sem App Sandbox | `phase=ready` | 2026-10-29 |
| App `--selftest` com App Sandbox | `phase=ready` | 2026-10-29 |
| Ícone da barra (macOS 27, sem fone): clique abre/fecha o painel, clique fora e Esc fecham; clique direito e Option-clique mostram o menu curto (com Option, "Ferramentas de desenvolvedor…"); "Configurações do fone…" abre as Configurações mesmo antes de o painel abrir | OK (era o item 21) | 2026-10-29 |

## A verificar (escreve no fone)

### Antes de começar

1. Feche o Sound Connect no celular ou desligue o Bluetooth dele, para ninguém disputar o canal.
2. Salve os ajustes atuais, para poder restaurá-los. O `dump` é somente leitura:
   ```sh
   mkdir -p captures/wh1000xm5
   mdr-cli dump --log-hex --trace > captures/wh1000xm5/antes.txt 2> captures/wh1000xm5/antes.log
   ```
3. Rode cada `set` com `--log-hex` e salve a saída em `captures/wh1000xm5/`, que fica fora do Git:
   ```sh
   mdr-cli set mode ambient --log-hex 2>> captures/wh1000xm5/escrita.log
   ```

### Ordem

Comece pelo que se desfaz na hora e deixe para o fim o que pode derrubar a conexão:

1. **Reversível na hora:** linhas 1 a 4 (modo de som, ambiente, EQ, DSEE) e 11 e 12 (volume, mídia).
2. **Comportamento do fone:** linhas 5, 6 e 9 (Falar para conversar, pausa automática, painel de toque).
3. **Pode exigir reconexão:** linhas 8, 10 e 7 (multiponto, prioridade, desligamento automático).
4. **Por último:** linha 24 (desligar o fone).

Para cada linha: rode o comando, confira no fone (voz/LED/app Sony) e confira que o valor
relido impresso pela CLI bate. Ao final, volte ao valor original.

### Depois

Compare um novo `dump` com `antes.txt` e restaure o que mudou. Gere a fixture com os SETs, que amplia o perfil do WH-1000XM5 (`docs/SIMULATOR.md`):

```sh
scripts/sanitize-capture.sh captures/wh1000xm5/escrita.log wh-1000xm5-2.5.1-escrita \
  --model WH-1000XM5 --firmware 2.5.1 --source "mdr-cli set --log-hex do mantenedor" --deny captures/deny.txt
```

| # | Comando | Esperado |
|---|---|---|
| 1 | `set mode ambient` / `set mode nc` / `set mode off` | modo muda; voz do fone anuncia |
| 2 | `set ambient 10` e `set voice on` | nível relido = 10, foco na voz = on |
| 3 | `set eq <preset>` e `set eq-bands 0,2,0,0,0,-2` | preset/banda relidos iguais |
| 4 | `set dsee on` / `off` | relido igual |
| 5 | `set stc on`, `set stc-sens high`, `set stc-time short` | Speak-to-Chat responde à voz |
| 6 | `set autopause off` / `on` | tirar o fone não pausa / pausa |
| 7 | **`set autooff 15m`** | **relido = 15m** — confirma a escolha "último byte `00`" (DECISIONS #6) |
| 8 | **`set multipoint off`** / `on` | fone pede confirmação; CLI responde positivo; relido igual (DECISIONS #7) |
| 9 | `set touch off` / `on` | toque no painel deixa de / volta a funcionar |
| 10 | `set priority stability` / `quality` | relido igual |
| 11 | `set volume 10` | volume muda no fone |
| 12 | `set play`, `pause`, `next`, `prev` | mídia do sistema responde |
| 13 | App: alerta de bateria baixa com threshold acima da carga atual | notificação aparece uma vez |
| 14 | App sandbox: perfil por Wi-Fi | troca de rede aplica o perfil (pede localização) |
| 15 | Desligar e ligar o fone com o app aberto | popup no canto escolhido, com bateria e modo; entrada animada; some após a duração, pausa com o cursor em cima |
| 16 | No popup, tocar no chip do modo | alterna Cancelamento ↔ Ambiente; o anel do 3D muda de cor |
| 17 | Apertar o botão NC/AMB do fone com o popup aberto | chip e anel mudam sozinhos |
| 18 | Ajustes › Acessibilidade › Reduzir movimento, depois Desenvolvedor › Testar popup | popup só faz fade, modelo parado |
| 19 | Ajustes › Popup: importar um `.usdz` | o popup e a aba Geral mostram o seu modelo girando; com > 20 MB, recusa |
| 20 | **Fast Pair**: fone em modo de pareamento (segurar o botão de liga 7 s) e Desenvolvedor › Procurar fone em modo de pareamento | anotar se aparece "Fast Pair · model ID" — decide a reabertura de DECISIONS #18 |
| 22 | Com o fone desconectado do Mac, painel › Conectar | o macOS conecta o fone e o painel mostra os controles |
| 23 | macOS 26+: Central de Controle › editar › adicionar "Modo de som do fone" e tocar | alterna Cancelamento ↔ Ambiente |
| 24 | `set poweroff` (por último) | fone desliga |

## Outros modelos

Fones diferentes do WH-1000XM5 estão marcados como experimentais no README. Para validar um:
Configurações › Geral › "Mostrar a aba Desenvolvedor" › **Copiar diagnóstico** + **Log do protocolo MDR › Exportar…**,
anexados numa issue com o template "Relatório de fone". Conferir em especial: bateria esquerda/direita/estojo
(earbuds), modos de som disponíveis e o equalizador (6 ou 10 bandas).
