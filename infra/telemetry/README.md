# Backend das métricas

Lambda Function URL que valida o pacote de [`docs/telemetry-schema.md`](../../docs/telemetry-schema.md), descarta o IP e grava no DynamoDB, com a chave `installId#date` e TTL de 400 dias. Um `installId` grava um pacote por dia: a repetição recebe 409.

O custo de um abuso é limitado pela concorrência reservada de 5 execuções.

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

Conta nova, com cota de 10 execuções simultâneas, recusa a reserva. Nesse caso:

```sh
npx cdk deploy -c reservedConcurrency=0
```

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
