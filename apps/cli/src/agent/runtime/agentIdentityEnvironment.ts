import { AGENT_IDENTITY_ENV_KEY, parseAgentIdentityV1, type AgentIdentityV1 } from '@happier-dev/protocol';

/**
 * The agent this runner works as, handed over by the daemon at spawn. The variable is left in
 * place so a respawned runner (whose environment is restored) keeps the same identity.
 */
export function readAgentIdentityFromEnvironment(env: NodeJS.ProcessEnv = process.env): AgentIdentityV1 | null {
    const raw = env[AGENT_IDENTITY_ENV_KEY];
    return typeof raw === 'string' && raw.trim().length > 0 ? parseAgentIdentityV1(raw) : null;
}
