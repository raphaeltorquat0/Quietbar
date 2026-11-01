# Privacidade do Quietbar

O Quietbar controla o fone por Bluetooth, e seus ajustes ficam no Mac. Não há conta.

O app usa a internet para duas coisas:

1. **Procurar atualizações**, pelo Sparkle. Dá para desligar em Configurações › Geral.
2. **Métricas anônimas, opt-in, desligadas por padrão.** Só com a sua autorização.

## Métricas

Depois de atualizar, o app pergunta uma vez. A opção padrão é **Agora não**. Para mudar depois, vá em Configurações › Privacidade.

**Ver o que sai:** em Configurações › Privacidade, **Ver o que é enviado** mostra o JSON exato do próximo envio.

**Desligar:** a mesma chave. Os contadores, os pacotes pendentes e o ID guardados no Mac são apagados. O que já foi enviado fica no servidor até vencer, em 400 dias, porque não há como ligar um ID a você.

### O que é coletado

Um pacote por dia, no máximo. O formato completo está em [`telemetry-schema.md`](telemetry-schema.md):

- ID aleatório, gerado no Mac e trocado a cada 90 dias
- Data do pacote
- Versões do Quietbar e do macOS, e arquitetura
- Modelo do fone, de uma lista conhecida
- Se o dia teve uso, trocas de modo manuais por origem e aberturas do painel. Uma troca sem pedido do app, como o botão do fone, vira `externalChange`
- Se a automação está em uso, quantas vezes cada tipo de gatilho disparou e quantos ajustes contrariaram uma regra

Contadores acima de 50 viram 50, para um perfil de uso incomum não identificar ninguém.

### O que nunca é coletado

Nome dado ao fone, endereço Bluetooth, nome de rede Wi-Fi, nome de app, nome de Foco, nome de perfil, áudio, ou qualquer dado pessoal.

### Como é enviado

- Os contadores ficam no Mac, e só o dia já terminado é enviado.
- Vai por HTTPS, com tempo limite de 10 s, sem cookies. Uma falha só tenta de novo 6 h depois, e um pacote não enviado é descartado em 3 dias.
- Não sai em rede com Dados Reduzidos nem em modo avião.
- Não há SDK de terceiros: o código está em `Packages/QuietTelemetry` e `App/Sources/Telemetry.swift`.

### No servidor

O endpoint é uma função na AWS, com o código em [`infra/telemetry`](../infra/telemetry). Como em qualquer conexão, o IP chega até ela, mas a função não o lê nem o grava, e o pacote guardado não tem a hora do recebimento. Cada pacote é apagado em 400 dias.

## Som no Mac

O áudio é processado em memória, e nada é gravado ou enviado ([detalhes](AUDIO.md)).

## Teste interno

A aba Desenvolvedor tem um modo de teste, desligado por padrão, que grava eventos de uso em arquivos neste Mac. Nada desses arquivos vai para a rede, e nunca incluem áudio, nome de rede em texto ou conteúdo de janelas ([detalhes](DOGFOOD.md)).

## Permissões

A lista de permissões e o motivo de cada uma estão no [README](../README.md).
