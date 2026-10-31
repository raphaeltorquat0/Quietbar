# Backend das métricas

Lambda Function URL que valida o pacote de [`docs/telemetry-schema.md`](../../docs/telemetry-schema.md), descarta o IP e grava no DynamoDB, com a chave `installId#date` e TTL de 400 dias. Um `installId` grava um pacote por dia: a repetição recebe 409.

O custo de um abuso é limitado pela concorrência reservada de 5 execuções, que é um teto: a sexta chamada simultânea recebe 429.

## Comandos

Pré-requisitos: Node 20+ e credenciais da AWS na conta certa (`aws sts get-caller-identity`).

```sh
cd infra/telemetry
npm ci
npm test
npx cdk bootstrap                 # só na primeira vez em cada conta e região
npx cdk diff
npx cdk deploy
```

Se o deploy falhar dizendo que a reserva deixaria o saldo da conta abaixo do mínimo, a conta tem cota baixa: a AWS exige manter 100 unidades sem reserva, e contas novas costumam ter menos que isso. Nesse caso, peça aumento da cota em Service Quotas, ou faça o deploy sem reserva:

```sh
npx cdk deploy -c reservedConcurrency=0
```

### O que `-c reservedConcurrency=0` faz

Omite `ReservedConcurrentExecutions` do template, o que foi conferido com `cdk synth`: com o padrão sai `5`, e com `0` a propriedade não existe. A função passa a usar a concorrência comum da conta.

- **Não é reservar 0 na AWS.** Na AWS, reserva 0 para a função. Aqui, 0 significa "sem reserva", e a função segue atendendo.
- **Custo:** some o teto de 5, e um abuso fica limitado só pela cota da conta. Cada chamada custa uma invocação e, se o pacote for válido, uma escrita. Vale criar um alarme de orçamento.
- **Efeito colateral:** se a função saturar a cota, outras funções da mesma conta podem ser limitadas.

Qualquer outro número define a reserva: `-c reservedConcurrency=2`.

O deploy imprime `TelemetryUrl` e `TableName`.

## Ligar o envio no app

Coloque a `TelemetryUrl` em `QuietbarTelemetryURL`, em `App/Support/Info.plist`, e gere a versão. Sem esse valor, o app não envia nada e não mostra a pergunta de opt-in.

## Relatório

```sh
scripts/telemetry-report --table <TableName>
```

Usa o AWS CLI com as credenciais da sessão. `--input <arquivo>` lê a saída de `aws dynamodb scan`.

## Apagar tudo

A tabela tem `RemovalPolicy.RETAIN`: `cdk destroy` não apaga os dados.

```sh
npx cdk destroy
aws dynamodb delete-table --table-name <TableName>
```
