import { App } from 'aws-cdk-lib';
import { TelemetryStack } from '../lib/telemetry-stack.js';

const app = new App();
new TelemetryStack(app, 'QuietbarTelemetry', {
  // Contas novas têm cota de 10 execuções e não aceitam reserva: use -c reservedConcurrency=0.
  reservedConcurrency: Number(app.node.tryGetContext('reservedConcurrency') ?? 5),
});
