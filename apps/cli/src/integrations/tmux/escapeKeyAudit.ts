import { logger } from '@/ui/logger';

/**
 * Every Escape Happier sends to a provider pane is logged with its callers. Claude Code 2.1.326
 * silently cancels a turn when Escape arrives just after Enter and puts the prompt back in the
 * composer (incident cmwyimjvw4buyqh01nx3pp1oh, 27 Nov 2026: a prompt accepted at 01:49:41Z was
 * cancelled and waited 37 s for a manual Enter, with no Happier log naming the sender).
 */
export function auditTmuxEscapeKeySent(path: 'special_key' | 'interrupt_turn'): void {
  const callers = (new Error().stack ?? '')
    .split('\n')
    .slice(1)
    .map((line) => line.trim().replace(/^at\s+/, ''))
    .filter((line) => line.length > 0 && !line.includes('escapeKeyAudit') && !line.includes('node:internal'))
    .slice(1, 7)
    .map((line) => line.replace(/\(?(?:file:\/\/)?\/[^()]*\/(src|dist)\//, '($1/'));
  logger.infoFile('[tmux] Escape sent to the provider pane', { path, callers });
}
