import { buildAssistantMessagePreview } from '../text/plainTextPreview.js';

type ReadyNotificationContent = Readonly<{
  title: string;
  /** The agent the session works as, when it has one. */
  subtitle?: string;
  body: string;
  /** The reply's one-tap answers (empty when previews are off or the reply has none). */
  options: ReadonlyArray<string>;
}>;

function normalizeNotificationText(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.replace(/\s+/g, ' ').trim();
  return normalized.length > 0 ? normalized : null;
}

/**
 * Title/subtitle/body of the "turn finished" notification. `messageText` is the raw assistant
 * reply; the outbound push boundary bounds the body's length.
 */
export function buildReadyNotificationContent(params: Readonly<{
  sessionTitle?: string | null;
  defaultTitle: string;
  waitingForCommandLabel: string;
  fallbackBody: string;
  includeMessageText?: boolean;
  messageText?: string | null;
  agentName?: string | null;
}>): ReadyNotificationContent {
  const title =
    normalizeNotificationText(params.sessionTitle) ??
    normalizeNotificationText(params.defaultTitle) ??
    normalizeNotificationText(params.waitingForCommandLabel) ??
    'Session';
  const subtitle = normalizeNotificationText(params.agentName);

  const preview = params.includeMessageText === false || typeof params.messageText !== 'string'
    ? null
    : buildAssistantMessagePreview(params.messageText, { agentName: subtitle });
  const fallbackBody =
    normalizeNotificationText(params.fallbackBody) ??
    `${normalizeNotificationText(params.waitingForCommandLabel) ?? 'Session'} is waiting for your command`;

  return {
    title,
    ...(subtitle ? { subtitle } : {}),
    body: preview?.text || fallbackBody,
    options: preview?.options ?? [],
  };
}
