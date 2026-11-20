import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { JSDOM } from 'jsdom';

import { readSessionLink, renderLanding } from '../public/native/landing.js';

const landingUrl = (session = 'session-123', server = 'https://relay.example.test') => {
    const url = new URL('https://happier.example.test/native/index.html');
    url.searchParams.set('session', session);
    url.searchParams.set('server', server);
    return url.href;
};

// The landing is a public URL writer. Browser fallback intentionally targets the
// existing root legacy reader, which retains id while displaying inline login.
test('writes both destinations without changing an opaque session ID or relay path', () => {
    const session = 'session_é+&@';
    const server = 'https://relay.example.test:8443/happier';
    const result = readSessionLink(landingUrl(session, server));
    assert.equal(result.error, undefined);
    const native = new URL(result.nativeHref);
    assert.equal(native.protocol, 'happier-native:');
    assert.equal(native.hostname, 'session');
    assert.equal(decodeURIComponent(native.pathname.slice(1)), session);
    assert.equal(native.searchParams.get('server'), server);
    const browser = new URL(result.browserHref, 'https://happier.example.test');
    assert.equal(browser.origin, 'https://happier.example.test');
    assert.equal(browser.pathname, '/');
    assert.equal(browser.searchParams.get('id'), session);
    assert.equal(browser.searchParams.get('server'), server);
    assert.equal(browser.hash, '');
});

test('preserves relay scope bytes instead of reserializing a validated URL', () => {
    const relays = [
        ['https://relay.example.test:443', 'https://relay.example.test:443'],
        ['https://relay.example.test/root/../relay', 'https://relay.example.test/root/../relay'],
        ['HTTPS://Relay.Example.test/CaseSensitive/Path', 'HTTPS://Relay.Example.test/CaseSensitive/Path'],
        ['https://relay.example.test/relay///', 'https://relay.example.test/relay'],
    ];
    for (const [input, expected] of relays) {
        const result = readSessionLink(landingUrl('session-123', input));
        assert.equal(result.error, undefined, input);
        assert.equal(result.server, expected, input);
        assert.equal(new URL(result.nativeHref).searchParams.get('server'), expected, input);
        assert.equal(new URL(result.browserHref, 'https://happier.example.test').searchParams.get('server'), expected, input);
    }
});

test('rejects ambiguous, incomplete and unsafe links without navigable destinations', () => {
    const cases = [
        'https://happier.example.test/native/index.html',
        ...['', '.', '..', '   ', 'session id', 'session\n123', 'session/123', 'session\\123', 'session?123', 'session#123', 'session%2F123'].map(id => landingUrl(id)),
        landingUrl('session-123', ''),
        landingUrl() + '&session=other',
        landingUrl() + '&extra=value',
        landingUrl() + '&extra=',
        landingUrl() + '#section',
        landingUrl() + '#',
        landingUrl() + '&server=https://other.example.test',
        landingUrl('session-123', 'javascript:alert(1)'),
        landingUrl('session-123', '//other.example.test'),
        landingUrl('session-123', 'http://relay.example.test'),
        landingUrl('session-123', 'http://localhost.example.test'),
        landingUrl('session-123', 'https://relay.example.test/\\evil'),
        landingUrl('session-123', 'https://relay.example.test/\npath'),
        landingUrl('session-123', 'https://user:secret@relay.example.test'),
        landingUrl('session-123', 'https://@relay.example.test'),
        landingUrl('session-123', 'https://relay.example.test/?token=secret'),
        landingUrl('session-123', 'https://relay.example.test/#secret'),
        landingUrl('session-123', 'https://relay.example.test/?'),
        landingUrl('session-123', 'https://relay.example.test/#'),
    ];
    for (const href of cases) {
        const result = readSessionLink(href);
        assert.ok(result.error, href);
        assert.equal(result.nativeHref, undefined, href);
        assert.equal(result.browserHref, undefined, href);
    }
});

test('accepts loopback HTTP without permitting lookalike remote relays', () => {
    for (const server of ['http://localhost:3005', 'http://127.0.0.1:3005/relay', 'http://[::1]:3005']) {
        const result = readSessionLink(landingUrl('session-123', server));
        assert.equal(result.error, undefined);
        assert.equal(new URL(result.nativeHref).searchParams.get('server'), server);
    }
});

test('only explicit user links navigate; invalid input clears both links and never becomes markup', () => {
    const html = fs.readFileSync(new URL('../public/native/index.html', import.meta.url), 'utf8');
    const dom = new JSDOM(html, { url: landingUrl() });
    const { document } = dom.window;
    renderLanding(document, landingUrl('session-123', 'https://relay.example.test/long-path'));
    assert.equal(document.querySelector('#open-native').getAttribute('href'), readSessionLink(landingUrl('session-123', 'https://relay.example.test/long-path')).nativeHref);
    assert.equal(document.querySelector('#continue-browser').getAttribute('href'), readSessionLink(landingUrl('session-123', 'https://relay.example.test/long-path')).browserHref);
    assert.equal(document.querySelector('#relay').textContent, 'https://relay.example.test/long-path');
    assert.equal(dom.window.location.href, landingUrl());
    renderLanding(document, landingUrl('session-123', 'javascript:<img src=x onerror=alert(1)>'));
    for (const selector of ['#open-native', '#continue-browser']) {
        assert.equal(document.querySelector(selector).hasAttribute('href'), false);
        assert.equal(document.querySelector(selector).getAttribute('aria-disabled'), 'true');
    }
    assert.equal(document.querySelector('#link-error').hidden, false);
    assert.equal(document.querySelector('img'), null);
    assert.equal(dom.window.location.href, landingUrl());
    dom.window.close();
});

test('AASA gives only native opening links to Native and preserves all other RN routes', () => {
    const aasa = JSON.parse(fs.readFileSync(new URL('../public/.well-known/apple-app-site-association', import.meta.url), 'utf8'));
    const native = aasa.applinks.details.find(entry => entry.appIDs.includes('DPF7ZLTLN2.com.devmanny.happier'));
    assert.ok(native, 'Native must be associated explicitly');
    assert.deepEqual(native.components.map(component => component['/']), ['/native/*']);
    const rn = aasa.applinks.details.find(entry => entry.appIDs.includes('L86V3EF623.dev.happier.app'));
    const exclusion = rn.components.findIndex(component => component['/'] === '/native/*' && component.exclude === true);
    const wildcard = rn.components.findIndex(component => component['/'] === '*' && !component.exclude);
    assert.ok(exclusion >= 0 && exclusion < wildcard, 'RN must exclude Native links before its existing wildcard');
    assert.deepEqual(aasa.activitycontinuation.apps, ['L86V3EF623.dev.happier.app']);
});
