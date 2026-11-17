import { describe, expect, it } from 'vitest';

import {
  resolveExistingSessionLaunchOptions,
  resolveSessionRuntimeBackendConflict,
} from './existingSessionBackendTargetAdmission';

const claude = { kind: 'builtInAgent', agentId: 'claude' } as const;
const codex = { kind: 'builtInAgent', agentId: 'codex' } as const;
const kiro = { kind: 'configuredAcpBackend', backendId: 'custom-kiro' } as const;
const kiroMetadata = {
  flavor: 'acp:custom-kiro',
  acpConfiguredBackendV1: { v: 1, updatedAt: 100, backendId: 'custom-kiro', title: 'Custom Kiro' },
};

describe('resolveSessionRuntimeBackendConflict', () => {
  it('names the Session\'s current Agent when a runtime is another one', () => {
    // Incident 2026-11-17: a Claude runtime served the Session after its switch to Codex.
    expect(resolveSessionRuntimeBackendConflict({ sessionMetadata: { flavor: 'codex' }, backendTarget: claude }))
      .toEqual(codex);
    expect(resolveSessionRuntimeBackendConflict({ sessionMetadata: kiroMetadata, backendTarget: codex }))
      .toEqual(kiro);
  });

  it.each([
    { name: 'the same Agent', sessionMetadata: { flavor: 'codex' }, backendTarget: codex },
    { name: 'the same configured backend', sessionMetadata: kiroMetadata, backendTarget: kiro },
    // Unknown on either side is not proof of another Agent.
    { name: 'an unknown runtime', sessionMetadata: { flavor: 'codex' }, backendTarget: undefined },
    { name: 'an unread Session', sessionMetadata: null, backendTarget: claude },
    { name: 'a Session that names no Agent', sessionMetadata: { path: '/tmp' }, backendTarget: claude },
  ])('admits $name', ({ sessionMetadata, backendTarget }) => {
    expect(resolveSessionRuntimeBackendConflict({ sessionMetadata, backendTarget })).toBeNull();
  });
});

describe('resolveExistingSessionLaunchOptions', () => {
  const codexSession = {
    path: '/repo', machineId: 'machine-1', flavor: 'codex', claudeSessionId: 'claude-1', codexSessionId: 'codex-1',
    modelOverrideV1: { v: 1, modelId: 'gpt-6.1-sol', updatedAt: 730 },
  };

  it('retargets a stale request to the Agent the Session names, keeping only its authority and prompt', () => {
    const resolution = resolveExistingSessionLaunchOptions({
      sessionId: 'sess-1',
      sessionMetadata: codexSession,
      options: {
        directory: '/repo', existingSessionId: 'sess-1', backendTarget: claude,
        resume: 'claude-1', modelId: 'claude-opus-5-5', modelUpdatedAt: 900,
        environmentVariables: { CLAUDE_CONFIG_DIR: '/stale' },
        executionAuthorization: { provenance: 'user_request', requestId: 'automation-run' },
        spawnNonce: 'nonce-1', initialTranscriptAfterSeq: 4,
      },
    });

    expect(resolution).toMatchObject({ type: 'launch', retargetedFrom: claude });
    if (resolution.type !== 'launch') throw new Error('expected a launch');
    expect(resolution.options).toMatchObject({
      backendTarget: codex, existingSessionId: 'sess-1', directory: '/repo', modelId: 'gpt-6.1-sol',
      executionAuthorization: { provenance: 'user_request', requestId: 'automation-run' },
      spawnNonce: 'nonce-1', initialTranscriptAfterSeq: 4,
    });
    expect(resolution.options.resume).not.toBe('claude-1');
    expect(resolution.options.environmentVariables?.CLAUDE_CONFIG_DIR).toBeUndefined();
  });

  it('runs a request that names no Agent as the Session\'s Agent, with the rest of the request', () => {
    const options = { directory: '/repo', existingSessionId: 'sess-1', modelId: 'gpt-6.1-sol' };
    expect(resolveExistingSessionLaunchOptions({ sessionId: 'sess-1', sessionMetadata: codexSession, options }))
      .toEqual({ type: 'launch', options: { ...options, backendTarget: codex }, retargetedFrom: null });
  });

  it.each([
    { name: 'the Session\'s own Agent', sessionMetadata: codexSession, options: { directory: '/repo', backendTarget: codex } },
    { name: 'a handoff identity replacement', sessionMetadata: codexSession, options: { directory: '/repo', backendTarget: claude, attachMetadataIdentityPolicy: 'replace_with_runtime_identity' as const } },
    { name: 'a Session that names no Agent', sessionMetadata: { path: '/repo' }, options: { directory: '/repo', backendTarget: claude } },
  ])('keeps the request for $name', ({ sessionMetadata, options }) => {
    const resolution = resolveExistingSessionLaunchOptions({ sessionId: 'sess-1', sessionMetadata, options });
    expect(resolution).toEqual({ type: 'launch', options, retargetedFrom: null });
  });

  it('retargets from the Session\'s persisted placement, however the stale request spells its directory', () => {
    // An automation stored `/private/tmp/repo` for a Session persisted at `/tmp/repo`: the same
    // place, spelled differently. A cold resume runs where the Session lives.
    const resolution = resolveExistingSessionLaunchOptions({
      sessionId: 'sess-1',
      sessionMetadata: { ...codexSession, path: '/tmp/repo' },
      options: { directory: '/private/tmp/repo', backendTarget: claude },
    });
    expect(resolution).toMatchObject({
      type: 'launch',
      retargetedFrom: claude,
      options: { backendTarget: codex, directory: '/tmp/repo', machineId: 'machine-1' },
    });
  });

  it('refuses a stale request for another machine as a placement mismatch, not an Agent conflict', () => {
    expect(resolveExistingSessionLaunchOptions({
      sessionId: 'sess-1',
      sessionMetadata: codexSession,
      options: { directory: '/repo', machineId: 'machine-2', backendTarget: claude },
    })).toEqual({ type: 'placement_mismatch', sessionBackendTarget: codex, backendTarget: claude });
  });
});
