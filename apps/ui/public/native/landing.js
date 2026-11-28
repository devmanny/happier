// This static link boundary is deliberately independent of the RN auth/runtime.
// Keep its accepted public URL inputs aligned with HappierKit.SessionLink.
/**
 * @typedef {{ error: string } | {
 *   sessionId: string, server: string, nativeHref: string, browserHref: string
 * }} SessionLinkResult
 */

/** @param {string} href @returns {SessionLinkResult} */
export function readSessionLink(href) {
    const invalid = { error: 'This session link is incomplete or invalid. Ask for a new link and try again.' };
    try {
        const url = new URL(href);
        if (url.href.includes('#') || [...url.searchParams.keys()].some(key => key !== 'session' && key !== 'server')) return invalid;
        const sessions = url.searchParams.getAll('session');
        const servers = url.searchParams.getAll('server');
        if (sessions.length !== 1 || servers.length !== 1) return invalid;
        const sessionId = sessions[0];
        // One opaque path segment; never trim or double-decode into another ID.
        if (!sessionId || sessionId === '.' || sessionId === '..' || /[\s\p{Cc}/\\?#%]/u.test(sessionId)) return invalid;
        const rawServer = servers[0];
        if (/[\s\p{Cc}\\?#]/u.test(rawServer)) return invalid;
        const authority = rawServer.match(/^https?:\/\/([^/]+)/i)?.[1];
        if (!authority || authority.includes('@')) return invalid;
        const serverUrl = new URL(rawServer);
        const loopback = /^(?:localhost|127\.0\.0\.1)(?::[0-9]+)?$/i.test(authority)
            || /^\[::1\](?::[0-9]+)?$/i.test(authority);
        if (serverUrl.protocol !== 'https:' && !(serverUrl.protocol === 'http:' && loopback)) return invalid;
        // Validation must not rewrite the relay's credential scope (:443, case, or path).
        const server = rawServer.replace(/\/+$/, '');
        const native = new URL(`happier-native://session/${encodeURIComponent(sessionId)}`);
        native.searchParams.set('server', server);
        // Released RN root reader retains id while showing inline login. Some
        // external/restore auth flows return to /; the page explains reopening.
        const browser = new URLSearchParams({ id: sessionId, server });
        return { sessionId, server, nativeHref: native.href, browserHref: `/?${browser}` };
    } catch {
        return invalid;
    }
}

/** @param {Document} document @param {string} href */
export function renderLanding(document, href) {
    const result = readSessionLink(href);
    const native = document.getElementById('open-native');
    const browser = document.getElementById('continue-browser');
    const relay = document.getElementById('relay');
    const context = document.getElementById('relay-context');
    const error = document.getElementById('link-error');
    for (const link of [native, browser]) {
        link.removeAttribute('href');
        link.setAttribute('aria-disabled', 'true');
        link.setAttribute('tabindex', '-1');
    }
    if ('error' in result) {
        relay.textContent = '';
        context.hidden = true;
        error.textContent = result.error;
        error.hidden = false;
        return result;
    }
    relay.textContent = result.server;
    context.hidden = false;
    error.hidden = true;
    error.textContent = '';
    native.setAttribute('href', result.nativeHref);
    browser.setAttribute('href', result.browserHref);
    for (const link of [native, browser]) {
        link.removeAttribute('aria-disabled');
        link.removeAttribute('tabindex');
    }
    return result;
}

if (typeof document !== 'undefined') renderLanding(document, window.location.href);
