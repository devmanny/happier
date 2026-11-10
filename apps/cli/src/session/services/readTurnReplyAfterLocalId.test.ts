import { describe, expect, it } from 'vitest';

import { readTurnReplyFromRows } from './readTurnReplyAfterLocalId';

const ctx = { encryptionKey: new Uint8Array([1]), encryptionVariant: 'legacy' as const };
let seq = 10;
const row = (v: unknown) => ({ seq: ++seq, createdAt: seq, content: { t: 'plain' as const, v } });
const assistant = (text: string) => row({ role: 'assistant', content: { type: 'text', text }, meta: {} });
const user = (text: string) => row({ role: 'user', content: { type: 'text', text }, meta: {} });
const completed = () => row({ role: 'agent', content: { type: 'acp', data: { type: 'task_complete', id: 'turn-1' } } });
const failed = () => row({ role: 'agent', content: { type: 'acp', data: { type: 'turn_failed', id: 'turn-1' } } });

describe('readTurnReplyFromRows', () => {
  it('is the turn\'s final assistant message, finished once the turn completes', () => {
    expect(readTurnReplyFromRows({ rows: [assistant('Reviso…'), assistant('Listo: @Tomás revisa'), completed()], ctx }))
      .toEqual({ finished: true, text: 'Listo: @Tomás revisa' });
    expect(readTurnReplyFromRows({ rows: [assistant('Reviso…')], ctx })).toEqual({ finished: false, text: 'Reviso…' });
    expect(readTurnReplyFromRows({ rows: [failed()], ctx })).toEqual({ finished: true, text: null });
  });

  it('ends at the next user message: what comes after belongs to another turn', () => {
    expect(readTurnReplyFromRows({ rows: [assistant('Primero'), completed(), user('otra cosa'), assistant('Otra respuesta')], ctx }))
      .toEqual({ finished: true, text: 'Primero' });
  });
});
