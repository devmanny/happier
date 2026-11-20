import { parseOptionsFromText } from './agentResponseOptions.js';

/**
 * Extracts plain text from markdown by removing formatting.
 * Canonical markdown→plain-preview owner (session list/transcript previews in the UI, push bodies).
 */
export function stripMarkdown(text: string): string {
  return text
    // Remove code blocks (before inline code, whose backticks would otherwise split the fences)
    .replace(/```[\s\S]*?```/g, '[code]')
    // Remove headers
    .replace(/^#{1,6}\s+/gm, '')
    // Remove table separator rows (|---|---| and :---: variants)
    .replace(/^\s*\|?[\s:|-]+\|[\s:|-]*$/gm, '')
    // Replace remaining table pipes with spaces
    .replace(/\|/g, ' ')
    // Remove bold and italic
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\*([^*]+)\*/g, '$1')
    .replace(/__([^_]+)__/g, '$1')
    .replace(/_([^_]+)_/g, '$1')
    // Remove inline code
    .replace(/`([^`]+)`/g, '$1')
    // Remove links
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    // Remove horizontal rules
    .replace(/^---+$/gm, '')
    // Remove list markers
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/^\s*\d+\.\s+/gm, '')
    // Clean up multiple whitespace
    .replace(/\s+/g, ' ')
    .trim();
}

const ELLIPSIS = '…';

/**
 * At most `maxChars` code points (ellipsis included): cut at the last word boundary and end with
 * «…» only when the text did not fit. A single word longer than half the bound is hard-cut.
 */
export function truncatePlainTextAtWordBoundary(text: string, maxChars: number): string {
  const points = Array.from(text);
  const max = Math.max(1, Math.trunc(maxChars));
  if (points.length <= max) return text;

  const head = points.slice(0, max - 1);
  let cut = head.length;
  for (let index = head.length; index > 0; index -= 1) {
    if (/\s/.test(points[index] ?? '')) {
      cut = index;
      break;
    }
  }
  if (cut < head.length && cut < Math.floor(max / 2)) cut = head.length;
  const kept = head.slice(0, cut).join('').replace(/[\s,;:.\-–—]+$/u, '');
  return `${kept || head.join('')}${ELLIPSIS}`;
}

const EMOJI = String.raw`(?:\p{Extended_Pictographic}|\p{Emoji_Modifier}|\p{Regional_Indicator}|‍|️|⃣)`;
const TRAILING_EMOJIS = new RegExp(String.raw`(?:\s*${EMOJI})+\s*$`, 'u');
const SIGNATURE_BOUNDARY = String.raw`(^|[.!?…:)\]])\s*(?:[-–—]\s*)?`;
/** «Mateo 🤖», «— Leo 🤖»: a one-to-three-word capitalized name and emoji closing the reply. */
const GENERIC_SIGNATURE = new RegExp(
  String.raw`${SIGNATURE_BOUNDARY}\p{Lu}[\p{L}'’-]*(?:\s+\p{Lu}[\p{L}'’-]*){0,2}(?:\s*${EMOJI})+\s*$`,
  'u',
);

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function stripTrailingSignature(text: string, agentName: string | null): string {
  let result = text.replace(GENERIC_SIGNATURE, '$1');
  if (agentName) {
    const named = new RegExp(String.raw`${SIGNATURE_BOUNDARY}${escapeRegExp(agentName)}(?:\s*${EMOJI})*\s*$`, 'iu');
    result = result.replace(named, '$1');
  }
  return result.replace(TRAILING_EMOJIS, '').trim();
}

/**
 * Notification actions are button-sized and travel in the push payload next to the body: four
 * options of 120 code points stay under half of the 4096-byte APNs/Expo payload even at four
 * UTF-8 bytes per code point, so they cannot crowd out the body or routing data.
 */
const MAX_PREVIEW_OPTIONS = 4;
const MAX_PREVIEW_OPTION_CHARS = 120;

function collapseWhitespace(value: string): string {
  return value.replace(/\s+/g, ' ').trim();
}

export type AssistantMessagePreview = Readonly<{
  /** Plain one-paragraph text; empty when nothing but options/signature remains. */
  text: string;
  /** Texts of the reply's `<options>` block, at most four, each bounded. */
  options: ReadonlyArray<string>;
}>;

/**
 * Plain preview of a raw agent reply: options block removed (also an unterminated one left by a
 * truncated reply) and returned separately, markdown stripped, closing signature and loose
 * emojis dropped, whitespace collapsed, and cut at a word boundary when `maxChars` is given.
 */
export function buildAssistantMessagePreview(
  raw: string,
  params: Readonly<{ agentName?: string | null; maxChars?: number }> = {},
): AssistantMessagePreview {
  const parsed = parseOptionsFromText(raw);
  const withoutOptions = parsed.text
    .replace(/<options>[\s\S]*$/i, '')
    .replace(/<\/?options?>/gi, ' ');
  const agentName = typeof params.agentName === 'string' ? collapseWhitespace(params.agentName) : '';
  const plain = collapseWhitespace(stripTrailingSignature(stripMarkdown(withoutOptions), agentName || null));
  const text = params.maxChars === undefined ? plain : truncatePlainTextAtWordBoundary(plain, params.maxChars);
  const options = parsed.options
    .map((option) => truncatePlainTextAtWordBoundary(collapseWhitespace(stripMarkdown(option)), MAX_PREVIEW_OPTION_CHARS))
    .filter((option) => option.length > 0)
    .slice(0, MAX_PREVIEW_OPTIONS);
  return { text, options };
}
