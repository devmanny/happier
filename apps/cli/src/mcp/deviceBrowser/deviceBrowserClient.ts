import {
  DEVICE_BROWSER_MAX_WAIT_MS,
  DEVICE_BROWSER_RPC_SLOTS,
  DeviceBrowserRequestSchema,
  DeviceBrowserResponseSchema,
  deviceBrowserRpcMethod,
  type DeviceBrowserFailure,
  type DeviceBrowserRequest,
  type DeviceBrowserResponse,
} from '@happier-dev/protocol';
import { isRpcMethodNotAvailableError } from '@happier-dev/protocol/rpcErrors';

/** One encrypted account RPC to `<sessionMachineId>:<method>` (see `callExactMachineRpc`). */
export type DeviceBrowserTransport = (params: Readonly<{
  method: string;
  request: DeviceBrowserRequest;
  timeoutMs: number;
}>) => Promise<unknown>;

export type DeviceBrowserClient = Readonly<{
  invoke: (request: unknown) => Promise<DeviceBrowserResponse>;
}>;

const DEFAULT_TIMEOUT_MS = 30_000;
const NAVIGATION_TIMEOUT_MS = 60_000;
/** Relay + device overhead on top of the device-side wait, so the device answers first. */
const WAIT_MARGIN_MS = 15_000;
const DEFAULT_WAIT_MS = 10_000;

function failure(errorCode: DeviceBrowserFailure['errorCode'], error: string): DeviceBrowserFailure {
  return { ok: false, errorCode, error };
}

export function resolveDeviceBrowserTimeoutMs(request: DeviceBrowserRequest): number {
  switch (request.op) {
    case 'navigate':
      return NAVIGATION_TIMEOUT_MS;
    case 'wait':
      return Math.min(request.timeoutMs ?? request.durationMs ?? DEFAULT_WAIT_MS, DEVICE_BROWSER_MAX_WAIT_MS) + WAIT_MARGIN_MS;
    default:
      return DEFAULT_TIMEOUT_MS;
  }
}

/**
 * Sends one browser operation of one session to the user's Happier app. Slots are tried in contract order and a
 * later slot is addressed only when the relay proved no client serves the earlier one; a request
 * that may have reached a device is never re-sent elsewhere.
 */
export function createDeviceBrowserClient(
  transport: DeviceBrowserTransport,
  scope: Readonly<{ sessionId: string }>,
): DeviceBrowserClient {
  return {
    invoke: async (rawRequest) => {
      // The calling session owns the call: an agent cannot act for another session.
      const scoped = rawRequest && typeof rawRequest === 'object'
        ? { ...(rawRequest as Record<string, unknown>), sessionId: scope.sessionId }
        : rawRequest;
      const parsedRequest = DeviceBrowserRequestSchema.safeParse(scoped);
      if (!parsedRequest.success) {
        return failure('invalid_request', parsedRequest.error.issues.map((issue: { message: string }) => issue.message).join('; '));
      }
      const request = parsedRequest.data;
      const timeoutMs = resolveDeviceBrowserTimeoutMs(request);
      for (const slot of DEVICE_BROWSER_RPC_SLOTS) {
        let raw: unknown;
        try {
          raw = await transport({ method: deviceBrowserRpcMethod(slot), request, timeoutMs });
        } catch (error) {
          if (isRpcMethodNotAvailableError(error)) continue;
          const message = error instanceof Error ? error.message : String(error);
          return failure('unavailable', `The Happier app did not answer: ${message}`);
        }
        const parsed = DeviceBrowserResponseSchema.safeParse(raw);
        return parsed.success
          ? parsed.data
          : failure('unavailable', 'The Happier app answered with an unrecognized browser response; update the app.');
      }
      return failure(
        'unavailable',
        'No Happier app is serving the integrated browser. Open Happier on the Mac (always available) or open the browser in Happier on iPhone/iPad, then retry.',
      );
    },
  };
}
