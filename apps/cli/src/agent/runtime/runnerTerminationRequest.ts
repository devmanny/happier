import type { RunnerTerminationEvent } from './runnerTerminationOutcome';

type RunnerTerminationRequester = (event: RunnerTerminationEvent) => void;

let registeredRequester: RunnerTerminationRequester | null = null;
let pendingRequest: RunnerTerminationEvent | null = null;

/**
 * Asks this process's runner to terminate through its own termination path
 * (`registerRunnerTerminationHandlers`), for an owner that does not hold that registration: the
 * session client's Agent lifetime guard (`ApiSessionClient.bindRuntimeBackendTarget`). One runner
 * runs per process.
 *
 * A request made before the runner has registered its handlers waits and is honored at
 * registration, so the stop is always the graceful one (input fence, provider cleanup, session
 * death). A raw OS signal would not be: before registration a terminal-started Claude runner's
 * caffeinate listener swallows SIGTERM, and a runner without any listener dies without cleanup.
 */
export function requestRunnerTermination(event: RunnerTerminationEvent): void {
  if (registeredRequester) {
    registeredRequester(event);
    return;
  }
  pendingRequest ??= event;
}

/**
 * Registration seam owned by `registerRunnerTerminationHandlers`. A request that was waiting runs on
 * the next microtask, exactly like a signal arriving right after registration; the returned
 * function unregisters the requester.
 */
export function registerRunnerTerminationRequester(requester: RunnerTerminationRequester): () => void {
  registeredRequester = requester;
  const waiting = pendingRequest;
  pendingRequest = null;
  if (waiting) {
    queueMicrotask(() => {
      if (registeredRequester === requester) requester(waiting);
      else pendingRequest ??= waiting;
    });
  }
  return () => {
    if (registeredRequester === requester) registeredRequester = null;
  };
}
