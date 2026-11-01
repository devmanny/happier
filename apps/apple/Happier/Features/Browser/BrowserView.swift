import HappierKit
import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Integrated browser over the shared `BrowserModel`, laid out like Safari: on the iPhone a glass
/// bar at the bottom; on the Mac and iPad the address in the toolbar and a tab strip under it.
struct BrowserView: View {
    @Environment(BrowserModel.self) private var browser
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    var inSheet = false

    var body: some View {
        layout
            .onAppear { browser.viewAppeared() }
            .onDisappear { browser.viewDisappeared() }
    }

    @ViewBuilder private var layout: some View {
        #if os(macOS)
        desktop
        #else
        if sizeClass == .compact {
            BrowserPage()
                .safeAreaInset(edge: .bottom, spacing: 0) { BrowserPhoneBar(inSheet: inSheet) }
                .toolbar(.hidden, for: .navigationBar)
        } else {
            desktop
        }
        #endif
    }

    private var desktop: some View {
        BrowserPage()
            .safeAreaInset(edge: .top, spacing: 0) {
                if browser.tabs.count > 1 { BrowserTabStrip() }
            }
            .toolbar {
                // Native placement reserves the Mac window controls and iPad's
                // system chrome; never overlay the logo on the title bar.
                ToolbarItem(placement: .navigation) {
                    Color.blue
                        .frame(width: 24, height: 24)
                        .mask {
                            // Keep the original smile cutout when tinting the brand asset.
                            Image("Logo")
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .colorInvert()
                                .luminanceToAlpha()
                        }
                        .accessibilityElement()
                        .accessibilityLabel(Text("Happier"))
                        .accessibilityAddTraits(.isImage)
                        .help("Happier")
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .navigation)
                ToolbarItemGroup(placement: .navigation) {
                    BrowserBackButton()
                    BrowserForwardButton()
                }
                ToolbarItem(placement: .principal) {
                    BrowserAddressField(compact: false)
                        .frame(minWidth: 180, idealWidth: 560, maxWidth: 720)
                }
                if inSheet {
                    ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
                }
                if let url = browser.selectedTab?.url {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            .help("Share")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { browser.newTab() } label: { Label("New Tab", systemImage: "plus") }
                        .keyboardShortcut("t", modifiers: .command)
                        .help("New Tab")
                }
            }
            #if os(macOS)
            .toolbar(removing: .title)
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(browser.selectedTab.map(browser.tabTitle) ?? "Browser")
    }
}

// MARK: - Page

/// The selected tab's page, a start page for an empty tab, and a thin loading line on top.
private struct BrowserPage: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        ZStack(alignment: .top) {
            if let tab = browser.selectedTab {
                BrowserWebView(tab: tab).id(tab.id)
                if tab.url == nil, !tab.isLoading { BrowserStartPage() }
                BrowserLoadingLine(tab: tab)
            } else {
                BrowserStartPage()
            }
        }
    }
}

private struct BrowserLoadingLine: View {
    let tab: BrowserTab

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.tint)
                .frame(width: proxy.size.width * max(0.05, tab.estimatedProgress), height: 2.5)
                .opacity(tab.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: tab.estimatedProgress)
                .animation(.easeOut(duration: 0.4), value: tab.isLoading)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}

/// What an empty tab shows: the browser's name, and the tabs agents are working in.
private struct BrowserStartPage: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "safari")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.tint)
            Text("Happier Browser")
                .font(.title2.weight(.semibold))
            Text("Your agents work in their own tabs here, signed in with the same accounts as you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            let agentTabs = browser.tabs.filter { $0.sessionId != nil }
            if !agentTabs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(agentTabs) { tab in
                        Button { browser.selectedTabId = tab.id } label: {
                            HStack(spacing: 10) {
                                BrowserTabMark(tab: tab)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(browser.sessionTitle(tab.sessionId ?? "")).font(.subheadline.weight(.medium))
                                    Text(tab.pageTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                                AgentSparkle(tab: tab)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(maxWidth: 360)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                    }
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Address

/// Safari-style address: the site's host centered while browsing; the full address, selected,
/// while typing. Reload/stop and the agent's ✨ sit inside it.
private struct BrowserAddressField: View {
    @Environment(BrowserModel.self) private var browser
    let compact: Bool
    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
        let tab = browser.selectedTab
        HStack(spacing: 6) {
            if !focused, let url = tab?.url {
                Image(systemName: url.scheme == "https" ? "lock.fill" : "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            TextField("Search or enter website", text: $text, selection: $selection)
                .textFieldStyle(.plain)
                .multilineTextAlignment(focused ? .leading : .center)
                .font(compact ? .body.weight(.medium) : .callout)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.webSearch)
                #endif
                .submitLabel(.go)
                .onSubmit {
                    browser.open(typed: text)
                    focused = false
                }
            if let tab, !focused, tab.url != nil {
                AgentSparkle(tab: tab)
                Button {
                    if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tab.isLoading ? "Stop" : "Reload"))
            }
        }
        .padding(.horizontal, compact ? 16 : 10)
        .frame(height: compact ? 46 : 30)
        .background {
            if !compact { Capsule().fill(.quaternary.opacity(0.6)) }
        }
        .contentShape(.capsule)
        .onTapGesture { focused = true }
        .onChange(of: focused) { _, isFocused in
            text = display(tab?.url, editing: isFocused)
            if isFocused { selection = TextSelection(range: text.startIndex..<text.endIndex) }
        }
        .onChange(of: tab?.url, initial: true) { _, url in
            if !focused { text = display(url, editing: false) }
        }
        .onChange(of: browser.selectedTabId) { _, _ in
            if !focused { text = display(browser.selectedTab?.url, editing: false) }
        }
    }

    /// The host while browsing ("github.com"), the whole address while editing.
    private func display(_ url: URL?, editing: Bool) -> String {
        guard let url else { return "" }
        if editing { return url.absoluteString }
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Navigation buttons

private struct BrowserBackButton: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        Button { browser.selectedTab?.webView.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
            .disabled(browser.selectedTab?.canGoBack != true)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")
    }
}

private struct BrowserForwardButton: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        Button { browser.selectedTab?.webView.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
            .disabled(browser.selectedTab?.canGoForward != true)
            .keyboardShortcut("]", modifiers: .command)
            .help("Forward")
    }
}

// MARK: - iPhone bar

/// The iPhone's bottom bar: back, the address pill and a menu, three pieces of glass that meld.
private struct BrowserPhoneBar: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let inSheet: Bool

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    AppHaptics.light()
                    browser.selectedTab?.webView.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .frame(width: 46, height: 46)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(browser.selectedTab?.canGoBack != true)
                .opacity(browser.selectedTab?.canGoBack == true ? 1 : 0.35)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(Text("Back"))

                BrowserAddressField(compact: true)
                    .glassEffect(.regular.interactive(), in: .capsule)

                Menu { menu } label: {
                    Image(systemName: browser.tabs.count > 1 ? "square.on.square" : "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 46, height: 46)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(Text("More"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var menu: some View {
        let tab = browser.selectedTab
        Section {
            Button { tab?.webView.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                .disabled(tab?.canGoForward != true)
            if let url = tab?.url {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                // A browser build may itself be the default; avoid reopening this URL in a loop.
                if !BrowserModel.isBrowserRole {
                    Button { BrowserModel.openInDefaultBrowser(url) } label: {
                        Label("Open in Default Browser", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
        Section("Tabs") {
            Picker("Tabs", selection: Binding(get: { browser.selectedTab?.id }, set: { browser.selectedTabId = $0 })) {
                ForEach(browser.tabs) { tab in
                    Text(browser.tabTitle(tab)).tag(Optional(tab.id))
                }
            }
            .pickerStyle(.inline)
            Button { browser.newTab() } label: { Label("New Tab", systemImage: "plus") }
            if let tab {
                Button(role: .destructive) { browser.closeTab(tab.id) } label: { Label("Close Tab", systemImage: "xmark") }
            }
        }
        if inSheet {
            Section {
                Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
            }
        }
    }
}

// MARK: - Tab strip (Mac, iPad)

/// Safari-style tabs sharing the width; a session's tab carries its name, color and ✨.
private struct BrowserTabStrip: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        HStack(spacing: 4) {
            ForEach(browser.tabs) { tab in
                BrowserTabItem(tab: tab, selected: tab.id == browser.selectedTab?.id)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct BrowserTabItem: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            BrowserTabMark(tab: tab)
            Text(browser.tabTitle(tab))
                .font(.callout.weight(selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            AgentSparkle(tab: tab)
            Button { browser.closeTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(hovering || selected ? 1 : 0)
            .accessibilityLabel(Text("Close Tab"))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background {
            if selected {
                Capsule().fill(Color.primary.opacity(0.11))
            } else if hovering {
                Capsule().fill(Color.primary.opacity(0.05))
            }
        }
        .contentShape(.capsule)
        .onTapGesture { browser.selectedTabId = tab.id }
        .onHover { hovering = $0 }
        .help(tab.sessionId == nil ? tab.pageTitle : "\(browser.tabTitle(tab)) — \(tab.pageTitle)")
        .contextMenu {
            Button("Close Tab", role: .destructive) { browser.closeTab(tab.id) }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A session tab's folder color (or a neutral dot); a globe for the user's own tabs.
private struct BrowserTabMark: View {
    @Environment(BrowserModel.self) private var browser
    let tab: BrowserTab

    var body: some View {
        if let sessionId = tab.sessionId {
            Circle()
                .fill(browser.sessionColor(sessionId) ?? Color.secondary.opacity(0.6))
                .frame(width: 8, height: 8)
        } else {
            Image(systemName: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// ✨ while an agent has used this tab in the last seconds; never blocks anything.
struct AgentSparkle: View {
    let tab: BrowserTab

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let until = tab.agentActiveUntil, until > context.date {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse)
                    .help("An agent is using this tab")
                    .accessibilityLabel(Text("An agent is using this tab"))
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Web view host

/// Shows a tab's web view; when the view goes away the web view returns to the off-screen host.
#if os(macOS)
struct BrowserWebView: NSViewRepresentable {
    let tab: BrowserTab
    @Environment(BrowserModel.self) private var browser

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let webView = tab.webView
        browser.tabDisplayed(tab.id, true)
        guard webView.superview !== view else { return }
        webView.removeFromSuperview()
        webView.frame = view.bounds
        webView.autoresizingMask = [.width, .height]
        view.addSubview(webView)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
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
            guard tab.webView.superview === view else { return }
            browser?.park(tab)
            browser?.tabDisplayed(tab.id, false)
        }
    }
}
#else
struct BrowserWebView: UIViewRepresentable {
    let tab: BrowserTab
    @Environment(BrowserModel.self) private var browser

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ view: UIView, context: Context) {
        browser.tabDisplayed(tab.id, true)
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
            guard tab.webView.superview === view else { return }
            browser?.park(tab)
            browser?.tabDisplayed(tab.id, false)
        }
    }
}
#endif

// MARK: - Window and presentation

/// The browser's own window (Mac, iPad); one shared window, reopened rather than duplicated.
struct BrowserWindow: View {
    static let id = "browser"
    /// The only value the window group is opened with, so it never makes a second browser window.
    static let value = "main"

    @Environment(HappierStore.self) private var store

    var body: some View {
        Group {
            #if os(macOS)
            BrowserView()
                .frame(minWidth: 560, minHeight: 420)
            #else
            NavigationStack { BrowserView() }
            #endif
        }
        // A browser window restored on launch without the main one still needs the store started.
        .task { store.restore() }
        .modifier(BrowserReadiness())
    }
}

/// Once the store is signed in, the browser serves agents (relay slots) and watches sessions to
/// close their tabs when they end; from whichever window comes up first.
struct BrowserReadiness: ViewModifier {
    @Environment(HappierStore.self) private var store
    @Environment(BrowserModel.self) private var browser

    func body(content: Content) -> some View {
        content.task(id: store.phase == .ready) {
            guard store.phase == .ready else { return }
            browser.updateSlots()
            browser.startWatchingSessions()
        }
    }
}

/// The iPhone shows the browser as a sheet owned by whoever opened it.
struct BrowserSheet: ViewModifier {
    @Binding var shown: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $shown) { NavigationStack { BrowserView(inSheet: true) } }
    }
}
