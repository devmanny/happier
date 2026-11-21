/**
 * Which sessions the next deep-index pass reads: sessions with new activity first (the inventory
 * saw their latest seq move), then a fair rotation through the remaining sessions that still have
 * unread messages. Caught-up sessions cost no request.
 */
export function selectDeepIndexWork(params: Readonly<{
  candidateIds: readonly string[];
  startIndex: number;
  priorityIds: readonly string[];
  maxSessions: number;
  needsWork: (sessionId: string) => boolean;
}>): Readonly<{ sessionIds: string[]; consumedPriorityIds: string[]; nextStartIndex: number }> {
  const max = Math.max(1, Math.trunc(params.maxSessions));
  const selected: string[] = [];
  const consumedPriorityIds: string[] = [];

  for (const id of params.priorityIds) {
    if (selected.length >= max) break;
    consumedPriorityIds.push(id);
    if (!selected.includes(id) && params.needsWork(id)) selected.push(id);
  }

  const total = params.candidateIds.length;
  let index = total > 0 ? ((Math.trunc(params.startIndex) % total) + total) % total : 0;
  let nextStartIndex = index;
  for (let scanned = 0; scanned < total && selected.length < max; scanned += 1) {
    const id = params.candidateIds[index]!;
    index = (index + 1) % total;
    if (selected.includes(id) || !params.needsWork(id)) continue;
    selected.push(id);
    nextStartIndex = index;
  }

  return { sessionIds: selected, consumedPriorityIds, nextStartIndex };
}
