import type { TerminalPromptSubmitVerificationPolicy } from '@/integrations/terminalHost/promptSubmitVerification';
import { isExactClaudePastedTextMarker } from './claudePastedTextMarker';
import { isClaudeUnifiedComposerTextMatch } from './promptIdentity';
import {
  classifyClaudeOwnComposerDraft,
  type ClaudeOwnComposerDraftClassification,
} from './ownComposerDraftClassification';
import { parseClaudeScreenState, type ClaudeScreenState } from './tuiControls/screenState';

function normalizeNewlines(value: string): string {
  return value.replace(/\r\n?/g, '\n');
}

function isCollapsedPastedTextComposer(composerContent: string | null): boolean {
  return composerContent !== null
    && isExactClaudePastedTextMarker(composerContent);
}

function shouldVerifyAfterSubmit(promptText: string): boolean {
  return normalizeNewlines(promptText).trim().length > 0;
}

/**
 * What the verifier last saw instead of (or as) the prompt, for the stall-budget warning: a kind,
 * never screen or prompt text. Claude's composer may stay empty, sit behind a selector (Rewind),
 * hold other text, or show a generating turn while the paste never paints.
 */
export type ClaudePromptStagingObservationKind =
  | 'prompt_visible'
  | 'empty'
  | 'generating'
  | 'selection'
  | 'non_input'
  | 'foreign'
  | 'capture_style_unavailable'
  | 'provider_unavailable';

export type ClaudePromptStagingObservations = Readonly<{
  /** Forget the previous write's observation before a new write starts. */
  reset(): void;
  readLastKind(): ClaudePromptStagingObservationKind | null;
}>;

export type ClaudePromptSubmitVerificationPolicy = TerminalPromptSubmitVerificationPolicy & Readonly<{
  stagingObservations: ClaudePromptStagingObservations;
}>;

function resolveObservationKind(
  state: ClaudeScreenState,
  classification: ClaudeOwnComposerDraftClassification,
): ClaudePromptStagingObservationKind {
  switch (classification) {
    case 'own':
      return 'prompt_visible';
    case 'empty':
      return state.generating ? 'generating' : 'empty';
    case 'non_input_state':
      return state.selectionListVisible ? 'selection' : 'non_input';
    case 'generating':
      return 'generating';
    case 'foreign':
    case 'capture_style_unavailable':
    case 'provider_unavailable':
      return classification;
  }
}

function isPromptInComposer(params: Readonly<{
  promptText: string;
  screenText: string;
  /** Present only while staging (before Enter): records what the composer showed. */
  observeStaging?: ((kind: ClaudePromptStagingObservationKind) => void) | undefined;
}>): boolean {
  const state = parseClaudeScreenState(params.screenText);
  const matches = (composerText: string) => isCollapsedPastedTextComposer(composerText)
    || isClaudeUnifiedComposerTextMatch({
      promptText: params.promptText,
      composerText,
      // During this authorized paste, Claude may expose fewer than 256 characters
      // in a small viewport (observed with 2.1.280). Historical draft ownership
      // keeps its stronger threshold; submission must not depend on window size.
      allowShortVisibleWindow: true,
    });
  // A prompt that starts with `!` flips Claude into bash mode on paste and shows up on the bash-mode
  // prompt line, which is not a message composer and so never appears in `composerContent`.
  if ((state.composerContent !== null && matches(state.composerContent))
    || (params.promptText.startsWith('!')
      && state.shellComposerContent !== null
      && matches(state.shellComposerContent))) {
    params.observeStaging?.('prompt_visible');
    return true;
  }
  if (!params.observeStaging) return false;
  const classification = classifyClaudeOwnComposerDraft({
    screen: state,
    rawText: params.screenText,
    ownComposerTexts: { matches },
    stopOnGenerating: false,
  });
  params.observeStaging(resolveObservationKind(state, classification));
  if (classification === 'foreign') {
    throw new Error('Claude composer changed before prompt submission');
  }
  return false;
}

export function createClaudePromptSubmitVerificationPolicy(): ClaudePromptSubmitVerificationPolicy {
  let lastKind: ClaudePromptStagingObservationKind | null = null;
  const observeStaging = (kind: ClaudePromptStagingObservationKind): void => {
    lastKind = kind;
  };
  return {
    shouldVerifyAfterSubmit,
    isPromptStagedBeforeSubmit: (params) => isPromptInComposer({ ...params, observeStaging }),
    isPromptStillPendingAfterSubmit: isPromptInComposer,
    stagingObservations: {
      reset: () => {
        lastKind = null;
      },
      readLastKind: () => lastKind,
    },
  };
}
