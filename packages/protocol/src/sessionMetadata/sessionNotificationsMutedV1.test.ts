import { describe, expect, it } from 'vitest';

import { isSessionNotificationsMuted } from './sessionNotificationsMutedV1.js';

describe('isSessionNotificationsMuted', () => {
  it('is muted only when the user turned the bell off', () => {
    expect(isSessionNotificationsMuted({ notificationsMutedV1: { v: 1, muted: true, updatedAt: 1 } })).toBe(true);
    expect(isSessionNotificationsMuted({ notificationsMutedV1: { v: 1, muted: false, updatedAt: 2 } })).toBe(false);
    expect(isSessionNotificationsMuted({})).toBe(false);
    expect(isSessionNotificationsMuted(null)).toBe(false);
    expect(isSessionNotificationsMuted({ notificationsMutedV1: 'yes' })).toBe(false);
  });
});
