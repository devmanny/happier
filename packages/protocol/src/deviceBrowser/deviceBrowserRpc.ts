import { z } from 'zod';

/**
 * Integrated browser of a signed-in Happier app (native iPhone/iPad/Mac), driven by a session agent.
 *
 * Transport: an ordinary account RPC over the relay. The app's user-scoped socket registers
 * `<machineId>:<deviceBrowserRpcMethod(slot)>` for each machine it knows; the session process
 * calls it like any machine RPC, so params and result are end-to-end encrypted with that
 * machine's data key (plain machines stay plain). The daemon never registers these methods.
 *
 * Slots are last-registration-wins per account (relay behaviour). Callers try them in
 * `DEVICE_BROWSER_RPC_SLOTS` order and move to the next slot only when the relay reports that no
 * client serves the method, which proves the request reached nobody:
 * - `focused`: the device whose browser UI the user opened most recently (iPhone/iPad/Mac).
 * - `host`: an always-connected Mac app, the background host.
 */
export const DEVICE_BROWSER_RPC_SLOTS = ['focused', 'host'] as const;
export type DeviceBrowserRpcSlot = (typeof DEVICE_BROWSER_RPC_SLOTS)[number];

export function deviceBrowserRpcMethod(slot: DeviceBrowserRpcSlot): string {
  return `device.browser.v1.${slot}`;
}

/**
 * Upper bound of one `wait` step. The relay forwards an RPC for at most 300 s
 * (`HAPPIER_RPC_FORWARD_MAX_TIMEOUT_MS`); a wait stays well inside it so the device answers
 * with a typed `timeout` instead of the relay dropping the call.
 */
export const DEVICE_BROWSER_MAX_WAIT_MS = 120_000;

const TabId = z.string().trim().min(1);
const ElementRef = z.string().trim().min(1);
const Selector = z.string().trim().min(1);

const tabTarget = { tabId: TabId.optional() };
const elementTarget = { ref: ElementRef.optional(), selector: Selector.optional() };

function hasAtMostOneElementTarget(value: { ref?: string; selector?: string }): boolean {
  return !(value.ref !== undefined && value.selector !== undefined);
}

function hasExactlyOneElementTarget(value: { ref?: string; selector?: string }): boolean {
  return (value.ref !== undefined) !== (value.selector !== undefined);
}

const StatusRequest = z.object({ op: z.literal('status') }).strict();

const NavigateRequest = z.object({
  op: z.literal('navigate'),
  ...tabTarget,
  url: z.string().trim().min(1).optional(),
  action: z.enum(['go', 'back', 'forward', 'reload']).optional(),
  newTab: z.boolean().optional(),
}).strict().refine(
  (value) => (value.action ?? 'go') === 'go' ? value.url !== undefined : true,
  { path: ['url'], message: 'url is required to navigate' },
);

const ScreenshotRequest = z.object({
  op: z.literal('screenshot'),
  ...tabTarget,
  fullPage: z.boolean().optional(),
}).strict();

const SnapshotRequest = z.object({
  op: z.literal('snapshot'),
  ...tabTarget,
  maxChars: z.number().int().positive().optional(),
}).strict();

const ClickRequest = z.object({
  op: z.literal('click'),
  ...tabTarget,
  ...elementTarget,
}).strict().refine(hasExactlyOneElementTarget, { message: 'Provide exactly one of ref or selector' });

const TypeRequest = z.object({
  op: z.literal('type'),
  ...tabTarget,
  ...elementTarget,
  text: z.string(),
  clear: z.boolean().optional(),
  submit: z.boolean().optional(),
}).strict().refine(hasAtMostOneElementTarget, { message: 'Provide at most one of ref or selector' });

const ScrollRequest = z.object({
  op: z.literal('scroll'),
  ...tabTarget,
  ...elementTarget,
  deltaX: z.number().optional(),
  deltaY: z.number().optional(),
  to: z.enum(['top', 'bottom']).optional(),
}).strict().refine(hasAtMostOneElementTarget, { message: 'Provide at most one of ref or selector' });

const EvaluateRequest = z.object({
  op: z.literal('evaluate'),
  ...tabTarget,
  script: z.string().min(1),
}).strict();

const WaitRequest = z.object({
  op: z.literal('wait'),
  ...tabTarget,
  selector: Selector.optional(),
  text: z.string().min(1).optional(),
  urlIncludes: z.string().min(1).optional(),
  durationMs: z.number().int().positive().max(DEVICE_BROWSER_MAX_WAIT_MS).optional(),
  timeoutMs: z.number().int().positive().max(DEVICE_BROWSER_MAX_WAIT_MS).optional(),
}).strict().refine(
  (value) => [value.selector, value.text, value.urlIncludes, value.durationMs].some((item) => item !== undefined),
  { message: 'Provide selector, text, urlIncludes or durationMs' },
);

const TabsRequest = z.object({
  op: z.literal('tabs'),
  action: z.enum(['list', 'new', 'select', 'close']),
  tabId: TabId.optional(),
  url: z.string().trim().min(1).optional(),
}).strict().refine(
  (value) => value.action === 'select' || value.action === 'close' ? value.tabId !== undefined : true,
  { path: ['tabId'], message: 'tabId is required' },
);

export const DeviceBrowserRequestSchema = z.union([
  StatusRequest,
  NavigateRequest,
  ScreenshotRequest,
  SnapshotRequest,
  ClickRequest,
  TypeRequest,
  ScrollRequest,
  EvaluateRequest,
  WaitRequest,
  TabsRequest,
]);
export type DeviceBrowserRequest = z.infer<typeof DeviceBrowserRequestSchema>;
export type DeviceBrowserOperation = DeviceBrowserRequest['op'];

export const DeviceBrowserDeviceSchema = z.object({
  name: z.string(),
  platform: z.enum(['ios', 'ipados', 'macos']),
}).strict();
export type DeviceBrowserDevice = z.infer<typeof DeviceBrowserDeviceSchema>;

export const DeviceBrowserTabSchema = z.object({
  id: TabId,
  url: z.string(),
  title: z.string(),
  selected: z.boolean(),
  loading: z.boolean(),
}).strict();
export type DeviceBrowserTab = z.infer<typeof DeviceBrowserTabSchema>;

export const DEVICE_BROWSER_ERROR_CODES = [
  'invalid_request',
  'disabled',
  'tab_not_found',
  'element_not_found',
  'navigation_failed',
  'script_error',
  'timeout',
  'unavailable',
] as const;
export type DeviceBrowserErrorCode = (typeof DEVICE_BROWSER_ERROR_CODES)[number];

export const DeviceBrowserSuccessSchema = z.object({
  ok: z.literal(true),
  device: DeviceBrowserDeviceSchema,
  tab: DeviceBrowserTabSchema.optional(),
  tabs: z.array(DeviceBrowserTabSchema).optional(),
  /** Snapshot text or other human-readable output. */
  text: z.string().optional(),
  truncated: z.boolean().optional(),
  /** JSON result of `evaluate`. */
  value: z.unknown().optional(),
  image: z.object({
    mimeType: z.literal('image/png'),
    data: z.string().min(1),
    width: z.number().int().nonnegative(),
    height: z.number().int().nonnegative(),
  }).strict().optional(),
}).strict();
export type DeviceBrowserSuccess = z.infer<typeof DeviceBrowserSuccessSchema>;

export const DeviceBrowserFailureSchema = z.object({
  ok: z.literal(false),
  errorCode: z.enum(DEVICE_BROWSER_ERROR_CODES),
  error: z.string(),
}).strict();
export type DeviceBrowserFailure = z.infer<typeof DeviceBrowserFailureSchema>;

export const DeviceBrowserResponseSchema = z.discriminatedUnion('ok', [
  DeviceBrowserSuccessSchema,
  DeviceBrowserFailureSchema,
]);
export type DeviceBrowserResponse = z.infer<typeof DeviceBrowserResponseSchema>;
