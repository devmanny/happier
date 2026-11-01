import { exportCurrentPage } from './cookie-export.mjs';
const prepare = document.querySelector('#prepare');
const status = document.querySelector('#status');
const open = document.querySelector('#open');
let tab;
try {
    [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    const page = new URL(tab.url);
    if (['http:', 'https:'].includes(page.protocol)) {
        document.querySelector('#site').textContent = page.hostname;
        prepare.disabled = false;
    }
} catch { status.textContent = 'Open a website, then try again.'; }
prepare.addEventListener('click', async () => {
    prepare.disabled = true;
    status.textContent = 'Preparing…';
    try {
        const result = await exportCurrentPage(browser, tab);
        open.href = result.url;
        open.hidden = false;
        prepare.hidden = true;
        status.textContent = `${result.count} cookies ready.${result.skipped ? ` ${result.skipped} unsupported cookies skipped.` : ''} Open Happier to review, or go to Settings → Browser → Import from Safari.`;
    } catch {
        status.textContent = 'Nothing was imported. Allow access to this website and try again. If the page changed or has no supported cookies, reopen this extension.';
        prepare.disabled = false;
    }
});
