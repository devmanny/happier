import HappierKit
import SwiftUI

/// Settings: the account and relay, machines, notifications and new-session defaults (synced with
/// the account, so the other Happier apps and the CLI follow them), then this device's appearance,
/// voices, linking and the secret key. On the Mac it is also the app's Settings window.
struct SettingsView: View {
    /// In a sheet (iPhone, iPad, the Mac sidebar button) rather than the Mac Settings window.
    var inSheet = true
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @AppStorage(AppHaptics.enabledKey) private var hapticsEnabled = true
    #if os(iOS)
    @AppStorage(IPhoneNavigation.key) private var iPhoneNavigation = IPhoneNavigation.drawer
    #endif
    @State private var revealKey = false
    @State private var linkingDevice = false

    var body: some View {
        Form {
            accountSection
            Section {
                NavigationLink {
                    MachinesView()
                } label: {
                    Label("Machines", systemImage: "desktopcomputer")
                }
            } footer: {
                Text("The computers your sessions run on.")
            }
            Section {
                NavigationLink {
                    AgentsView()
                } label: {
                    Label("Agents", systemImage: "person.2")
                }
            } footer: {
                Text("Named agents with their own description, engine and account. Choose one when you start a session.")
            }
            NotificationSettingsSection()
            Section {
                NavigationLink {
                    DefaultPermissionsView()
                } label: {
                    Label("Default Permissions", systemImage: "hand.raised")
                }
            } header: {
                Text("New Sessions")
            } footer: {
                Text("How much each agent may do without asking, when a new session starts.")
            }
            appearanceSection
            ReadAloudVoices()
            BrowserSettingsSection()
            #if os(iOS)
            Section {
                Picker("iPhone Navigation", selection: $iPhoneNavigation) {
                    ForEach(IPhoneNavigation.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } header: {
                Text("Experimental")
            } footer: {
                Text("Sidebar Drawer slides the sessions in beside the conversation. Standard uses the system's list and back button. This device only.")
            }
            #endif
            Section {
                Button("Link New Device", systemImage: "qrcode.viewfinder") {
                    AppHaptics.light()
                    linkingDevice = true
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("Sign in another phone, tablet or computer: on it, choose Link with Another Device and scan its code from here.")
            }
            securitySection
            Section {
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    AppHaptics.warning()
                    if inSheet { dismiss() }
                    store.signOut()
                }
            }
            Section {
                LabeledContent("Version", value: Self.version)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
        }
        .task { await store.refreshAccountSettings() }
        .sheet(isPresented: $linkingDevice) {
            NavigationStack { LinkNewDeviceView() }
                #if os(macOS)
                .frame(minWidth: 440, minHeight: 360)
                #endif
        }
    }

    private var accountSection: some View {
        Section {
            LabeledContent("Relay") {
                HStack(spacing: 6) {
                    Text(store.server.host() ?? store.server.absoluteString)
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                        .accessibilityLabel(Text(statusText))
                }
            }
            if let accountId = store.accountId {
                LabeledContent("Account ID") {
                    Text(accountId).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .contextMenu {
                    Button("Copy Account ID", systemImage: "doc.on.doc") { MessageClipboard.copy(accountId) }
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("\(statusText). Your sessions sync through this relay.")
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            if let settings = store.accountSettings {
                Picker("Status Position", selection: Binding(get: { settings.statusPosition }, set: { position in
                    AppHaptics.selection()
                    Task { await store.updateAccountSettings { $0.delta(statusPosition: position) } }
                })) {
                    Label("Left", systemImage: "text.alignleft").tag(AccountSettings.StatusPosition.left)
                    Label("Right", systemImage: "text.alignright").tag(AccountSettings.StatusPosition.right)
                }
            }
            #if os(iOS)
            Toggle("Haptics", isOn: $hapticsEnabled)
            #endif
        }
    }

    @ViewBuilder private var securitySection: some View {
        if let secret = store.recoverySecret {
            Section {
                if revealKey {
                    Text(SecretKeyFormat.format(secret))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Button("Copy Secret Key", systemImage: "doc.on.doc") {
                        AppHaptics.confirm()
                        MessageClipboard.copy(SecretKeyFormat.format(secret))
                    }
                } else {
                    Button("Show Secret Key", systemImage: "key") {
                        AppHaptics.light()
                        revealKey = true
                    }
                }
            } header: {
                Text("Security")
            } footer: {
                Text("Your secret key restores this account on any device. Anyone with it can read your sessions; keep it somewhere safe.")
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var statusColor: Color {
        switch store.connection {
        case .online: .green
        case .connecting: .orange
        case .offline: .red
        }
    }

    private var statusText: String {
        switch store.connection {
        case .online: String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        case .offline: String(localized: "Offline")
        }
    }
}

/// Light, dark, or as the system is; this device only.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "happier.appearance"
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

#if os(iOS)
/// How the iPhone lays out sessions and conversation (Settings → Experimental; this device only):
/// the sliding sessions drawer, or the system's list-then-conversation navigation.
enum IPhoneNavigation: String, CaseIterable, Identifiable {
    case drawer, standard
    static let key = "happier.iPhoneNavigation"
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .drawer: "Sidebar Drawer"
        case .standard: "Standard"
        }
    }
}
#endif

/// Applies the chosen theme to a window's content.
struct FollowsAppAppearance: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}

/// Push notifications, from the account's settings: the CLI reads them before it sends each push.
private struct NotificationSettingsSection: View {
    @Environment(HappierStore.self) private var store

    var body: some View {
        Section {
            if let settings = store.accountSettings {
                let notifications = settings.notifications
                toggle("Push Notifications", \.pushEnabled, notifications)
                if notifications.pushEnabled {
                    toggle("When an Agent Finishes", \.ready, notifications)
                    toggle("Permission Requests", \.permissionRequest, notifications)
                    toggle("Questions from Agents", \.userActionRequest, notifications)
                    toggle("Show the Reply in Finished Alerts", \.readyIncludeMessageText, notifications)
                    toggle("Show Details in Requests", \.requestIncludeMessageText, notifications)
                    toggle("Quiet While a Computer Is in Use", \.mutePhoneWhenComputerFocused, notifications)
                }
                Picker("While Happier Is Open", selection: Binding(
                    get: { notifications.foregroundBehavior },
                    set: { value in update { $0.foregroundBehavior = value } }
                )) {
                    Text("Banner and Sound").tag(AccountSettings.ForegroundBehavior.full)
                    Text("Notification Center Only").tag(AccountSettings.ForegroundBehavior.silent)
                    Text("Nothing").tag(AccountSettings.ForegroundBehavior.off)
                }
            } else if let error = store.accountSettingsError {
                Text(error).foregroundStyle(.secondary)
                Button("Try Again") { Task { await store.refreshAccountSettings() } }
            } else {
                HStack {
                    Text("Loading…").foregroundStyle(.secondary)
                    Spacer()
                    HappierSpinner(size: HappierSpinner.mini)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Shared with Happier on your other devices. A conversation already on screen never alerts.")
        }
    }

    private func toggle(_ title: LocalizedStringKey, _ key: WritableKeyPath<AccountSettings.Notifications, Bool>,
                        _ notifications: AccountSettings.Notifications) -> some View {
        Toggle(title, isOn: Binding(get: { notifications[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } }))
    }

    private func update(_ change: @escaping (inout AccountSettings.Notifications) -> Void) {
        AppHaptics.selection()
        Task {
            await store.updateAccountSettings { settings in
                var next = settings.notifications
                change(&next)
                return settings.delta(notifications: next)
            }
        }
    }
}

/// The permission mode each agent's new sessions start in (`sessionDefaultPermissionModeByTargetKey`).
private struct DefaultPermissionsView: View {
    @Environment(HappierStore.self) private var store

    /// Agents in use first, then the rest of the catalog.
    private var agents: [String] {
        var counts: [String: Int] = [:]
        for session in store.sessions.values { if let id = session.agentId { counts[id, default: 0] += 1 } }
        return Agent.ids.enumerated().sorted { a, b in
            let used = (counts[a.element] ?? 0, counts[b.element] ?? 0)
            return used.0 != used.1 ? used.0 > used.1 : a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        Form {
            if let settings = store.accountSettings {
                Section {
                    ForEach(agents, id: \.self) { agentId in
                        Picker(selection: Binding(
                            get: { settings.defaultPermissionMode(for: agentId) },
                            set: { mode in
                                AppHaptics.selection()
                                Task { await store.updateAccountSettings { $0.delta(defaultPermissionMode: mode, for: agentId) } }
                            }
                        )) {
                            Text("Not Set").tag(PermissionMode?.none)
                            ForEach(PermissionMode.allCases, id: \.self) { mode in
                                Text(mode.label(agentId: agentId)).tag(PermissionMode?.some(mode))
                            }
                        } label: {
                            HStack(spacing: 10) {
                                AgentAvatar(agentId: agentId, size: 24)
                                Text(Agent.displayNames[agentId] ?? agentId)
                            }
                        }
                    }
                } footer: {
                    Text("Shared with Happier on your other devices. Agents that are not set start in YOLO here; you can still change the mode for each session.")
                }
            } else if let error = store.accountSettingsError {
                Text(error).foregroundStyle(.secondary)
            } else {
                HappierSpinner(size: HappierSpinner.mini)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Default Permissions")
        .task { if store.accountSettings == nil { await store.refreshAccountSettings() } }
    }
}
