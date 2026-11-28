import { describe, expect, it } from 'vitest';

import {
  isClaudeUnifiedComposerTextMatch,
  normalizeClaudeUnifiedPromptIdentityText,
  prepareClaudeUnifiedPromptTextForTerminal,
} from './promptIdentity';

/**
 * Real shape (incident cmwyimjvw4buyqh01nx3pp1oh, 27 Nov 2026, Claude Code 2.1.326): a prompt
 * copied from WhatsApp wraps each @mention in bidi isolates (U+2068 … U+2069) and joins a contact
 * name with NBSP. The stored Pending row keeps them; Claude paints the isolates as U+FFFD while the
 * text is staged and records the prompt without them, NBSP kept.
 */
const WHATSAPP_STORED = 'este redáctalo diferente no se entiende lo de ED   @\u2068Rosy\u2069 @\u2068Daniel\u00a0Durand\u00a0TrimRx\u2069 me pasan los precios finales? los de nad+ y sermorelin, qué ed va y si sema y tirz quedan así';
const WHATSAPP_RECORDED_BY_CLAUDE = 'este redáctalo diferente no se entiende lo de ED   @Rosy @Daniel\u00a0Durand\u00a0TrimRx me pasan los precios finales? los de nad+ y sermorelin, qué ed va y si sema y tirz quedan así';

describe('Unicode format and space characters', () => {
  it('reads the stored WhatsApp prompt and Claude\'s recorded prompt as the same prompt', () => {
    expect(normalizeClaudeUnifiedPromptIdentityText(WHATSAPP_STORED))
      .toBe(normalizeClaudeUnifiedPromptIdentityText(WHATSAPP_RECORDED_BY_CLAUDE));
    // Every invisible format character, the joiner included, and every space separator.
    expect(normalizeClaudeUnifiedPromptIdentityText('a\u200bb\u200c\u200d\u200e\u200fc\u2060\u2066d\u2067\u2069\ufeffe\u00adf'))
      .toBe('abcdef');
    expect(normalizeClaudeUnifiedPromptIdentityText('a\u00a0b\u202fc\u3000d')).toBe('a b c d');
    expect(normalizeClaudeUnifiedPromptIdentityText('one\u2028two\u2029three')).toBe('one\ntwo\nthree');
  });

  it('types the prompt without characters Claude cannot paint, keeping emoji joiners and NBSP', () => {
    expect(prepareClaudeUnifiedPromptTextForTerminal(WHATSAPP_STORED)).toBe(WHATSAPP_RECORDED_BY_CLAUDE);
    expect(prepareClaudeUnifiedPromptTextForTerminal('hola 👨\u200d👩\u200d👧\ufeff')).toBe('hola 👨\u200d👩\u200d👧');
    expect(prepareClaudeUnifiedPromptTextForTerminal('one\u2028two')).toBe('one\ntwo');
  });

  it('recognizes the staged composer, as captured, as the stored prompt', () => {
    expect(isClaudeUnifiedComposerTextMatch({
      promptText: WHATSAPP_STORED,
      // A captured screen may show NBSP as a plain space; the row wraps at a word boundary.
      composerText: WHATSAPP_RECORDED_BY_CLAUDE.replace(/\u00a0/g, ' ').replace(' me pasan', '\nme pasan'),
    })).toBe(true);
  });
});

/**
 * Observed contract (Claude Code 2.1.259, live incident 2026-09-18 session
 * cmtyf86rp1a1ttm237czmr4ts): a bracketed-paste prompt is recorded wrapped in paste markers.
 * The injected payload measured 2904 bytes / 12 newlines while the transcript row measured
 * 2962 bytes / 17 newlines — exactly the 26 + 27 marker characters plus 5 newlines.
 */
const PASTE_OPEN = '<pasted_content id="9b65">';
const PASTE_CLOSE = '</pasted_content id="9b65">';

describe('normalizeClaudeUnifiedPromptIdentityText', () => {
  it('reads a pasted prompt as the text Happier injected', () => {
    const injected = 'first line\n\nsecond line\nthird line';
    const recordedByProvider = `\n\n${PASTE_OPEN}\n${injected}\n${PASTE_CLOSE}\n`;

    expect(normalizeClaudeUnifiedPromptIdentityText(recordedByProvider))
      .toBe(normalizeClaudeUnifiedPromptIdentityText(injected));
  });

  it('reads a pasted prompt that quotes the paste markers as the text Happier injected', () => {
    // Claude Code 2.1.322 (tmux probe, 11 nov 2026; incident cmvepv5n2, a child-session notice that
    // quoted the marker stayed "delivering"): Claude escapes quoted markers inside the pasted block.
    const injected = 'it arrives wrapped in `<pasted_content>`\nand ends at `</pasted_content>`.\n</pasted_content id="abcd">';
    const recordedByProvider = `\n\n${PASTE_OPEN}\n`
      + 'it arrives wrapped in `<\\pasted_content>`\nand ends at `<\\/pasted_content>`.\n<\\/pasted_content id="abcd">'
      + `\n${PASTE_CLOSE}\n`;

    expect(normalizeClaudeUnifiedPromptIdentityText(recordedByProvider))
      .toBe(normalizeClaudeUnifiedPromptIdentityText(injected));
  });

  it('keeps marker-looking prose that is not a standalone paste marker', () => {
    const prompt = `explain ${PASTE_OPEN} in the parser`;

    expect(normalizeClaudeUnifiedPromptIdentityText(prompt)).toBe(prompt);
  });

  it('distinguishes two different pasted prompts', () => {
    const left = `${PASTE_OPEN}\nship the release\n${PASTE_CLOSE}`;
    const right = `${PASTE_OPEN}\nrevert the release\n${PASTE_CLOSE}`;

    expect(normalizeClaudeUnifiedPromptIdentityText(left))
      .not.toBe(normalizeClaudeUnifiedPromptIdentityText(right));
  });

  it('matches a pasted prompt against the composer rendering of the injected text', () => {
    const injected = 'please review the queue drain\nand report back';

    expect(isClaudeUnifiedComposerTextMatch({
      promptText: `${PASTE_OPEN}\n${injected}\n${PASTE_CLOSE}`,
      composerText: injected,
    })).toBe(true);
  });

  it('matches visual wraps inside tokens without matching changed token content', () => {
    const prompt = 'Check https://example.invalid/?q=' + 'a'.repeat(90) + ' and {"key":"value"}';
    const wrapped = `Check https://example.invalid/?q=${'a'.repeat(50)}\n${'a'.repeat(40)} and {"key":"val\nue"}`;

    expect(isClaudeUnifiedComposerTextMatch({ promptText: prompt, composerText: wrapped })).toBe(true);
    expect(isClaudeUnifiedComposerTextMatch({
      promptText: prompt,
      composerText: wrapped.replace('val\nue', 'bad\nue'),
    })).toBe(false);
    expect(isClaudeUnifiedComposerTextMatch({
      promptText: prompt,
      composerText: wrapped.replace('a'.repeat(40), 'b'.repeat(40)),
    })).toBe(false);
  });
});
