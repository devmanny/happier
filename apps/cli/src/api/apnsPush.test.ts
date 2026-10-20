import { generateKeyPairSync, verify } from 'node:crypto';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it, vi } from 'vitest';

import {
  createApnsAuthToken,
  parseApnsPushToken,
  readApnsCredentials,
  sendApnsNotifications,
  type ApnsTransport,
} from './apnsPush';

vi.mock('@/ui/logger', () => ({ logger: { debug: vi.fn(), infoFile: vi.fn() } }));

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const credentials = {
  keyId: 'KEY123',
  teamId: 'TEAM45',
  privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
};

function decodeSegment(segment: string): unknown {
  return JSON.parse(Buffer.from(segment, 'base64url').toString('utf8'));
}

describe('parseApnsPushToken', () => {
  it('reads environment, topic and device token from a native app token', () => {
    expect(parseApnsPushToken('apns:sandbox:com.devmanny.happier:0aff01')).toEqual({
      environment: 'sandbox',
      topic: 'com.devmanny.happier',
      deviceToken: '0aff01',
    });
    expect(parseApnsPushToken('apns:production:com.devmanny.happier:ABCDEF')?.environment).toBe('production');
  });

  it('rejects Expo tokens and malformed native tokens', () => {
    expect(parseApnsPushToken('ExponentPushToken[abc]')).toBeNull();
    expect(parseApnsPushToken('apns:staging:com.x:0aff')).toBeNull();
    expect(parseApnsPushToken('apns:sandbox:com.x:not-hex')).toBeNull();
    expect(parseApnsPushToken('apns:sandbox::0aff')).toBeNull();
  });
});

describe('createApnsAuthToken', () => {
  it('signs an ES256 provider token APNs can verify', () => {
    const token = createApnsAuthToken(credentials, 1_700_000_000);
    const [header, claims, signature] = token.split('.');
    expect(decodeSegment(header)).toEqual({ alg: 'ES256', kid: 'KEY123' });
    expect(decodeSegment(claims)).toEqual({ iss: 'TEAM45', iat: 1_700_000_000 });
    const valid = verify(
      'sha256',
      Buffer.from(`${header}.${claims}`),
      { key: publicKey, dsaEncoding: 'ieee-p1363' },
      Buffer.from(signature, 'base64url'),
    );
    expect(valid).toBe(true);
  });
});

describe('readApnsCredentials', () => {
  it('loads the key referenced by apns.json in the Happier home', () => {
    const home = mkdtempSync(join(tmpdir(), 'happier-apns-'));
    writeFileSync(join(home, 'AuthKey.p8'), credentials.privateKeyPem);
    writeFileSync(join(home, 'apns.json'), JSON.stringify({ keyId: 'KEY123', teamId: 'TEAM45', keyPath: 'AuthKey.p8' }));
    expect(readApnsCredentials(home)).toEqual(credentials);
  });

  it('is null when push is not configured', () => {
    expect(readApnsCredentials(mkdtempSync(join(tmpdir(), 'happier-apns-')))).toBeNull();
  });
});

describe('sendApnsNotifications', () => {
  const message = {
    title: 'Fix login',
    subtitle: 'Bash',
    body: 'Claude asks permission to use Bash',
    badge: 3,
    categoryId: 'happier.permissionRequest.v1',
    data: { sessionId: 's1', requestId: 'r1', serverUrl: 'https://h.example' },
  };

  it('posts an alert to the token environment and reports dead tokens', async () => {
    const calls: Parameters<ApnsTransport>[0][] = [];
    const transport: ApnsTransport = async (request) => {
      calls.push(request);
      return request.path.endsWith('dead') ? { status: 410, body: '{"reason":"Unregistered"}' } : { status: 200, body: '' };
    };
    const result = await sendApnsNotifications({
      tokens: ['apns:sandbox:com.devmanny.happier:0aff', 'apns:production:com.devmanny.happier:dead'],
      message,
      credentials,
      transport,
      nowSec: 1_700_000_000,
    });

    expect(result.invalidTokens).toEqual(['apns:production:com.devmanny.happier:dead']);
    expect(calls.map((call) => [call.origin, call.path])).toEqual([
      ['https://api.sandbox.push.apple.com', '/3/device/0aff'],
      ['https://api.push.apple.com', '/3/device/dead'],
    ]);
    expect(calls[0].headers).toMatchObject({
      'apns-topic': 'com.devmanny.happier',
      'apns-push-type': 'alert',
      'apns-priority': '10',
    });
    expect(calls[0].headers.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    expect(JSON.parse(calls[0].body)).toEqual({
      aps: {
        alert: { title: 'Fix login', subtitle: 'Bash', body: 'Claude asks permission to use Bash' },
        sound: 'default',
        badge: 3,
        category: 'happier.permissionRequest.v1',
      },
      body: message.data,
    });
  });

  it('keeps tokens that failed for reasons other than the device', async () => {
    const transport: ApnsTransport = async () => ({ status: 403, body: '{"reason":"InvalidProviderToken"}' });
    const result = await sendApnsNotifications({
      tokens: ['apns:sandbox:com.devmanny.happier:0aff'],
      message,
      credentials,
      transport,
      nowSec: 1_700_000_000,
    });
    expect(result.invalidTokens).toEqual([]);
  });
});
