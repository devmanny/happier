import { isChildSessionNoticeText } from '@/session/lineage/childSessionNotice';

export type TurnInputKindTracker = Readonly<{
  /** Called once per user input handed to the provider. */
  recordDispatchedUserInput: (text: string) => void;
  /** Freezes the tally for the turn that starts now and resets it for the next one. */
  beginTurn: (turnToken: string) => void;
  /** True when the active turn was started only by automatic Happier notices. */
  isAutomaticNoticeOnly: (turnToken: string | null | undefined) => boolean;
}>;

/**
 * Tells a turn that a human (or any ordinary caller) started from one that only reacts
 * to automatic child/nesting notices. The latter must not wake the user's devices: the
 * parent agent is processing machine traffic, not answering a person.
 */
export function createTurnInputKindTracker(): TurnInputKindTracker {
  let total = 0;
  let automatic = 0;
  let active: Readonly<{ turnToken: string; automaticOnly: boolean }> | null = null;

  return {
    recordDispatchedUserInput(text) {
      total += 1;
      if (isChildSessionNoticeText(text)) automatic += 1;
    },
    beginTurn(turnToken) {
      active = { turnToken, automaticOnly: total > 0 && automatic === total };
      total = 0;
      automatic = 0;
    },
    isAutomaticNoticeOnly(turnToken) {
      if (!turnToken || !active || active.turnToken !== turnToken) return false;
      return active.automaticOnly;
    },
  };
}
