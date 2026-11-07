import { truncatePlainTextAtWordBoundary } from '@happier-dev/protocol';

/**
 * The turn's raw assistant reply, trimmed and bounded at a word boundary. Formatting (markdown,
 * line breaks, the options block) is kept: the notification formatter needs it.
 */
export function normalizeTurnAssistantText(
  value: string | null | undefined,
  params: Readonly<{ maxTextChars: number }>,
): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  return truncatePlainTextAtWordBoundary(trimmed, params.maxTextChars);
}
