import { describe, expect, it } from 'vitest';

import { createClaudeOwnComposerTextLog } from './ownComposerTextLog';

describe('createClaudeOwnComposerTextLog (lane X, incident cmq8y3nlx user_draft starvation)', () => {
  it('matches a draft EXACTLY equal to a recorded injected prompt', () => {
    const log = createClaudeOwnComposerTextLog();
    log.record('please continue with the refactor');
    expect(log.matches('please continue with the refactor')).toBe(true);
    expect(log.matches('  please continue with the refactor \n')).toBe(true);
  });

  it('does not treat one line of a recorded multiline injection as clearable own residue', () => {
    const log = createClaudeOwnComposerTextLog();
    const prompt = 'first instruction line\nsecond instruction line\r\nthird line';
    log.record(prompt);

    expect(log.matches(prompt)).toBe(true);
    expect(log.matches('third line')).toBe(false);
    expect(log.matches('second instruction line')).toBe(false);
  });

  it('does not match a genuine edited draft with a one-letter suffix after a recorded prompt', () => {
    const log = createClaudeOwnComposerTextLog();
    const prompt = 'please continue with the refactor';
    log.record(prompt);

    expect(log.matches(`${prompt} d`)).toBe(false);
    expect(log.matches(`${prompt}\nd`)).toBe(false);
  });

  it('NEVER matches genuine user text, partial overlaps, or empty drafts', () => {
    const log = createClaudeOwnComposerTextLog();
    log.record('/effort medium');
    log.record('please continue');
    expect(log.matches('medium/effort medium')).toBe(false);
    expect(log.matches('please continue!')).toBe(false);
    expect(log.matches('please')).toBe(false);
    expect(log.matches('')).toBe(false);
    expect(log.matches('   ')).toBe(false);
  });

  it('matches a long visible window while the own injection remains recorded but rejects short windows', () => {
    let nowMs = 10_000;
    const log = createClaudeOwnComposerTextLog({
      nowMs: () => nowMs,
      prefixResidueWindowMs: 5_000,
    });
    const longPrompt = `please continue with the full implementation ${'x'.repeat(320)}`;
    log.record(longPrompt);

    expect(log.matches(longPrompt.slice(0, 280))).toBe(true);
    expect(log.matches(longPrompt.slice(-280))).toBe(true);
    expect(log.matches(longPrompt.slice(-80))).toBe(false);

    nowMs += 5_001;
    expect(log.matches(longPrompt.slice(-280))).toBe(true);
  });

  it('matches a short prefix only after a risky terminal write marked it as possible own residue', () => {
    let nowMs = 10_000;
    const log = createClaudeOwnComposerTextLog({
      nowMs: () => nowMs,
      prefixResidueWindowMs: 5_000,
    });
    const longPrompt = `please produce the full report ${'x'.repeat(320)}`;
    const shortResidue = longPrompt.slice(0, 34);
    log.record(longPrompt);

    expect(log.matches(shortResidue)).toBe(false);

    log.recordPossiblePartialResidue(longPrompt);

    expect(log.matches(shortResidue)).toBe(true);
    expect(log.matches('please produce a different draft')).toBe(false);

    nowMs += 5_001;
    expect(log.matches(shortResidue)).toBe(false);
  });

  it('keeps very short prefix clearing scoped to durable provider-claimed residue', () => {
    let nowMs = 10_000;
    const log = createClaudeOwnComposerTextLog({
      nowMs: () => nowMs,
      prefixResidueWindowMs: 5_000,
    });
    const longPrompt = `continue the exact pending message ${'x'.repeat(320)}`;
    const shortProviderResidue = longPrompt.slice(0, 19);
    log.record(longPrompt);

    log.recordPossiblePartialResidue(longPrompt);
    expect(log.matches(shortProviderResidue)).toBe(false);

    log.recordPossiblePartialResidue(longPrompt, { minPrefixChars: 16 });
    expect(log.matches(shortProviderResidue)).toBe(true);
    expect(log.matches('continue a different')).toBe(false);

    nowMs += 5_001;
    expect(log.matches(shortProviderResidue)).toBe(false);
  });

  it('matches a recent Claude collapsed paste marker for a recorded multiline injection', () => {
    let nowMs = 10_000;
    const log = createClaudeOwnComposerTextLog({
      nowMs: () => nowMs,
      prefixResidueWindowMs: 5_000,
    });
    const prompt = Array.from({ length: 41 }, (_, index) => `line ${index}`).join('\n');
    log.record(prompt);

    expect(log.matches('[Pasted text #1 +40 lines]')).toBe(true);
    expect(log.matches('[Pasted text +40 lines]')).toBe(true);
    expect(log.matches('[Pasted text #1 +39 lines]')).toBe(true);
    expect(log.matches('[Pasted text #1 +43 lines]')).toBe(true);
    expect(log.matches('[Pasted text #1 +44 lines]')).toBe(false);

    nowMs += 5_001;
    expect(log.matches('[Pasted text #1 +40 lines]')).toBe(false);
  });

  it('keeps large collapsed paste markers matchable through the scaled provider-acceptance wait', () => {
    let nowMs = 10_000;
    const log = createClaudeOwnComposerTextLog({ nowMs: () => nowMs });
    const prompt = Array.from({ length: 3_663 }, (_, index) => `line ${index}`).join('\n');
    log.record(prompt);

    nowMs += 181_000;
    expect(log.matches('[Pasted text #1 +3662 lines]')).toBe(true);

    nowMs += 10 * 60_000;
    expect(log.matches('[Pasted text #1 +3662 lines]')).toBe(false);
  });

  it.each(['record', 'recordPossiblePartialResidue'] as const)('preserves pasted newlines before semantic normalization through %s', (recordMethod) => {
    const body = Array.from({ length: 14 }, (_, index) => `line ${index}`).join('\n');
    for (const prompt of [
      `\n\n${body}\n\n\n`,
      `\n\n<pasted_content id="probe">\n${body}\n</pasted_content id="probe">\n`.replace(/\n/g, '\r\n'),
    ]) {
      const log = createClaudeOwnComposerTextLog();
      // Same semantic identity, but a different paste. Partial-write recording must retain
      // the actual newlines rather than updating the earlier normalized entry.
      log.record(body);
      log[recordMethod](prompt);

      expect(log.matches('[Pasted text #1 +18 lines]')).toBe(true);
      expect(log.matches(body)).toBe(true);
      expect(log.matches('[Pasted text #1 +22 lines]')).toBe(false);
      expect(log.matches('my draft [Pasted text #1 +18 lines]')).toBe(false);
    }
  });

  it('does not match a genuine draft that merely contains a Claude collapsed paste marker', () => {
    const log = createClaudeOwnComposerTextLog();
    const prompt = Array.from({ length: 41 }, (_, index) => `line ${index}`).join('\n');
    log.record(prompt);

    expect(log.matches('please explain why [Pasted text #1 +40 lines] happened')).toBe(false);
  });

  it('does not match Claude collapsed paste markers for single-line injections', () => {
    const log = createClaudeOwnComposerTextLog();
    log.record('please continue with the refactor');
    expect(log.matches('[Pasted text #1 +0 lines]')).toBe(false);
    expect(log.matches('[Pasted text #1 +1 lines]')).toBe(false);
    expect(log.matches('[Pasted text #1]')).toBe(false);
  });

  describe('drafts made of whole recorded prompts pasted back to back (Pending blocked incident, 2026-11-16)', () => {
    // A stalled TUI painted an earlier own paste and a later Send Again paste together; the short
    // concatenation was classified foreign, so it was never cleared and blocked every later send.
    const first = 'I signed in, but I do not see the Beta organizations.';
    const urlPrompt = `https://example.test/dashboard ${first}`;

    function logWithBothPrompts() {
      const log = createClaudeOwnComposerTextLog();
      log.record(first);
      log.record(urlPrompt);
      return log;
    }

    it('matches two or more complete recorded entries with nothing or only whitespace between them', () => {
      const log = logWithBothPrompts();

      expect(log.matches(`${first}${urlPrompt}`)).toBe(true);
      expect(log.matches(`${first} ${urlPrompt}`)).toBe(true);
      expect(log.matches(`${first}\n${urlPrompt}`)).toBe(true);
      expect(log.matches(`${first}${first}${urlPrompt}`)).toBe(true);
      expect(log.matches(`${first}${first}`)).toBe(true);
    });

    it('matches the concatenation when the TUI soft-wraps it across rows', () => {
      const log = logWithBothPrompts();
      const wrapped = `${first}https://example.test/dashboard I signed in, but I do\nnot see the Beta organizations.`;

      expect(log.matches(wrapped)).toBe(true);
    });

    it('never matches partial entries, truncated entries, or any extra user text', () => {
      const log = logWithBothPrompts();

      expect(log.matches(`${first} d`)).toBe(false);
      expect(log.matches(`${first}${urlPrompt} d`)).toBe(false);
      expect(log.matches(`${first} and also my own words`)).toBe(false);
      expect(log.matches(`my own words ${first}`)).toBe(false);
      expect(log.matches(`${first.slice(0, 20)}${urlPrompt}`)).toBe(false);
      expect(log.matches(`${first}${urlPrompt.slice(0, -4)}`)).toBe(false);
      expect(log.matches(`${first}${urlPrompt.slice(8)}`)).toBe(false);
      expect(log.matches(`${first}, ${urlPrompt}`)).toBe(false);
    });

    it('never matches short replies typed together, even when each one was sent before', () => {
      // The log also holds transcript-seeded and controller-typed entries. Short ones carry no
      // identity: a user at the Mac typing "sí dale" is writing, not looking at our residue.
      const log = logWithBothPrompts();
      for (const reply of ['sí', 'dale', 'ok', 'gracias', 'commit', 'push', '1', '2']) log.record(reply);

      for (const draft of [
        'sí dale', 'sídale', 'ok gracias', 'commit push', 'sí sí', 'okok', '12', '21 1',
        `${first} ok`, `ok ${first}`, `${first}\nsí`,
      ]) {
        expect(log.matches(draft), draft).toBe(false);
      }
      expect(log.matches(`${first}\n${urlPrompt}`)).toBe(true);
    });
  });

  it('is bounded: oldest entries are evicted beyond the limit', () => {
    const log = createClaudeOwnComposerTextLog({ limit: 2 });
    log.record('one');
    log.record('two');
    log.record('three');
    expect(log.matches('one')).toBe(false);
    expect(log.matches('two')).toBe(true);
    expect(log.matches('three')).toBe(true);
  });
});

describe('createClaudeOwnComposerTextLog — soft-wrapped drafts (C11 live, runner pid 20327)', () => {
  it('matches a recorded single-line text whose draft rendering soft-wrapped across lines', () => {
    const log = createClaudeOwnComposerTextLog();
    log.record('QA-C11 M1: reply with exactly the word ALPHA and nothing else');
    expect(log.matches('QA-C11 M1: reply with exactly the word ALPHA\nand nothing else')).toBe(true);
  });

  it('still never matches a wrapped draft whose words differ from any recorded text', () => {
    const log = createClaudeOwnComposerTextLog();
    log.record('QA-C11 M1: reply with exactly the word ALPHA and nothing else');
    expect(log.matches('QA-C11 M1: reply with exactly the word ALPHA\nand nothing more')).toBe(false);
    expect(log.matches('QA-C11 M1: reply with exactly the word ALPHA')).toBe(false);
  });
});
