import HappierKit
import SwiftUI
import WebKit

/// Integrated browser: address bar, back/forward/reload and tabs over the shared `BrowserModel`.
/// Its own window on the Mac and iPad (`BrowserWindow`), a sheet on the iPhone.
struct BrowserView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss
    var inSheet = false
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        page
            #if os(macOS)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) { backButton; forwardButton }
                ToolbarItem(placement: .principal) { addressField.frame(minWidth: 280, idealWidth: 620, maxWidth: 820) }
                ToolbarItemGroup(placement: .primaryAction) { reloadButton; AgentBrowserIndicator(); tabsMenu }
            }
            .navigationTitle(browser.selectedTab?.displayTitle ?? "Browser")
            #else
            .safeAreaInset(edge: .top, spacing: 0) { phoneBar }
            #endif
            .onAppear { browser.viewAppeared() }
            .onDisappear { browser.viewDisappeared() }
            .onChange(of: browser.selectedTab?.url, initial: true) { _, url in
                if !addressFocused { address = url?.absoluteString ?? "" }
            }
    }

    private var page: some View {
        Group {
            if let tab = browser.selectedTab {
                ZStack(alignment: .top) {
                    BrowserWebView(tab: tab).id(tab.id)
                    if tab.isLoading {
                        ProgressView(value: tab.estimatedProgress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                ContentUnavailableView("No Tabs", systemImage: "safari")
            }
        }
    }

    #if os(iOS)
    /// iPhone/iPad: one glass bar over the page, Safari-like.
    private var phoneBar: some View {
        HStack(spacing: 12) {
            if inSheet {
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }
            backButton
            forwardButton
            addressField
            reloadButton
            AgentBrowserIndicator()
            tabsMenu
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
    #endif

    private var backButton: some View {
        Button { browser.selectedTab?.webView.goBack() } label: { Image(systemName: "chevron.backward") }
            .disabled(browser.selectedTab?.canGoBack != true)
            .accessibilityLabel(Text("Back"))
    }

    private var forwardButton: some View {
        Button { browser.selectedTab?.webView.goForward() } label: { Image(systemName: "chevron.forward") }
            .disabled(browser.selectedTab?.canGoForward != true)
            .accessibilityLabel(Text("Forward"))
    }

    private var addressField: some View {
        TextField("Search or enter website", text: $address)
            .textFieldStyle(.roundedBorder)
            .focused($addressFocused)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.webSearch)
            #endif
            .submitLabel(.go)
            .onSubmit {
                browser.open(typed: address)
                addressFocused = false
            }
    }

    @ViewBuilder private var reloadButton: some View {
        if browser.selectedTab?.isLoading == true {
            Button { browser.selectedTab?.webView.stopLoading() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(Text("Stop"))
        } else {
            Button { browser.selectedTab?.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel(Text("Reload"))
        }
    }

    private var tabsMenu: some View {
        Menu {
            Button { browser.newTab(); addressFocused = true } label: { Label("New Tab", systemImage: "plus") }
            if let tab = browser.selectedTab {
                Button(role: .destructive) { browser.closeTab(tab.id) } label: { Label("Close Tab", systemImage: "xmark") }
            }
            if browser.tabs.count > 1 {
                Divider()
                Picker("Tabs", selection: Binding(get: { browser.selectedTab?.id }, set: { browser.selectedTabId = $0 })) {
                    ForEach(browser.tabs) { tab in Text(tab.displayTitle).tag(Optional(tab.id)) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: browser.tabs.count > 1 ? "\(min(browser.tabs.count, 50)).square" : "square.on.square")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Tabs"))
    }
}

/// A discreet sign that a session agent drove the browser in the last seconds; never blocks.
struct AgentBrowserIndicator: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let until = browser.agentActiveUntil, until > context.date {
                Label("Agent", systemImage: "sparkles")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse)
                    .help("An agent is using the browser")
                    .accessibilityLabel(Text("An agent is using the browser"))
                    .transition(.opacity)
            }
        }
    }
}

/// Shows a tab's web view; when the view goes away the web view returns to the off-screen host.
#if os(macOS)
struct BrowserWebView: NSViewRepresentable {
    let tab: BrowserTab
    @Environment(BrowserModel.self) private var browser

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) { host(tab.webView, in: view) }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.release(from: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab, browser: browser) }

    private func host(_ webView: WKWebView, in view: NSView) {
        guard webView.superview !== view else { return }
        webView.removeFromSuperview()
        webView.frame = view.bounds
        webView.autoresizingMask = [.width, .height]
        view.addSubview(webView)
    }

    @MainActor final class Coordinator {
        let tab: BrowserTab
        weak var browser: BrowserModel?
        init(tab: BrowserTab, browser: BrowserModel) {
            self.tab = tab
            self.browser = browser
        }
        /// Only when this view still holds it: a newer view of the same tab may already show it.
        func release(from view: AnyObject) {
            if tab.webView.superview === view { browser?.park(tab) }
        }
    }
}
#else
struct BrowserWebView: UIViewRepresentable {
    let tab: BrowserTab
    @Environment(BrowserModel.self) private var browser

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ view: UIView, context: Context) {
        let webView = tab.webView
        guard webView.superview !== view else { return }
        webView.removeFromSuperview()
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.release(from: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab, browser: browser) }

    @MainActor final class Coordinator {
        let tab: BrowserTab
        weak var browser: BrowserModel?
        init(tab: BrowserTab, browser: BrowserModel) {
            self.tab = tab
            self.browser = browser
        }
        /// Only when this view still holds it: a newer view of the same tab may already show it.
        func release(from view: AnyObject) {
            if tab.webView.superview === view { browser?.park(tab) }
        }
    }
}
#endif

/// The browser's own window (Mac, iPad); one shared window, reopened rather than duplicated.
struct BrowserWindow: View {
    static let id = "browser"
    /// The only value the window group is opened with, so it never makes a second browser window.
    static let value = "main"

    var body: some View {
        BrowserView()
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 420)
            #endif
    }
}
