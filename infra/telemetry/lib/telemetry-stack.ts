import { CfnOutput, Duration, RemovalPolicy, Stack, type StackProps } from 'aws-cdk-lib';
import { AttributeType, BillingMode, Table } from 'aws-cdk-lib/aws-dynamodb';
import { Architecture, FunctionUrlAuthType, Runtime } from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import { LogGroup, RetentionDays } from 'aws-cdk-lib/aws-logs';
import type { Construct } from 'constructs';
import { fileURLToPath } from 'node:url';

export interface TelemetryStackProps extends StackProps {
  /** Teto de execuções simultâneas: é o que limita o custo de um abuso. 0 omite a reserva, e a função fica sem teto próprio. */
  reservedConcurrency: number;
}

export class TelemetryStack extends Stack {
  constructor(scope: Construct, id: string, props: TelemetryStackProps) {
    super(scope, id, props);

    const table = new Table(this, 'Packets', {
      partitionKey: { name: 'pk', type: AttributeType.STRING },
      billingMode: BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'expiresAt',
      removalPolicy: RemovalPolicy.RETAIN,
    });

    const ingest = new NodejsFunction(this, 'Ingest', {
      entry: fileURLToPath(new URL('../lambda/handler.ts', import.meta.url)),
      runtime: Runtime.NODEJS_22_X,
      architecture: Architecture.ARM_64,
      memorySize: 128,
      timeout: Duration.seconds(3),
      reservedConcurrentExecutions: props.reservedConcurrency || undefined,
      logGroup: new LogGroup(this, 'IngestLogs', {
        retention: RetentionDays.TWO_WEEKS,
        removalPolicy: RemovalPolicy.DESTROY,
      }),
      environment: { TABLE_NAME: table.tableName },
      bundling: { externalModules: ['@aws-sdk/*'], minify: true },
    });
    table.grant(ingest, 'dynamodb:PutItem');

    // Sem autenticação: o app é aberto, então um segredo no binário não protegeria nada.
    const url = ingest.addFunctionUrl({ authType: FunctionUrlAuthType.NONE });

    new CfnOutput(this, 'TelemetryUrl', { value: url.url });
    new CfnOutput(this, 'TableName', { value: table.tableName });
  }
}
