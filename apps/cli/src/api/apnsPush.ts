import { sign } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { connect } from 'node:http2';
import { isAbsolute, join } from 'node:path';

import { logger } from '@/ui/logger';

import { readPushFetchTokensTimeoutMs } from './pushNotificationsConfig';

/**
 * Direct APNs delivery for native Apple clients, which register `apns:<environment>:<topic>:<hex>`
 * tokens instead of Expo tokens. Requires an APNs auth key of the app's team on this machine
 * (`apns.json` in the Happier home: `{ keyId, teamId, keyPath }`).
 */
export type ApnsPushToken = Readonly<{
  environment: 'sandbox' | 'production';
  topic: string;
  deviceToken: string;
}>;

export type ApnsCredentials = Readonly<{ keyId: string; teamId: string; privateKeyPem: string }>;

export type ApnsMessage = Readonly<{
  title: string;
  body: string;
  subtitle?: string;
  badge?: number;
  categoryId?: string;
  data?: Record<string, unknown>;
}>;

export type ApnsTransport = (request: Readonly<{
  origin: string;
  path: string;
  headers: Record<string, string>;
  body: string;
}>) => Promise<Readonly<{ status: number; body: string }>>;

const APNS_TOKEN = /^apns:(sandbox|production):([^:]+):([0-9a-fA-F]+)$/;

export function parseApnsPushToken(token: string): ApnsPushToken | null {
  const match = APNS_TOKEN.exec(token);
  if (!match) return null;
  return { environment: match[1] as ApnsPushToken['environment'], topic: match[2], deviceToken: match[3] };
}

export function readApnsCredentials(happierHomeDir: string): ApnsCredentials | null {
  const configPath = join(happierHomeDir, 'apns.json');
  if (!existsSync(configPath)) return null;
  try {
    const config = JSON.parse(readFileSync(configPath, 'utf8')) as { keyId?: unknown; teamId?: unknown; keyPath?: unknown };
    if (typeof config.keyId !== 'string' || typeof config.teamId !== 'string' || typeof config.keyPath !== 'string') {
      logger.infoFile('[PUSH] apns.json needs keyId, teamId and keyPath');
      return null;
    }
    const keyPath = isAbsolute(config.keyPath) ? config.keyPath : join(happierHomeDir, config.keyPath);
    return { keyId: config.keyId, teamId: config.teamId, privateKeyPem: readFileSync(keyPath, 'utf8') };
  } catch (error) {
    logger.infoFile('[PUSH] Could not read APNs credentials', { error: error instanceof Error ? error.message : String(error) });
    return null;
  }
}

/** ES256 provider token (`kid` = key id, `iss` = team id). APNs accepts it for up to an hour. */
export function createApnsAuthToken(credentials: ApnsCredentials, nowSec: number): string {
  const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const unsigned = `${encode({ alg: 'ES256', kid: credentials.keyId })}.${encode({ iss: credentials.teamId, iat: nowSec })}`;
  const signature = sign('sha256', Buffer.from(unsigned), { key: credentials.privateKeyPem, dsaEncoding: 'ieee-p1363' });
  return `${unsigned}.${signature.toString('base64url')}`;
}

/** Same payload shape the Expo service delivers: `data` travels under `body`. */
function buildApnsPayload(message: ApnsMessage): string {
  return JSON.stringify({
    aps: {
      alert: { title: message.title, ...(message.subtitle ? { subtitle: message.subtitle } : {}), body: message.body },
      sound: 'default',
      ...(message.badge !== undefined ? { badge: message.badge } : {}),
      ...(message.categoryId ? { category: message.categoryId } : {}),
    },
    body: message.data ?? {},
  });
}

function isDeadTokenResponse(status: number, body: string): boolean {
  if (status === 410) return true;
  if (status !== 400) return false;
  const reason = (() => {
    try {
      return (JSON.parse(body) as { reason?: unknown }).reason;
    } catch {
      return undefined;
    }
  })();
  return reason === 'BadDeviceToken' || reason === 'DeviceTokenNotForTopic';
}

export async function sendApnsNotifications(params: Readonly<{
  tokens: ReadonlyArray<string>;
  message: ApnsMessage;
  credentials: ApnsCredentials;
  transport?: ApnsTransport;
  nowSec?: number;
}>): Promise<Readonly<{ invalidTokens: ReadonlyArray<string> }>> {
  const transport = params.transport ?? http2ApnsTransport;
  const authorization = `bearer ${createApnsAuthToken(params.credentials, params.nowSec ?? Math.floor(Date.now() / 1000))}`;
  const body = buildApnsPayload(params.message);
  const invalidTokens: string[] = [];
  for (const token of params.tokens) {
    const target = parseApnsPushToken(token);
    if (!target) continue;
    try {
      const response = await transport({
        origin: target.environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com',
        path: `/3/device/${target.deviceToken}`,
        headers: { authorization, 'apns-topic': target.topic, 'apns-push-type': 'alert', 'apns-priority': '10' },
        body,
      });
      if (response.status === 200) continue;
      if (isDeadTokenResponse(response.status, response.body)) {
        invalidTokens.push(token);
      } else {
        logger.infoFile('[PUSH] APNs rejected notification', { status: response.status, body: response.body.slice(0, 200) });
      }
    } catch (error) {
      logger.infoFile('[PUSH] APNs request failed', { error: error instanceof Error ? error.message : String(error) });
    }
  }
  return { invalidTokens };
}

export const http2ApnsTransport: ApnsTransport = (request) =>
  new Promise((resolve, reject) => {
    const client = connect(request.origin);
    const fail = (error: Error) => {
      client.close();
      reject(error);
    };
    client.on('error', fail);
    const stream = client.request({
      ':method': 'POST',
      ':path': request.path,
      'content-type': 'application/json',
      ...request.headers,
    });
    // Reuses the push path's network budget so one stuck request cannot hold notifications forever.
    stream.setTimeout(readPushFetchTokensTimeoutMs(), () => {
      stream.close();
      fail(new Error('APNs request timed out'));
    });
    let status = 0;
    let body = '';
    stream.on('response', (headers) => {
      status = Number(headers[':status'] ?? 0);
    });
    stream.setEncoding('utf8');
    stream.on('data', (chunk: string) => {
      body += chunk;
    });
    stream.on('end', () => {
      client.close();
      resolve({ status, body });
    });
    stream.on('error', fail);
    stream.end(request.body);
  });
