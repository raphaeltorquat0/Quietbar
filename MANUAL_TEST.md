# Roteiro manual: automação contextual (1.4.0)

O que depende de Meet, Zoom, um Foco real, o app Atalhos ou um gesto no fone. O que já foi provado saiu deste roteiro e está em [`docs/validation/1.4.0-sim.md`](docs/validation/1.4.0-sim.md).

**Fone:** WH-1000XM5, firmware 2.5.1 ou anotar qual. **Registre:** versão do macOS e cada item como OK ou falhou.

## Antes de começar

1. Rode `make install` e abra o app pelo `/Applications`. O sistema só lista intents e filtros de um app registrado.
2. Feche o Sound Connect no celular, para ele não disputar o canal.
3. Em Configurações › Automação, ligue **Mudar o modo de som em chamadas**, com o modo **Cancelamento**.
4. Em outro Terminal, deixe as decisões do motor na tela:
   ```sh
   /usr/bin/log stream --predicate 'subsystem == "io.github.raphaeltorquat0.Quietbar" AND category == "automation"'
   ```
5. Deixe o fone em **Ambiente**, a não ser que o passo peça outro estado.

## 1. Chamada no Meet

| # | Ação | Esperado |
|---|---|---|
| 1.1 | Entre numa reunião de teste no Meet, com o XM5 como microfone | Em cerca de 3 s, o fone vai para Cancelamento e o painel mostra "Em chamada" |
| 1.2 | Silencie e reative o microfone no Meet por 30 s | Nada muda. No navegador puro, o mudo por `track.enabled` não oscila (E1). Se oscilar aqui, o Meet para a entrada ao silenciar: anote e aumente a espera |
| 1.3 | Saia da reunião | Em cerca de 3 s, o fone volta para Ambiente e o indicador some |
| 1.4 | Repita com o microfone interno do Mac selecionado no Meet | Mesmo resultado: entradas fora do padrão também contam |

## 2. Chamada no Zoom

| # | Ação | Esperado |
|---|---|---|
| 2.1 | Entre numa reunião de teste no Zoom | Como 1.1 |
| 2.2 | Saia da reunião | Como 1.3 |
| 2.3 | Abra a tela de teste de áudio do Zoom e feche antes de 3 s | O modo não muda |
| 2.4 | Durante a chamada, ouça o som e fale | Sem corte de áudio quando o modo muda. O canal e os comandos já foram provados no E3 |

## 3. Falso positivo e apps ignorados

| # | Ação | Esperado |
|---|---|---|
| 3.1 | Abra o Gravador e grave por 10 s | Conta como chamada. Em Automação, aparece "Usando o microfone: …" |
| 3.2 | Clique em **Ignorar** e grave de novo | O modo não muda |
| 3.4 | Use o ditado do macOS por alguns segundos | Anote o processo mostrado e se vale ignorá-lo |
| 3.5 | Com a Siri ativa por voz e o Mac parado por 1 minuto | Nenhuma chamada detectada |
| 3.6 | Com **Som no Mac** ligado e música tocando | Nenhuma chamada detectada |

## 4. Foco

Crie um perfil em Perfis › + › **Sem gatilho (Foco e Atalhos)**, com o modo **Desligado**, chamado "Teste".

| # | Ação | Esperado |
|---|---|---|
| 4.1 | Abra Automação › **Abrir os Ajustes de Foco**, escolha um Foco e adicione o Quietbar em Filtros de Foco | O Quietbar aparece na lista e mostra o perfil "Teste" para escolher |
| 4.2 | Ative o Foco | O fone vai para Desligado e o painel mostra "Foco: Teste". **Anote a demora:** na hora indica `perform`; até 30 s indica a consulta a `current` (macOS 26.5 tem um relato de `perform` quebrado) |
| 4.3 | Desative o Foco | O fone volta ao modo anterior, com a mesma anotação de demora |
| 4.4 | Com o Foco ativo, saia do Quietbar e abra de novo | A regra volta sozinha em segundos |
| 4.5 | Com o Quietbar fechado, ative o Foco | Anote se o sistema abre o app. Sem isso, a regra só entra quando o app abrir |
| 4.6 | Ative o Foco e entre numa chamada; saia da chamada | Cancelamento durante a chamada; depois volta a Desligado, e não ao modo de antes do Foco |

## 5. App Atalhos

Em Atalhos, procure **Quietbar** na lista de apps. Rode cada ação com o fone conectado e com o painel fechado.

| # | Ação | Esperado |
|---|---|---|
| 5.1 | Definir modo de ruído, em cada um dos 3 modos | O fone muda a cada um |
| 5.2 | Definir nível do ambiente, com 5 e com 20, em modo Ambiente | O nível muda |
| 5.3 | Aplicar perfil "Teste" | O perfil é aplicado e continua até a próxima mudança de contexto |
| 5.4 | Aplicar preset de EQ, escolhendo um da lista | O preset muda no painel |
| 5.5 | Consultar bateria do fone | Mostra a porcentagem, e o valor pode ir para a ação seguinte |
| 5.6 | Repita 5.1 com o Quietbar fechado | O sistema abre o app em segundo plano e o fone muda |
| 5.7 | Repita 5.1 com o fone desconectado | Erro claro: "O fone não está conectado ao Mac." |
| 5.8 | Com o sistema em inglês, peça à Siri "Set Quietbar to Ambient sound"; em português, "Definir o Quietbar como Som ambiente" | A frase é reconhecida |
| 5.9 | Atalho num Mac com build Developer ID e notarizado | Repita 5.1 e 4.1. **Este build nunca foi gerado.** O E8 só provou que os metadados sobrevivem à reassinatura |

## 6. Conflito entre perfil por app e chamada

Crie um perfil por app para o Spotify (ou outro player): modo **Ambiente**, nível **5**, preset de EQ diferente do atual.

| # | Ação | Esperado |
|---|---|---|
| 6.1 | Deixe o fone em Desligado e traga o Spotify para frente | Em meio segundo, Ambiente, nível 5, com o preset; painel com "App: Spotify" |
| 6.2 | Com o Spotify na frente, entre numa chamada | Cancelamento; nível e preset do perfil continuam; painel com "Em chamada" |
| 6.3 | Durante a chamada, alterne entre o Spotify e outro app | Cancelamento continua, mas o preset e o nível acompanham o perfil |
| 6.4 | Saia da chamada com o Spotify na frente | Volta ao Ambiente do perfil |
| 6.5 | Traga outro app para frente e espere 6 s | Volta a Desligado, com o preset de antes do perfil |
| 6.6 | Dê Cmd-Tab por vários apps, sem parar em nenhum | O modo não muda |

## 7. Override manual

| # | Ação | Esperado |
|---|---|---|
| 7.1 | Em chamada, com o painel aberto, mude para Ambiente | O modo fica; o painel mostra "Ajuste manual" |
| 7.2 | Alterne para um app sem perfil | O ajuste manual continua |
| 7.3 | Saia da chamada | O override acaba e o modo de antes da chamada volta |
| 7.4 | Em chamada, com o painel aberto, aperte o botão NC/AMB do fone | Conta como ajuste manual. A mudança fora do app já foi provada no E5b; falta o botão físico |
| 7.5 | Com um perfil ativo e o painel fechado há mais de 15 s, aperte o botão NC/AMB e troque de app | O modo fica, e o menu mostra "Ajuste manual". Depois de mais uma troca, a regra volta a valer |
| 7.6 | Com o Speak-to-Chat ligado, fale fora de uma chamada, com um perfil ativo | Se o modo mudar sozinho e voltar, o indicador volta à regra |

## 8. Fone e sistema

| # | Ação | Esperado |
|---|---|---|
| 8.1 | Entre numa chamada com o fone desligado e ligue-o no meio | O modo da chamada é aplicado alguns segundos depois de conectar |
| 8.2 | Feche a tampa em chamada e abra depois do fim | O app não fica preso em "Em chamada". O sono foi injetado no E9; falta o real |
| 8.3 | Depois de cada bloco, abra Desenvolvedor › Log | Sem escritas repetidas nem erros de ACK |

## Atalhos do E7

Para medir se o Foco chega por `perform()` ou pela consulta de 30 s, crie estes atalhos no app Atalhos, com **estes nomes exatos**. Antes, instale a 1.4.0 com `make install`, abra o app e faça os passos 4.1 com o perfil "Teste".

| Nome | Ações |
|---|---|
| `QB Foco On` | **Definir Foco** › Ativar › o Foco do passo 4.1 › Até Desligar |
| `QB Foco Off` | **Definir Foco** › Desativar |
| `QB Intent Modo` | Quietbar › **Definir modo de ruído** › Som ambiente |
| `QB Intent Ambiente` | Quietbar › **Definir nível do ambiente** › 10 |
| `QB Intent Perfil` | Quietbar › **Aplicar perfil** › Teste |
| `QB Intent EQ` | Quietbar › **Aplicar preset de EQ** › um preset da lista |
| `QB Intent Bateria` | Quietbar › **Consultar bateria do fone** |

Depois rode, com o fone conectado:

```sh
scripts/validation/e7.sh
```

São cerca de 13 minutos. O script para e lista o que faltar, e o resultado sai com a fonte de cada mudança de Foco e a latência.
