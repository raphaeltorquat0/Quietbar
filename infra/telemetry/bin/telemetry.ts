import { App } from 'aws-cdk-lib';
import { TelemetryStack } from '../lib/telemetry-stack.js';

const app = new App();
new TelemetryStack(app, 'QuietbarTelemetry', {
  // 0 aqui não reserva nada, ao contrário de reservar 0 na AWS, que para a função (README).
  reservedConcurrency: Number(app.node.tryGetContext('reservedConcurrency') ?? 5),
});
