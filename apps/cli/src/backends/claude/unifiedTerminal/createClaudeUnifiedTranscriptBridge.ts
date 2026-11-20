import { createSessionScanner, type SessionScanner } from '../utils/sessionScanner';
import type { ClaudeRemoteSubagentFileCollector } from '../remote/sidechains/claudeRemoteSubagentFileCollector';
import type { CommittedClaudeJsonlMessageBaseline } from '../utils/claudeJsonlMessageKey';
import type { RawJSONLines } from '../types';
import { readClaudeTranscriptTurnSignal } from '../localControl/readClaudeTranscriptTurnSignal';
import { isSidechainSessionHook } from '../utils/sessionHookAttribution';
import { open } from 'node:fs/promises';
import { join } from 'node:path';
import { logger } from '@/ui/logger';
import { getProjectPath } from '../utils/path';
import { loadClaudeJsonlReplayBaseline } from '../utils/loadClaudeJsonlReplayBaseline';
import type { SessionHookData } from '../utils/startHookServer';
import type { ClaudeUnifiedSessionHookSubscription } from './createClaudeUnifiedHookLifecycleBridge';
import type { ClaudeUnifiedStartableDisposable } from './_types';
import type { ClaudeWorkflowActivityObservationContext } from '../workflows/claudeWorkflowActivitySource';
import { readClaudeTaskLifecycleEnvelope } from '../taskNotifications/claudeTaskLifecycleEnvelope';
import { readClaudeJsonlTimestampMs } from '../utils/claudeJsonlTimestamp';

type ClaudeUnifiedTranscriptBridgeSessionFound = (sessionId: string, data: SessionHookData) => void;

function readHookEventName(data: SessionHookData): string {
  const raw = data.hook_event_name ?? data.hookEventName ?? data.eventName;
  return typeof raw === 'string' ? raw : '';
}

function readHookString(data: SessionHookData, snakeKey: string, camelKey: string): string | null {
  const raw = (data as Record<string, unknown>)[snakeKey] ?? (data as Record<string, unknown>)[camelKey];
  return typeof raw === 'string' && raw.trim().length > 0 ? raw.trim() : null;
}

type ClaudeUnifiedHookTranscriptInfo = Readonly<{
  sessionId: string;
  transcriptPath: string | null;
}>;

function readHookTranscriptInfo(data: SessionHookData): ClaudeUnifiedHookTranscriptInfo | null {
  const sessionId = readHookString(data, 'session_id', 'sessionId');
  if (!sessionId) return null;
  return {
    sessionId,
    transcriptPath: readHookString(data, 'transcript_path', 'transcriptPath'),
  };
}

function readSessionStartInfo(data: SessionHookData): Readonly<ClaudeUnifiedHookTranscriptInfo & {
  source: string | null;
}> | null {
  if (readHookEventName(data) !== 'SessionStart') return null;
  const transcriptInfo = readHookTranscriptInfo(data);
  if (!transcriptInfo) return null;
  return {
    ...transcriptInfo,
    source: readHookString(data, 'source', 'source'),
  };
}

function readLaterHookTranscriptInfo(data: SessionHookData): Readonly<{
  sessionId: string;
  transcriptPath: string;
}> | null {
  const hookEventName = readHookEventName(data);
  if (!hookEventName || hookEventName === 'SessionStart') return null;
  const transcriptInfo = readHookTranscriptInfo(data);
  return transcriptInfo?.transcriptPath ? {
    sessionId: transcriptInfo.sessionId,
    transcriptPath: transcriptInfo.transcriptPath,
  } : null;
}

type ClaudeUnifiedSessionStartInfo = NonNullable<ReturnType<typeof readSessionStartInfo>>;

type PendingClaudeUnifiedSessionBinding = Readonly<{
  data: SessionHookData;
  sessionInfo: ClaudeUnifiedSessionStartInfo;
}>;

function disposeSubscription(dispose: (() => void) | null): void {
  if (!dispose) return;
  dispose();
}

function readTranscriptString(message: RawJSONLines, key: string): string | null {
  const raw = (message as Record<string, unknown>)[key];
  return typeof raw === 'string' && raw.trim().length > 0 ? raw.trim() : null;
}

function shouldForwardResumeTranscriptToLifecycle(
  message: RawJSONLines,
  resumeLiveTranscriptAfterMsBySessionId: ReadonlyMap<string, number>,
): boolean {
  const sessionId = readTranscriptString(message, 'sessionId');
  if (!sessionId) return true;
  const liveAfterMs = resumeLiveTranscriptAfterMsBySessionId.get(sessionId);
  if (liveAfterMs === undefined) return true;
  const timestampMs = readClaudeJsonlTimestampMs(message);
  if (timestampMs === null) return true;
  return timestampMs >= liveAfterMs;
}

function shouldForwardFreshResumeTranscriptToMessage(
  message: RawJSONLines,
  resumeLiveTranscriptAfterMsBySessionId: ReadonlyMap<string, number>,
): boolean {
  const sessionId = readTranscriptString(message, 'sessionId');
  if (!sessionId) return true;
  const liveAfterMs = resumeLiveTranscriptAfterMsBySessionId.get(sessionId);
  if (liveAfterMs === undefined) return true;
  const timestampMs = readClaudeJsonlTimestampMs(message);
  if (timestampMs === null) return false;
  return timestampMs >= liveAfterMs;
}

function isFailedTurnTerminalTranscript(message: RawJSONLines): boolean {
  const signal = readClaudeTranscriptTurnSignal(message);
  return signal?.type === 'turn_terminal' && signal.reason === 'failed';
}

function shouldSuppressPriorEraFailedTurnVisibleReplay(
  message: RawJSONLines,
  lifecycleOwnedByCurrentRunner: boolean,
): boolean {
  return !lifecycleOwnedByCurrentRunner && isFailedTurnTerminalTranscript(message);
}

function isFreshHookDrivenSession(opts: Readonly<{
  sessionId: string | null;
  transcriptPath?: string | null | undefined;
}>): boolean {
  const transcriptPath = typeof opts.transcriptPath === 'string' && opts.transcriptPath.trim().length > 0
    ? opts.transcriptPath.trim()
    : null;
  return opts.sessionId === null && !transcriptPath;
}

function readKnownResumeTranscriptPath(opts: Readonly<{
  sessionId: string | null;
  transcriptPath?: string | null | undefined;
  workingDirectory: string;
  claudeConfigDir?: string | null | undefined;
}>): Readonly<{ path: string; source: 'explicit' | 'canonical' }> | null {
  const explicitTranscriptPath =
    typeof opts.transcriptPath === 'string' && opts.transcriptPath.trim().length > 0
      ? opts.transcriptPath.trim()
      : null;
  if (explicitTranscriptPath) {
    return { path: explicitTranscriptPath, source: 'explicit' };
  }
  const sessionId =
    typeof opts.sessionId === 'string' && opts.sessionId.trim().length > 0
      ? opts.sessionId.trim()
      : null;
  if (!sessionId) return null;
  return {
    path: join(getProjectPath(opts.workingDirectory, opts.claudeConfigDir ?? null), `${sessionId}.jsonl`),
    source: 'canonical',
  };
}

const COMPLETE_LINE_BOUNDARY_READ_CHUNK_BYTES = 64 * 1024;

/**
 * Byte offset just past the last complete JSONL line. A line Claude is still writing belongs to the
 * live follower: a boundary inside it would split the row so that neither the startup snapshot nor
 * the follower could read it. Missing or unreadable files start at 0.
 */
async function readCompleteJsonlLineBoundaryBytes(filePath: string): Promise<number> {
  let file: Awaited<ReturnType<typeof open>> | null = null;
  try {
    file = await open(filePath, 'r');
    let end = (await file.stat()).size;
    const buffer = Buffer.alloc(COMPLETE_LINE_BOUNDARY_READ_CHUNK_BYTES);
    while (end > 0) {
      const start = Math.max(0, end - buffer.length);
      const { bytesRead } = await file.read(buffer, 0, end - start, start);
      const newlineIndex = buffer.subarray(0, bytesRead).lastIndexOf(0x0a);
      if (newlineIndex >= 0) return start + newlineIndex + 1;
      end = start;
    }
    return 0;
  } catch {
    return 0;
  } finally {
    await file?.close().catch(() => {});
  }
}

export function createClaudeUnifiedTranscriptBridge(opts: Readonly<{
  sessionId: string | null;
  transcriptPath?: string | null | undefined;
  workingDirectory: string;
  claudeConfigDir?: string | null | undefined;
  onMessage?: ((message: RawJSONLines) => void | Promise<void>) | undefined;
  onHistoricalMessage?: ((message: RawJSONLines) => void | Promise<void>) | undefined;
  onTranscriptMessage?: ((message: RawJSONLines) => void) | undefined;
  onRawTranscriptValue?: ((
    value: unknown,
    observation: ClaudeWorkflowActivityObservationContext,
  ) => void) | undefined;
  onLiveProviderTaskJsonlValue?: ((input: Readonly<{
    sessionId: string;
    value: unknown;
  }>) => void) | undefined;
  onLiveProviderTaskObservationLost?: ((input: Readonly<{
    sessionId: string;
    reason: string;
  }>) => void) | undefined;
  /**
   * Observes every live trusted row of the primary Claude session so an exact Pending prompt can be
   * accepted from the transcript (rows such as native queued commands reach only this raw channel).
   */
  proveAcceptedMainTranscript?: ((value: unknown) => boolean) | undefined;
  /**
   * Called for every live trusted row of the primary Claude session, and once after the startup
   * snapshot of the trusted session has been read. A reported id is published only once its
   * transcript proves it, and SessionStart precedes the file Claude creates at the first prompt;
   * the identity owner re-runs that proof here while the id is still pending.
   */
  onTrustedMainTranscriptRow?: ((sessionId: string) => void) | undefined;
  /**
   * Publishes the scanner's ONE sidechain importer for as long as that scanner is alive, and `null`
   * once it is gone. The bridge builds the scanner lazily (after the SessionStart subscription and
   * the replay baseline), so a launcher cannot hold the importer up front; it subscribes instead.
   * The `null` on teardown is load-bearing — a registration accepted after cleanup would attach a
   * follower nothing will stop, and would claim a transcript that is no longer being imported.
   */
  onSubagentFileCollectorChanged?: ((
    collector: ClaudeRemoteSubagentFileCollector | null,
  ) => void) | undefined;
  onSessionFound?: ClaudeUnifiedTranscriptBridgeSessionFound | undefined;
  validateSessionStart?: ((info: Readonly<{
    sessionId: string;
    transcriptPath: string | null;
    source: string | null;
  }>) => boolean) | undefined;
  onTranscriptMissing?: ((info: { sessionId: string; filePath: string }) => void) | undefined;
  transcriptMissingWarningMs?: number | undefined;
  subscribeClaudeSessionHooks?: ClaudeUnifiedSessionHookSubscription | undefined;
  onStartupReplayComplete?: (() => void) | undefined;
  /**
   * Committed Claude JSONL dedupe baseline for resume replay (Lane N4). The baseline must be
   * loaded BEFORE the scanner replays initial rows; a load FAILURE fails closed (no
   * replay-as-new), and a partial coverage window suppresses replay of rows older than the
   * window (they cannot be proven uncommitted).
   */
  loadCommittedClaudeJsonlMessageBaseline?: (() =>
    | Promise<CommittedClaudeJsonlMessageBaseline>
    | CommittedClaudeJsonlMessageBaseline) | undefined;
  classifyDiscoveredSession?: ((params: {
    sessionId: string;
    filePath: string;
    messages: readonly RawJSONLines[];
  }) => 'ignore' | 'diagnostic' | 'main' | null | undefined) | undefined;
}>): ClaudeUnifiedStartableDisposable {
  let disposed = false;
  let scanner: Awaited<SessionScanner> | null = null;
  let unsubscribe: (() => void) | null = null;
  const resumeLiveTranscriptAfterMsBySessionId = new Map<string, number>();
  const freshResumeLiveMessageAfterMsBySessionId = new Map<string, number>();
  const pendingSessionBindings: PendingClaudeUnifiedSessionBinding[] = [];
  const promotedDiscoveredMainSessionIds = new Set<string>();
  const freshHookDrivenSession = isFreshHookDrivenSession(opts);
  const knownResumeSessionId =
    typeof opts.sessionId === 'string' && opts.sessionId.trim().length > 0
      ? opts.sessionId.trim()
      : null;
  const knownResumeTranscript = readKnownResumeTranscriptPath(opts);
  const knownResumeTranscriptPath = knownResumeTranscript?.path ?? null;
  let activeTrustedSessionBinding: Readonly<{
    data: SessionHookData;
    sessionInfo: ClaudeUnifiedSessionStartInfo;
  }> | null = null;

  const recordSessionStartBaselines = (
    sessionInfo: ClaudeUnifiedSessionStartInfo,
    receivedAtMs: number,
  ) => {
    if (sessionInfo.source !== 'resume') return;
    resumeLiveTranscriptAfterMsBySessionId.set(sessionInfo.sessionId, receivedAtMs);
    if (freshHookDrivenSession) {
      freshResumeLiveMessageAfterMsBySessionId.set(sessionInfo.sessionId, receivedAtMs);
    }
  };

  const applySessionBinding = (
    sessionInfo: ClaudeUnifiedSessionStartInfo,
    data: SessionHookData,
    sessionStartReceivedAtMs: number | null,
  ) => {
    if (disposed) return;
    activeTrustedSessionBinding = { data, sessionInfo };
    if (sessionStartReceivedAtMs !== null) {
      recordSessionStartBaselines(sessionInfo, sessionStartReceivedAtMs);
    }
    opts.onSessionFound?.(sessionInfo.sessionId, data);

    if (!scanner) {
      const pendingIndex = pendingSessionBindings.findIndex(
        (pending) => pending.sessionInfo.sessionId === sessionInfo.sessionId,
      );
      const pendingBinding = { data, sessionInfo };
      if (pendingIndex >= 0) pendingSessionBindings[pendingIndex] = pendingBinding;
      else pendingSessionBindings.push(pendingBinding);
      return;
    }

    scanner.onNewSession({
      sessionId: sessionInfo.sessionId,
      transcriptPath: sessionInfo.transcriptPath,
    });
  };

  const applyLaterHookTranscriptPath = (
    transcriptInfo: NonNullable<ReturnType<typeof readLaterHookTranscriptInfo>>,
    data: SessionHookData,
  ) => {
    if (disposed) return;
    const activeSessionStart = activeTrustedSessionBinding;
    if (
      !activeSessionStart
      || activeSessionStart.sessionInfo.sessionId !== transcriptInfo.sessionId
      || activeSessionStart.sessionInfo.transcriptPath === transcriptInfo.transcriptPath
    ) return;

    const updatedSessionInfo = {
      ...activeSessionStart.sessionInfo,
      transcriptPath: transcriptInfo.transcriptPath,
    };
    applySessionBinding(updatedSessionInfo, data, null);
  };

  const observeTrustedRawTranscriptValue = (
    value: unknown,
    observation: Readonly<{ historicalReplay: boolean }>,
  ): void => {
    opts.onRawTranscriptValue?.(value, observation);
    if (observation.historicalReplay) return;
    // The scanner serializes trusted raw observations behind preceding visible-message commits,
    // including a known resume whose adopted provider emits no new SessionStart. A real
    // SessionStart takes precedence over that initial requested identity.
    const trustedSessionId = activeTrustedSessionBinding?.sessionInfo.sessionId ?? knownResumeSessionId;
    const sessionId = readTranscriptString(value as RawJSONLines, 'sessionId');
    if (!sessionId) return;
    if (trustedSessionId ? sessionId !== trustedSessionId : !promotedDiscoveredMainSessionIds.has(sessionId)) return;
    // Acceptance proof is per exact Pending prompt and must keep observing every authenticated
    // primary-session raw row.
    opts.proveAcceptedMainTranscript?.(value);
    // Independent of acceptance: a UserPromptSubmit hook usually accepts the prompt before its row
    // lands, so identity publication must not wait for this row to match a Pending prompt.
    opts.onTrustedMainTranscriptRow?.(sessionId);
  };

  const observeLiveProviderTaskJsonlValue = (
    input: Readonly<{ sessionId: string; value: unknown }>,
  ): void => {
    const row = input.value && typeof input.value === 'object' && !Array.isArray(input.value)
      ? input.value as Readonly<Record<string, unknown>>
      : null;
    const rawSessionId = row?.session_id ?? row?.sessionId;
    const rowSessionId = typeof rawSessionId === 'string' ? rawSessionId.trim() : '';
    if (!rowSessionId || rowSessionId !== input.sessionId) return;
    opts.onLiveProviderTaskJsonlValue?.(input);
  };

  const flushPendingSessionBindings = () => {
    if (!scanner) return;
    for (const pending of pendingSessionBindings.splice(0)) {
      scanner.onNewSession({
        sessionId: pending.sessionInfo.sessionId,
        transcriptPath: pending.sessionInfo.transcriptPath,
      });
    }
  };

  return {
    async start() {
      if (disposed || scanner) return;
      const startedAtMs = Date.now();
      const waitForSessionStartHook = Boolean(opts.subscribeClaudeSessionHooks);
      if (opts.subscribeClaudeSessionHooks && !unsubscribe) {
        logger.debug('[unified]: Claude SessionStart hook subscription registered', {
          knownResumeSessionId,
          knownResumeTranscriptPath,
          knownResumeTranscriptPathSource: knownResumeTranscript?.source ?? 'none',
        });
        unsubscribe = opts.subscribeClaudeSessionHooks((data, observation) => {
          const trustedSessionId = activeTrustedSessionBinding?.sessionInfo.sessionId ?? knownResumeSessionId;
          const hookSessionId = readHookString(data, 'session_id', 'sessionId');
          const task = readClaudeTaskLifecycleEnvelope(data);
          if ((task?.subtype === 'agent-resume' || task?.subtype === 'async-launch')
            && trustedSessionId && hookSessionId === trustedSessionId) {
            opts.onRawTranscriptValue?.(data, {
              historicalReplay: false, authenticatedHook: true,
              ...(observation?.observedAt !== undefined ? { observedAt: observation.observedAt } : {}),
              ...(observation?.startupReplay ? { startupReplay: true } : {}),
            });
          }
          // A4-MED-2: a subagent (sidechain) SessionStart must never re-key the transcript /
          // resume identity — same shared gate the hook lifecycle bridge uses.
          if (isSidechainSessionHook(data)) {
            if (readHookEventName(data) === 'SessionStart') {
              logger.debug('[unified]: ignoring sidechain Claude SessionStart hook');
            }
            return;
          }
          const sessionInfo = readSessionStartInfo(data);
          if (!sessionInfo && readHookEventName(data) === 'SessionStart') {
            logger.debug('[unified]: ignoring malformed Claude SessionStart hook', {
              hasSessionId: Boolean(readHookString(data, 'session_id', 'sessionId')),
              hasTranscriptPath: Boolean(readHookString(data, 'transcript_path', 'transcriptPath')),
            });
          }
          if (!sessionInfo) {
            const transcriptInfo = readLaterHookTranscriptInfo(data);
            if (transcriptInfo) applyLaterHookTranscriptPath(transcriptInfo, data);
            return;
          }
          logger.debug('[unified]: Claude SessionStart hook received', {
            sessionId: sessionInfo.sessionId,
            hasTranscriptPath: Boolean(sessionInfo.transcriptPath),
            source: sessionInfo.source,
            knownResumeSessionId,
          });
          if (opts.validateSessionStart?.(sessionInfo) === false) return;
          applySessionBinding(sessionInfo, data, Date.now());
        }) ?? null;
      }
      let committedClaudeJsonlMessageKeys: ReadonlySet<string> = new Set<string>();
      let replaySuppressRowsBeforeMs: number | null = null;
      const resumesKnownClaudeSession = Boolean(opts.sessionId || opts.transcriptPath);
      // Capture the live boundary before baseline loading: Claude can append queued-command
      // evidence while the durable replay baseline is in flight. The scanner owns both paths.
      const initialLiveTranscriptStartOffsetBytes = waitForSessionStartHook && knownResumeTranscriptPath
        ? await readCompleteJsonlLineBoundaryBytes(knownResumeTranscriptPath)
        : undefined;
      if (waitForSessionStartHook) {
        const baseline = await loadClaudeJsonlReplayBaseline({
          loadCommittedBaseline: opts.loadCommittedClaudeJsonlMessageBaseline,
          resumesKnownClaudeSession,
          logPrefix: '[unified]',
        });
        committedClaudeJsonlMessageKeys = baseline.initialProcessedMessageKeys;
        replaySuppressRowsBeforeMs = baseline.replaySuppressRowsBeforeMs;
      }
      if (disposed) {
        pendingSessionBindings.length = 0;
        return;
      }
      const prebindKnownResumeTranscript = Boolean(
        waitForSessionStartHook
        && knownResumeSessionId
        && knownResumeTranscriptPath,
      );
      // An adopted terminal may not emit another SessionStart. Seed the same resume-era cutoff
      // before snapshot replay so old lifecycle rows cannot become current-runner activity.
      if (
        prebindKnownResumeTranscript
        && knownResumeSessionId
        && !resumeLiveTranscriptAfterMsBySessionId.has(knownResumeSessionId)
      ) {
        resumeLiveTranscriptAfterMsBySessionId.set(knownResumeSessionId, startedAtMs);
      }
      const initialBinding = activeTrustedSessionBinding?.sessionInfo;
      const initialSessionId = waitForSessionStartHook
        ? (initialBinding?.sessionId ?? (prebindKnownResumeTranscript ? knownResumeSessionId : null))
        : opts.sessionId;
      const initialTranscriptPath = waitForSessionStartHook
        ? (initialBinding ? initialBinding.transcriptPath : (prebindKnownResumeTranscript ? knownResumeTranscriptPath : null))
        : opts.transcriptPath;
      const nextScanner = await createSessionScanner({
        sessionId: initialSessionId,
        transcriptPath: initialTranscriptPath,
        initialLiveTranscriptStartOffsetBytes: initialSessionId === knownResumeSessionId
          && initialTranscriptPath === knownResumeTranscriptPath
          ? initialLiveTranscriptStartOffsetBytes
          : undefined,
        claudeConfigDir: opts.claudeConfigDir,
        workingDirectory: opts.workingDirectory,
        onMessage: async (message, observation) => {
          const lifecycleOwnedByCurrentRunner = shouldForwardResumeTranscriptToLifecycle(
            message,
            resumeLiveTranscriptAfterMsBySessionId,
          );
          if (
            shouldForwardFreshResumeTranscriptToMessage(message, freshResumeLiveMessageAfterMsBySessionId)
            && !shouldSuppressPriorEraFailedTurnVisibleReplay(message, lifecycleOwnedByCurrentRunner)
          ) {
            const handler = observation?.historicalReplay === true
              ? (opts.onHistoricalMessage ?? opts.onMessage)
              : opts.onMessage;
            await handler?.(message);
          }
          if (lifecycleOwnedByCurrentRunner) {
            opts.onTranscriptMessage?.(message);
          }
        },
        onRawJsonlValue: opts.onRawTranscriptValue || opts.proveAcceptedMainTranscript || opts.onTrustedMainTranscriptRow
          ? observeTrustedRawTranscriptValue
          : undefined,
        onLiveJsonlValue: opts.onLiveProviderTaskJsonlValue
          ? observeLiveProviderTaskJsonlValue
          : undefined,
        onLiveJsonlObservationLost: opts.onLiveProviderTaskObservationLost,
        onTranscriptMissing: opts.onTranscriptMissing,
        transcriptMissingWarningMs: opts.transcriptMissingWarningMs,
        initialProcessedMessageKeys: committedClaudeJsonlMessageKeys,
        replayInitialMessages: waitForSessionStartHook,
        replaySuppressRowsBeforeMs,
        discoverNewSessions: waitForSessionStartHook && !knownResumeSessionId && !opts.transcriptPath,
        bindToFirstSession: waitForSessionStartHook,
        bindDiscoveredSessions: !waitForSessionStartHook,
        classifyDiscoveredSession: opts.classifyDiscoveredSession,
        onDiscoveredMainSession: (params) => {
          if (promotedDiscoveredMainSessionIds.has(params.sessionId)) return;
          promotedDiscoveredMainSessionIds.add(params.sessionId);
          // Exact accepted-prompt transcript matching is the hookless identity fallback for a
          // terminal session whose SessionStart hook never activated. Promotion occurs only
          // after the scanner confirms this candidate won binding, so a simultaneous trusted
          // SessionStart cannot be overwritten by discovery.
          opts.onSessionFound?.(params.sessionId, {
            session_id: params.sessionId,
            transcript_path: params.filePath,
            cwd: opts.workingDirectory,
            source: 'transcript_discovery',
          });
        },
      });
      if (disposed) {
        pendingSessionBindings.length = 0;
        await nextScanner.cleanup();
        return;
      }
      scanner = nextScanner;
      opts.onSubagentFileCollectorChanged?.(nextScanner.subagentFileCollector);
      flushPendingSessionBindings();
      // The startup snapshot replays rows as history, which never reach the live-row report. A
      // transcript that materialized while nobody followed it must still let a pending identity
      // proof run now instead of waiting for Claude's next row.
      const startupTrustedSessionId = activeTrustedSessionBinding?.sessionInfo.sessionId
        ?? (prebindKnownResumeTranscript ? knownResumeSessionId : null);
      if (startupTrustedSessionId) opts.onTrustedMainTranscriptRow?.(startupTrustedSessionId);
      opts.onStartupReplayComplete?.();
    },
    async dispose() {
      if (disposed) return;
      disposed = true;
      disposeSubscription(unsubscribe);
      unsubscribe = null;
      pendingSessionBindings.length = 0;
      promotedDiscoveredMainSessionIds.clear();
      activeTrustedSessionBinding = null;
      if (scanner) opts.onSubagentFileCollectorChanged?.(null);
      await scanner?.cleanup();
      scanner = null;
    },
  };
}
