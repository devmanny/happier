import { describe, expect, it } from 'vitest';

import { resolveSessionProtocolCapabilitiesFeature } from './sessionProtocolCapabilitiesFeature';

describe('session protocol capability payload', () => {
    it('advertises Runtime Activity and Pending-input independently', () => {
        expect(resolveSessionProtocolCapabilitiesFeature()).toEqual({
            capabilities: {
                session: {
                    runtimeActivity: { protocolVersion: 2 },
                    // v3: a provider-proven undelivered row can return to its place in line.
                    pendingInput: { protocolVersion: 3 },
                },
            },
        });
    });
});
