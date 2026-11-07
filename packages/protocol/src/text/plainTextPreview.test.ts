import { describe, expect, it } from 'vitest';

import {
  buildAssistantMessagePreview,
  stripMarkdown,
  truncatePlainTextAtWordBoundary,
} from './plainTextPreview.js';

const MATEO_MESSAGE =
  'Ya está abierto en Safari: **BeyondGLP Protocol,  USD al mes**, con tarjeta, Apple Pay y Link. '
  + 'El correo visible pertenece al usuario ficticio de revisión. **No se realizó ningún cobro.** '
  + 'Mateo 🤖 <options> <option>Preparar la compra controlada con mi c';

describe('stripMarkdown', () => {
  it('removes headers, emphasis, links, lists and inline code', () => {
    expect(stripMarkdown('# Title\n\n- **Bold** item\n- see [the docs](https://x.test)\n1. run `yarn test`'))
      .toBe('Title Bold item see the docs run yarn test');
  });

  it('replaces fenced code blocks with a placeholder', () => {
    expect(stripMarkdown('Before\n```ts\nconst a = 1;\n```\nAfter')).toBe('Before [code] After');
  });
});

describe('truncatePlainTextAtWordBoundary', () => {
  it('keeps text that fits', () => {
    expect(truncatePlainTextAtWordBoundary('short text', 20)).toBe('short text');
  });

  it('cuts at the last word boundary and appends an ellipsis within the bound', () => {
    const result = truncatePlainTextAtWordBoundary('The quick brown fox jumps over the lazy dog', 20);
    expect(result).toBe('The quick brown fox…');
    expect(Array.from(result).length).toBeLessThanOrEqual(20);
  });

  it('drops trailing punctuation before the ellipsis', () => {
    expect(truncatePlainTextAtWordBoundary('Alpha beta, gamma delta epsilon', 13)).toBe('Alpha beta…');
  });

  it('hard-cuts a single long word without splitting surrogate pairs', () => {
    const result = truncatePlainTextAtWordBoundary('🧪'.repeat(30), 10);
    expect(result).toBe(`${'🧪'.repeat(9)}…`);
  });
});

describe('buildAssistantMessagePreview', () => {
  it('cleans a real agent message: markdown, signature and an unterminated options block', () => {
    const preview = buildAssistantMessagePreview(MATEO_MESSAGE);
    expect(preview.text).toBe(
      'Ya está abierto en Safari: BeyondGLP Protocol, USD al mes, con tarjeta, Apple Pay y Link. '
      + 'El correo visible pertenece al usuario ficticio de revisión. No se realizó ningún cobro.',
    );
    expect(preview.text).not.toContain('*');
    expect(preview.text).not.toContain('<options>');
    expect(preview.text).not.toContain('Mateo');
    expect(preview.text.endsWith('…')).toBe(false);
    expect(preview.options).toEqual([]);
  });

  it('returns the options of a complete options block separately', () => {
    const preview = buildAssistantMessagePreview(
      'Which one?\n\n<options>\n  <option>Run the **tests**</option>\n  <option>Ship it</option>\n</options>',
    );
    expect(preview).toEqual({ text: 'Which one?', options: ['Run the tests', 'Ship it'] });
  });

  it('keeps at most four options and bounds each one', () => {
    const long = 'word '.repeat(100).trim();
    const preview = buildAssistantMessagePreview(
      `Pick.<options>${['a', 'b', 'c', 'd', 'e'].map((o) => `<option>${o}</option>`).join('')}<option>${long}</option></options>`,
    );
    expect(preview.options).toEqual(['a', 'b', 'c', 'd']);
    const withLong = buildAssistantMessagePreview(`Pick.<options><option>${long}</option></options>`);
    expect(withLong.options[0]!.endsWith('…')).toBe(true);
    expect(withLong.options[0]!.length).toBeLessThan(long.length);
  });

  it('strips signature variants and trailing loose emojis', () => {
    expect(buildAssistantMessagePreview('Done.\n\n— Mateo 🤖').text).toBe('Done.');
    expect(buildAssistantMessagePreview('Done.\n\n**Leo 🤖**').text).toBe('Done.');
    expect(buildAssistantMessagePreview('Listo, ya quedó. Julián').text).toBe('Listo, ya quedó. Julián');
    expect(buildAssistantMessagePreview('Listo, ya quedó.\nJulián', { agentName: 'Julián' }).text).toBe('Listo, ya quedó.');
    expect(buildAssistantMessagePreview('All tests pass ✅ 🎉').text).toBe('All tests pass');
    expect(buildAssistantMessagePreview('Send it to Pedro 🤖 later').text).toBe('Send it to Pedro 🤖 later');
  });

  it('truncates at a word boundary only when the text exceeds the bound', () => {
    expect(buildAssistantMessagePreview('One two three four five', { maxChars: 14 }).text).toBe('One two three…');
    expect(buildAssistantMessagePreview('One two', { maxChars: 14 }).text).toBe('One two');
  });

  it('is empty when the message only holds a signature and options', () => {
    expect(buildAssistantMessagePreview('Mateo 🤖\n<options><option>Yes</option></options>')).toEqual({ text: '', options: ['Yes'] });
  });
});
