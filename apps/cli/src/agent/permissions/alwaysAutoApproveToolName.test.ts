import { describe, expect, it } from 'vitest';

import { isTrustedAlwaysAutoApproveToolName } from './alwaysAutoApproveToolName';

describe('isTrustedAlwaysAutoApproveToolName', () => {
  it('auto-approves the integrated browser tools under every Happier MCP prefix', () => {
    for (const name of ['mcp__happier__browser_click', 'happier__browser_navigate', 'happier_browser_screenshot']) {
      expect(isTrustedAlwaysAutoApproveToolName(name), name).toBe(true);
    }
  });

  it('does not auto-approve look-alike tools from other servers', () => {
    for (const name of ['browser_click', 'mcp__playwright__browser_click', 'mcp__other__browser_click', 'mcp__happier__browser_delete_everything', 'Bash']) {
      expect(isTrustedAlwaysAutoApproveToolName(name), name).toBe(false);
    }
  });
});
