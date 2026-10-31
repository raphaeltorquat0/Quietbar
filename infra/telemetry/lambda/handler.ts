import { ConditionalCheckFailedException, DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand } from '@aws-sdk/lib-dynamodb';
import { isPacket, type Packet } from './schema.js';

const MAX_BODY = 2048;
const TTL_DAYS = 400;
const DAY_SECONDS = 86_400;

interface UrlEvent {
  body?: string;
  isBase64Encoded?: boolean;
  requestContext?: { http?: { method?: string } };
}

type Put = (item: Record<string, unknown>) => Promise<void>;

/** O IP vem em `requestContext.http.sourceIp`: nada aqui lê esse campo, nem loga o evento. */
export async function handle(event: UrlEvent, put: Put, now = new Date()) {
  if (event.requestContext?.http?.method !== 'POST') return { statusCode: 405 };
  const raw = event.body ?? '';
  const body = event.isBase64Encoded ? Buffer.from(raw, 'base64').toString('utf8') : raw;
  if (Buffer.byteLength(body) > MAX_BODY) return { statusCode: 413 };
  let packet: unknown;
  try {
    packet = JSON.parse(body);
  } catch {
    return { statusCode: 400 };
  }
  if (!isPacket(packet, now)) return { statusCode: 400 };
  try {
    await put(item(packet));
  } catch (error) {
    // Limite por installId: um pacote por dia. A chave é o próprio limite.
    if (error instanceof ConditionalCheckFailedException) return { statusCode: 409 };
    throw error;
  }
  return { statusCode: 204 };
}

/** O vencimento sai do dia do pacote: a hora do recebimento não fica guardada. */
function item(p: Packet) {
  const expiresAt = Date.parse(`${p.date}T00:00:00Z`) / 1000 + TTL_DAYS * DAY_SECONDS;
  return { pk: `${p.installId}#${p.date}`, expiresAt, ...p };
}

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export const handler = (event: UrlEvent) =>
  handle(event, async (item) => {
    await db.send(new PutCommand({
      TableName: process.env.TABLE_NAME,
      Item: item,
      ConditionExpression: 'attribute_not_exists(pk)',
    }));
  });
