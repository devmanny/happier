import { describeTaskDue, taskDueNotices } from '@happier-dev/protocol';

import type { AgentTaskStore } from '@/session/agentTasks/agentTaskStore';
import { logger } from '@/ui/logger';

type TaskDuePushSender = Readonly<{
  sendToAllDevicesAsync: (title: string, body: string, data?: Record<string, unknown>) => Promise<void>;
}>;

/**
 * How often the daemon looks for the user's tasks that became due soon or overdue. Due dates are
 * set to the minute and "due soon" is a day ahead, so a few minutes of delay is invisible.
 */
export const TASK_DUE_CHECK_INTERVAL_MS = 5 * 60_000;

/**
 * Tell the user about each of their open tasks once when it is due within a day and once when it
 * is overdue. The task records the notice (a versioned write) before the push goes out, so when
 * several machines check at once only the one whose write lands sends it.
 */
export async function runTaskDueCheck(params: Readonly<{
  store: AgentTaskStore;
  push: TaskDuePushSender;
  pushEnabled: () => boolean;
  now?: () => number;
}>): Promise<void> {
  if (!params.pushEnabled()) return;
  const now = params.now?.() ?? Date.now();
  const { tasks } = await params.store.list();
  for (const notice of taskDueNotices({ tasks, now })) {
    let claimed = false;
    const task = await params.store.update(notice.taskId, (current, at) => {
      const already = notice.kind === 'overdue' ? current.notifiedV1?.overdueAt : current.notifiedV1?.dueSoonAt;
      if (already !== undefined) {
        claimed = false;
        return current;
      }
      claimed = true;
      return {
        ...current,
        notifiedV1: { ...current.notifiedV1, ...(notice.kind === 'overdue' ? { overdueAt: at } : { dueSoonAt: at }) },
      };
    });
    if (!task || !claimed) continue;
    const due = describeTaskDue(task, now);
    await params.push.sendToAllDevicesAsync(
      notice.kind === 'overdue' ? 'Task overdue' : 'Task due soon',
      due ? `${task.title} — ${due}` : task.title,
      { type: 'task_due', taskId: task.id },
    );
  }
}

/** Runs the check now and then every `TASK_DUE_CHECK_INTERVAL_MS` until stopped. */
export function startTaskDueNotifier(params: Parameters<typeof runTaskDueCheck>[0]): Readonly<{ stop: () => void }> {
  let running = false;
  const tick = () => {
    if (running) return;
    running = true;
    void runTaskDueCheck(params)
      .catch((error: unknown) => {
        logger.warn('[DAEMON RUN] Task due check failed (non-fatal)', { error: error instanceof Error ? error.message : String(error) });
      })
      .finally(() => { running = false; });
  };
  tick();
  const timer = setInterval(tick, TASK_DUE_CHECK_INTERVAL_MS);
  timer.unref?.();
  return { stop: () => clearInterval(timer) };
}
