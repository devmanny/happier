import type { DeepIndexSessionMeta } from './deepIndexDb';

function readText(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function readRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

/**
 * The title and agent a search hit shows, from decrypted session metadata: the same precedence
 * as the session lists (summary text, then name, then the folder name) and the raw `flavor`.
 */
export function readDeepIndexSessionMeta(metadata: Readonly<Record<string, unknown>> | null): DeepIndexSessionMeta {
  if (!metadata) return { title: null, agent: null };
  const summary = readRecord(metadata.summary);
  const folder = readText(metadata.path)
    ?.split(/[\\/]+/u)
    .filter((segment) => segment.length > 0)
    .pop() ?? null;
  return {
    title: readText(summary?.text) ?? readText(metadata.summaryText) ?? readText(metadata.name) ?? folder,
    agent: readText(metadata.flavor),
  };
}
