import test from 'node:test';
import assert from 'node:assert/strict';
import { exportCurrentPage } from '../HappierSafari/Resources/cookie-export.mjs';

const tab = { id: 4, url: 'https://login.example.com/account?token=not-exported' };
function safari({ granted = true, changed = false, missingStore = false } = {}) {
    const calls = [];
    return { calls,
        permissions: { request: async (value) => { calls.push(['permission', value]); return granted; } },
        tabs: { get: async () => changed ? { ...tab, url: 'https://other.example.com/' } : tab },
        cookies: {
            getAllCookieStores: async () => missingStore ? [] : [
                { id: 'other-profile', tabIds: [99] }, { id: 'profile-1', tabIds: [tab.id] },
            ],
            getAll: async (value) => {
            calls.push(['cookies', value]);
            return [
                { name: 'session', value: 'synthetic', domain: 'login.example.com', secure: true, sameSite: 'strict', partitionKey: null },
                { name: 'unspecified', value: 'synthetic', sameSite: 'unspecified' },
                { name: 'insecure', value: 'synthetic', secure: false, sameSite: 'no_restriction' },
                { name: 'partitioned', value: 'synthetic', domain: 'login.example.com', partitionKey: { topLevelSite: 'https://elsewhere.example' } },
            ];
        } },
        runtime: { sendNativeMessage: async (_, value) => {
            calls.push(['native', value]);
            return { ok: true, id: 'E6AA8463-86A5-4CEB-AF4B-BF439FF49739', count: value.cookies.length };
        } },
    };
}

test('exports only the approved current page and keeps credentials out of the link', async () => {
    const api = safari();
    const result = await exportCurrentPage(api, tab);
    assert.deepEqual(api.calls[0], ['permission', { origins: ['https://login.example.com/*'] }]);
    assert.deepEqual(api.calls[1], ['cookies', { url: tab.url, storeId: 'profile-1' }]);
    const payload = api.calls[2][1];
    assert.equal(payload.origin, 'https://login.example.com');
    assert.equal(payload.cookies.length, 1);
    assert.equal(result.skipped, 3);
    assert.equal(result.url, 'happier-native://browser-import/E6AA8463-86A5-4CEB-AF4B-BF439FF49739');
});

test('denial never reads cookies or writes the native handoff', async () => {
    const api = safari({ granted: false });
    await assert.rejects(exportCurrentPage(api, tab));
    assert.deepEqual(api.calls.map(([name]) => name), ['permission']);
});

test('a tab that navigated while requesting permission needs a new explicit export', async () => {
    const api = safari({ changed: true });
    await assert.rejects(exportCurrentPage(api, tab));
    assert.deepEqual(api.calls.map(([name]) => name), ['permission']);
});

test('never falls back to another profile when the tab cookie store is unavailable', async () => {
    const api = safari({ missingStore: true });
    await assert.rejects(exportCurrentPage(api, tab));
    assert.deepEqual(api.calls.map(([name]) => name), ['permission']);
});
