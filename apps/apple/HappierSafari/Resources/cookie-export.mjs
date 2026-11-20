// No background collection: this function runs only from the popup's Prepare Import button.
export async function exportCurrentPage(api, tab) {
    const page = new URL(tab.url);
    if (!['https:', 'http:'].includes(page.protocol) || page.username || page.password) throw new Error('unsupported');
    const granted = await api.permissions.request({ origins: [`${page.origin}/*`] });
    if (!granted) throw new Error('permission');
    const current = await api.tabs.get(tab.id);
    if (current.url !== tab.url) throw new Error('page-changed');
    // Select the store attached to this tab, including its profile/private browsing context.
    // A default-store fallback could silently import a different account's cookies.
    const stores = await api.cookies.getAllCookieStores();
    const store = stores.find(candidate => candidate.tabIds.includes(tab.id));
    if (!store) throw new Error('cookie-store');
    const available = await api.cookies.getAll({ url: tab.url, storeId: store.id });
    // WebKit cannot preserve a partition key or an unspecified SameSite policy on this path.
    // SameSite=None also requires Secure. Skip unsupported scope instead of weakening it.
    const cookies = available.filter(cookie => !cookie.partitionKey && cookie.partitioned !== true &&
        cookie.sameSite !== 'unspecified' && !(cookie.sameSite === 'no_restriction' && !cookie.secure));
    if (!cookies.length) throw new Error('empty');
    const response = await api.runtime.sendNativeMessage('com.devmanny.happier.safari', {
        version: 1, origin: page.origin, cookies,
    });
    if (!response?.ok || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(response.id)) {
        throw new Error('handoff');
    }
    return { url: `happier-native://browser-import/${response.id}`, count: response.count, skipped: available.length - cookies.length };
}
