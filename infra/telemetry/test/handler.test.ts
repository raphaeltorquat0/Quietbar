import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import { handle } from '../lambda/handler.js';
import { isPacket } from '../lambda/schema.js';

const sample = JSON.parse(readFileSync(new URL('./sample-v1.json', import.meta.url), 'utf8'));
const now = new Date('2026-09-22T10:00:00Z');
const post = (body: unknown) => ({
  body: typeof body === 'string' ? body : JSON.stringify(body),
  requestContext: { http: { method: 'POST', sourceIp: '203.0.113.7' } },
});
const put = async () => {};

test('aceita o pacote que o app gera', () => assert.ok(isPacket(sample, now)));

test('grava com a chave, o TTL de 400 dias e sem o IP', async () => {
  const items: Record<string, unknown>[] = [];
  const r = await handle(post(sample), async (i) => { items.push(i); }, now);
  assert.equal(r.statusCode, 204);
  assert.equal(items[0].pk, `${sample.installId}#2026-09-21`);
  assert.equal(items[0].expiresAt, Date.parse('2026-09-21T00:00:00Z') / 1000 + 400 * 86400);
  assert.ok(!JSON.stringify(items[0]).includes('203.0.113.7'));
  const { pk, expiresAt, ...rest } = items[0];
  assert.deepEqual(rest, sample);
});

test('recusa chave desconhecida em qualquer nível', () => {
  assert.ok(!isPacket({ ...sample, ssid: 'Casa' }, now));
  assert.ok(!isPacket({ ...sample, automation: { ...sample.automation, focusName: 'Trabalho' } }, now));
  assert.ok(!isPacket({ ...sample, modeChangesBySource: { ...sample.modeChangesBySource, app: 1 } }, now));
});

test('recusa nome de fone fora da lista, contador fora da faixa e chave ausente', () => {
  assert.ok(!isPacket({ ...sample, deviceModelFamily: 'Fone da Maria' }, now));
  assert.ok(!isPacket({ ...sample, panelOpens: 51 }, now));
  assert.ok(!isPacket({ ...sample, panelOpens: -1 }, now));
  const { arch, ...incomplete } = sample;
  assert.ok(!isPacket(incomplete, now));
  assert.ok(!isPacket({ ...sample, v: 2 }, now));
});

test('recusa data fora da janela ou inválida', () => {
  assert.ok(isPacket({ ...sample, date: '2026-09-18' }, now));
  assert.ok(!isPacket({ ...sample, date: '2026-09-17' }, now));
  assert.ok(!isPacket({ ...sample, date: '2026-09-24' }, now));
  assert.ok(!isPacket({ ...sample, date: '2026-02-31' }, new Date('2026-03-01T00:00:00Z')));
});

test('segundo pacote do mesmo dia e installId dá 409', async () => {
  const r = await handle(post(sample), async () => {
    throw new ConditionalCheckFailedException({ message: 'x', $metadata: {} });
  }, now);
  assert.equal(r.statusCode, 409);
});

test('outros erros', async () => {
  assert.equal((await handle({ requestContext: { http: { method: 'GET' } } }, put, now)).statusCode, 405);
  assert.equal((await handle(post('{'), put, now)).statusCode, 400);
  assert.equal((await handle(post('x'.repeat(3000)), put, now)).statusCode, 413);
  const encoded = { ...post(sample), body: Buffer.from(JSON.stringify(sample)).toString('base64'), isBase64Encoded: true };
  assert.equal((await handle(encoded, put, now)).statusCode, 204);
});
