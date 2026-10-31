import HappierKit
import Observation
import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One browser tab: a WKWebView sharing the app's persistent website data (cookies, logins).
@MainActor @Observable
final class BrowserTab: Identifiable {
    let id: String
    /// The user (opened by hand) or the session whose agent drives it.
    let owner: DeviceBrowserTabOwner
    let webView: WKWebView
    /// Until when the ✨ shows on this tab: an agent used it in the last seconds.
    private(set) var agentActiveUntil: Date?
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var estimatedProgress = 0.0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(id: String, owner: DeviceBrowserTabOwner, configuration: WKWebViewConfiguration) {
        self.id = id
        self.owner = owner
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        #if os(iOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        #endif
        // Inspectable from Safari's Develop menu, which helps when a site misbehaves.
        webView.isInspectable = true
        observations = [
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.estimatedProgress = view.estimatedProgress }
            },
        ]
    }

    var pageTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }

    var sessionId: String? {
        if case .session(let id) = owner { return id }
        return nil
    }

    func noteAgentActivity() {
        agentActiveUntil = Date().addingTimeInterval(4)
    }
}

/// The app-wide integrated browser: tabs the user browses in its own window (Mac, iPad) or sheet
/// (iPhone), and that session agents drive over the relay (`DeviceBrowserHost`).
///
/// Tabs outlive the UI. A tab the UI is not showing is parked in an off-screen host view so the
/// agent can keep loading, reading and capturing it in the background.
@MainActor @Observable
final class BrowserModel: NSObject {
    static let agentAccessKey = "browser.agentAccess"

    /// Every tab, user's and sessions', in opening order; each has its own web view.
    private(set) var tabs: [BrowserTab] = []
    /// The tab the browser UI shows. Only the user changes it; agents never do.
    var selectedTabId: String?
    /// Open browser windows or sheets on this device.
    private(set) var openViews = 0
    /// Tabs some browser view is showing right now (kept when their session ends). Written while
    /// views update, so not observed.
    @ObservationIgnored private(set) var displayedTabIds: Set<String> = []
    @ObservationIgnored private var watchingSessions = false

    @ObservationIgnored weak var store: HappierStore?
    @ObservationIgnored var registry = DeviceBrowserTabRegistry()
    /// One call at a time per tab; different tabs (sessions) run alongside.
    @ObservationIgnored let operations = KeyedSerialQueue()
    @ObservationIgnored private var sessionWatch = DeviceBrowserSessionWatch()
    @ObservationIgnored private var focusClaimed = false
    @ObservationIgnored let configuration: WKWebViewConfiguration
    @ObservationIgnored private let parking = BrowserParking()
    @ObservationIgnored var navigationWaiters: [ObjectIdentifier: [CheckedContinuation<Error?, Never>]] = [:]

    override init() {
        let configuration = WKWebViewConfiguration()
        // Persistent: cookies and logins survive relaunches, shared by every tab (and the agent).
        configuration.websiteDataStore = .default()
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        self.configuration = configuration
        super.init()
    }

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabId } ?? tabs.first { $0.owner == .user } }

    func tab(_ id: String) -> BrowserTab? { tabs.first { $0.id == id } }

    /// Any agent active in the last seconds, for the toolbar's ✨.
    var agentActive: Bool { tabs.contains { ($0.agentActiveUntil ?? .distantPast) > Date() } }

    var agentAccessEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.agentAccessKey) as? Bool ?? true
    }

    // MARK: - Tabs

    /// A tab the user opens; it becomes the one the browser shows.
    @discardableResult
    func newTab(url: URL? = nil) -> BrowserTab {
        let tab = addTab(id: registry.open(for: .user), owner: .user, url: url)
        selectedTabId = tab.id
        return tab
    }

    /// Creates the web view for a tab the registry already assigned.
    @discardableResult
    func addTab(id: String, owner: DeviceBrowserTabOwner, url: URL? = nil) -> BrowserTab {
        let tab = BrowserTab(id: id, owner: owner, configuration: configuration)
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        parking.park(tab.webView)
        tabs.append(tab)
        if let url { tab.webView.load(URLRequest(url: url)) }
        return tab
    }

    /// Opening the browser from a session shows that session's current tab, opening it first
    /// when the agent hasn't used the browser yet (the agent then keeps working in it).
    func showTab(for sessionId: String) {
        guard let resolved = try? registry.tab(for: sessionId, tabId: nil, create: true) else { return }
        selectedTabId = (tab(resolved.id) ?? addTab(id: resolved.id, owner: .session(sessionId))).id
    }

    /// Whether the session has a tab open, for the browser button in its toolbar.
    func hasTabs(for sessionId: String) -> Bool { tabs.contains { $0.sessionId == sessionId } }

    func closeTab(_ id: String) {
        registry.close(id)
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        finishWaiting(tab.webView)
        if selectedTabId == id { selectedTabId = tabs.first { $0.owner == .user }?.id }
    }

    func tabDisplayed(_ id: String, _ shown: Bool) {
        if shown { displayedTabIds.insert(id) } else { displayedTabIds.remove(id) }
    }

    /// The session's name and folder color for its tabs.
    func sessionTitle(_ sessionId: String) -> String {
        store?.sessions[sessionId]?.title ?? "Session \(sessionId.prefix(6))"
    }

    func sessionColor(_ sessionId: String) -> Color? {
        store?.folderColor(of: store?.sessions[sessionId])?.deep
    }

    // MARK: - Ended sessions

    /// Watches the session list and closes tabs of sessions that stopped or were archived,
    /// unless a browser view is showing them.
    func startWatchingSessions() {
        guard !watchingSessions else { return }
        watchingSessions = true
        watchSessions()
    }

    private func watchSessions() {
        guard let store else { return }
        withObservationTracking {
            reconcileSessionTabs(store)
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchSessions() }
        }
    }

    private func reconcileSessionTabs(_ store: HappierStore) {
        let owners = Set(tabs.compactMap(\.sessionId))
        var ended: Set<String> = []
        for sessionId in owners {
            let session = store.sessions[sessionId]
            let state = session.map { DeviceBrowserSessionWatch.State(active: $0.active, archived: $0.archivedAt != nil) }
            if sessionWatch.observe(sessionId, state) { ended.insert(sessionId) }
        }
        guard !ended.isEmpty else { return }
        let live = owners.subtracting(ended)
        for id in registry.tabsToClose(liveSessionIds: live, visibleTabIds: displayedTabIds) { closeTab(id) }
    }

    /// Returns a view the UI shows a tab's web view in; the tab goes back to the off-screen host when hidden.
    func park(_ tab: BrowserTab) { parking.park(tab.webView) }

    // MARK: - Address bar

    /// Typed text to a URL: a URL as is, a bare domain over https, anything else a web search.
    static func url(fromTyped text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "about", "file", "data"].contains(scheme) { return url }
        if !trimmed.contains(" "), trimmed.contains(".") || trimmed.hasPrefix("localhost"),
           let url = URL(string: "https://\(trimmed)") { return url }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return search.url
    }

    func open(typed text: String, in tab: BrowserTab? = nil) {
        guard let url = Self.url(fromTyped: text) else { return }
        if let tab = tab ?? selectedTab { tab.webView.load(URLRequest(url: url)) } else { newTab(url: url) }
    }

    // MARK: - Relay slots

    /// The browser UI opened: this device becomes the most recent one serving `focused`.
    func viewAppeared() {
        openViews += 1
        if selectedTab == nil { newTab() }
        focusClaimed = true
        updateSlots(reclaim: true)
    }

    func viewDisappeared() {
        openViews = max(0, openViews - 1)
        #if os(macOS)
        // On the Mac the window is the claim; the host slot keeps serving in the background.
        if openViews == 0 { focusClaimed = false }
        #endif
        updateSlots()
    }

    /// iOS closes the relay connection in the background, and the claim goes with it.
    func appEnteredBackground() {
        #if os(iOS)
        focusClaimed = false
        updateSlots()
        #endif
    }

    /// Back in the foreground with the browser still on screen, this device is the focused one again.
    func appBecameActive() {
        #if os(iOS)
        guard openViews > 0 else { return }
        focusClaimed = true
        updateSlots(reclaim: true)
        #endif
    }

    func updateSlots(reclaim: Bool = false) {
        guard let store else { return }
        var slots: Set<DeviceBrowserSlot> = []
        if agentAccessEnabled {
            #if os(macOS)
            slots.insert(.host)
            #endif
            if focusClaimed { slots.insert(.focused) }
        }
        store.setDeviceBrowserSlots(slots, reclaim: reclaim)
    }

    func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    static var device: DeviceBrowserDevice {
        #if os(macOS)
        return .init(name: Host.current().localizedName ?? "Mac", platform: .macos)
        #else
        return .init(name: UIDevice.current.name, platform: UIDevice.current.userInterfaceIdiom == .pad ? .ipados : .ios)
        #endif
    }
}

// MARK: - Navigation

extension BrowserModel: WKNavigationDelegate, WKUIDelegate {
    /// Waits for the web view's current navigation to finish; nil on success.
    func waitForNavigation(of webView: WKWebView) async -> Error? {
        await withCheckedContinuation { continuation in
            navigationWaiters[ObjectIdentifier(webView), default: []].append(continuation)
        }
    }

    func finishWaiting(_ webView: WKWebView) { finishNavigation(webView, error: nil) }

    private func finishNavigation(_ webView: WKWebView, error: Error?) {
        let waiters = navigationWaiters.removeValue(forKey: ObjectIdentifier(webView)) ?? []
        for waiter in waiters { waiter.resume(returning: error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishNavigation(webView, error: nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishNavigation(webView, error: Self.isCancellation(error) ? nil : error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishNavigation(webView, error: Self.isCancellation(error) ? nil : error) }
    }

    /// A newer navigation replacing this one is not a failure of the page.
    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
    }

    /// `target=_blank` links and `window.open` open in a new tab of this browser.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            guard let url = navigationAction.request.url else { return nil }
            switch tabs.first(where: { $0.webView === webView })?.owner {
            case .session(let sessionId):
                // A session's popup stays that session's, and does not take over the user's view.
                addTab(id: registry.open(for: .session(sessionId)), owner: .session(sessionId), url: url)
            default:
                newTab(url: url)
            }
            return nil
        }
    }
}

/// Keeps web views that no window shows attached to an off-screen view, so they keep rendering
/// (screenshots, layout) while the agent uses them in the background.
@MainActor
final class BrowserParking {
    #if os(macOS)
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1280, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900))
        window.orderBack(nil)
        return window
    }()

    func park(_ webView: WKWebView) {
        guard let container = window.contentView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
    #else
    private let container: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        return view
    }()

    func park(_ webView: WKWebView) {
        attachContainer()
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }

    /// Behind the app's own views in its window: WebKit keeps rendering a view that is in a window.
    private func attachContainer() {
        guard container.window == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
        guard let window else { return }
        container.frame = window.bounds
        window.insertSubview(container, at: 0)
    }
    #endif
}
