import type { ApiSessionClient } from '@/api/session/sessionClient';
import { getSessionNotificationTitle } from '@/agent/runtime/readyNotificationContext';
import { resolveReadyNotificationAssistantText } from '@/agent/runtime/readyNotificationAssistantText';
import type { ReadyNotificationTurnContext } from '@/agent/runtime/runPermissionModePromptLoop';
import { sendReadyWithPushNotification } from '@/agent/runtime/sendReadyWithPushNotification';
import type { TurnAssistantPreviewTracker } from '@/agent/runtime/turnAssistantPreviewTracker';
import type { AccountSettings } from '@happier-dev/protocol';

type ClaudeReadySession = Readonly<{
    sessionId: string;
    sendSessionEvent: (event: { type: 'ready' }) => void;
    getMetadataSnapshot?: () => unknown;
    getTurnAssistantTextSnapshot?: ApiSessionClient['getTurnAssistantTextSnapshot'];
}>;

type ClaudeReadyPushSender = Readonly<{
    sendToAllDevices: (title: string, body: string, opts: { sessionId: string }) => void;
}>;

export function createClaudeReadyHandler(params: Readonly<{
    session: ClaudeReadySession;
    pushSender: ClaudeReadyPushSender | null;
    waitingForCommandLabel: string;
    logPrefix: string;
    assistantPreviewTracker?: Pick<TurnAssistantPreviewTracker, 'getPreview'>;
    getPending: () => unknown;
    getQueueSize: () => number;
    /**
     * True when the canonical pending queue holds only blocked (undeliverable) rows. Such rows can
     * never advance the session, so they must not suppress the completed-turn ready event + push
     * A blocked row cannot suppress the notification forever.
     * Optional so non-pending-aware callers keep the raw queue-size guard.
     */
    hasOnlyBlockedPendingWork?: () => boolean;
    includeAssistantPreviewText?: boolean;
    shouldSendPush?: () => boolean;
    accountSettings?: AccountSettings | null;
    settingsSecretsReadKeys?: readonly Uint8Array[];
}>): (context?: ReadyNotificationTurnContext) => void {
    return (context?: ReadyNotificationTurnContext) => {
        if (params.getPending()) return;
        // Suppress ready only while genuinely-deliverable queued work remains. A non-empty local
        // queue whose canonical pending rows are all blocked cannot advance the session, so the
        // completed turn must still notify rather than sit online/idle forever.
        if (params.getQueueSize() !== 0 && params.hasOnlyBlockedPendingWork?.() !== true) return;
        sendReadyWithPushNotification({
            turnKey: context?.turnToken ?? null,
            session: params.session,
            pushSender: params.pushSender,
            waitingForCommandLabel: params.waitingForCommandLabel,
            logPrefix: params.logPrefix,
            sessionTitle: getSessionNotificationTitle(
                typeof params.session.getMetadataSnapshot === 'function'
                    ? () => params.session.getMetadataSnapshot?.()
                    : null,
            ),
            assistantPreviewText: resolveReadyNotificationAssistantText({
                includeMessageText: params.includeAssistantPreviewText,
                explicitAssistantText: params.assistantPreviewTracker?.getPreview() ?? null,
                session: params.session,
                turnToken: context?.turnToken ?? null,
                startSeqExclusive: context?.startSeqExclusive ?? null,
            }),
            accountSettings: params.accountSettings ?? null,
            settingsSecretsReadKeys: params.settingsSecretsReadKeys,
            includeAssistantPreviewText: params.includeAssistantPreviewText,
            shouldSendPush: params.shouldSendPush,
        });
    };
}
