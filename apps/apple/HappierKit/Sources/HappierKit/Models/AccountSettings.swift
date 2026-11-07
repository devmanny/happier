import Foundation

/// The Account's synced settings document (`/v2/account/settings`), shared with the React Native
/// app and read by the CLI. Writes replace only the top-level keys this app owns and keep every
/// other key as it is, like `accountSettingsRawDeltaMerge.ts`.
public struct AccountSettings: Sendable, Equatable {
    public enum ForegroundBehavior: String, Sendable, CaseIterable { case full, silent, off }

    /// `notificationsSettingsV1` (`accountSettings.ts`): everything on unless turned off.
    public struct Notifications: Sendable, Equatable {
        public var pushEnabled = true
        public var ready = true
        public var readyIncludeMessageText = true
        public var requestIncludeMessageText = true
        public var permissionRequest = true
        public var userActionRequest = true
        /// Hold phone pushes while a computer running Happier is in use.
        public var mutePhoneWhenComputerFocused = false
        /// How a push looks while the app is open on this phone.
        public var foregroundBehavior = ForegroundBehavior.full

        public init() {}
    }

    public private(set) var values: [String: JSONValue]

    public init(values: [String: JSONValue]) {
        self.values = values
    }

    public func merging(_ delta: [String: JSONValue]) -> AccountSettings {
        AccountSettings(values: values.merging(delta) { $1 })
    }

    // MARK: Notifications

    private static let notificationsKey = "notificationsSettingsV1"
    private static let channelsKey = "notificationChannelsV1"
    private static let pushChannelId = "builtin:expo_push"

    public var notifications: Notifications {
        let stored = values[Self.notificationsKey]
        var result = Notifications()
        func flag(_ key: String) -> Bool { stored?[key]?.boolValue ?? true }
        result.pushEnabled = flag("pushEnabled")
        result.ready = flag("ready")
        result.readyIncludeMessageText = flag("readyIncludeMessageText")
        result.requestIncludeMessageText = flag("requestIncludeMessageText")
        result.permissionRequest = flag("permissionRequest")
        result.userActionRequest = flag("userActionRequest")
        result.mutePhoneWhenComputerFocused = stored?["mutePhoneWhenComputerFocused"]?.boolValue ?? false
        result.foregroundBehavior = stored?["foregroundBehavior"]?.stringValue.flatMap(ForegroundBehavior.init(rawValue:)) ?? .full
        return result
    }

    /// Both notification keys (`buildNotificationSettingsDelta`): the CLI delivers through
    /// `notificationChannelsV1` whenever it exists, so the phone-push channel is rebuilt from the
    /// toggles while webhook channels stay as they are.
    public func delta(notifications: Notifications) -> [String: JSONValue] {
        var stored = values[Self.notificationsKey]?.objectValue ?? [:]
        stored["v"] = 1
        stored["pushEnabled"] = .bool(notifications.pushEnabled)
        stored["ready"] = .bool(notifications.ready)
        stored["readyIncludeMessageText"] = .bool(notifications.readyIncludeMessageText)
        stored["requestIncludeMessageText"] = .bool(notifications.requestIncludeMessageText)
        stored["permissionRequest"] = .bool(notifications.permissionRequest)
        stored["userActionRequest"] = .bool(notifications.userActionRequest)
        stored["mutePhoneWhenComputerFocused"] = .bool(notifications.mutePhoneWhenComputerFocused)
        stored["foregroundBehavior"] = .string(notifications.foregroundBehavior.rawValue)
        func on(_ key: String) -> JSONValue { .bool(stored[key]?.boolValue != false) }
        let pushChannel: JSONValue = [
            "v": 1, "id": .string(Self.pushChannelId), "kind": "expo_push", "enabled": on("pushEnabled"),
            "topics": [
                "ready": on("ready"), "permissionRequest": on("permissionRequest"), "userActionRequest": on("userActionRequest"),
                "connectedServiceAccountSwitch": on("connectedServiceAccountSwitch"),
                "connectedServiceQuotaBlocked": on("connectedServiceQuotaBlocked"),
                "connectedServiceQuotaRecovered": on("connectedServiceQuotaRecovered"),
            ],
            "readyIncludeMessageText": on("readyIncludeMessageText"),
            "requestIncludeMessageText": on("requestIncludeMessageText"),
        ]
        let others = (values[Self.channelsKey]?.arrayValue ?? []).filter { $0["id"]?.stringValue != Self.pushChannelId }
        return [Self.notificationsKey: .object(stored), Self.channelsKey: .array([pushChannel] + others)]
    }

    // MARK: Default permission mode for new sessions

    private static let permissionModesKey = "sessionDefaultPermissionModeByTargetKey"

    /// The mode new sessions with this agent start in, when the user chose one
    /// (`sessionDefaultPermissionModeByTargetKey["agent:<id>"]`).
    public func defaultPermissionMode(for agentId: String) -> PermissionMode? {
        values[Self.permissionModesKey]?["agent:\(agentId)"]?.stringValue.map(PermissionMode.init(stored:))
    }

    public func delta(defaultPermissionMode mode: PermissionMode?, for agentId: String) -> [String: JSONValue] {
        var map = values[Self.permissionModesKey]?.objectValue ?? [:]
        map["agent:\(agentId)"] = mode.map { .string($0.rawValue) }
        return [Self.permissionModesKey: .object(map)]
    }

    // MARK: Composer status line

    /// Where the conversation's status line (agent and state) sits above the composer: left, where
    /// "Online" always was, or right, above the mic. Native app only; other apps keep the key.
    public enum StatusPosition: String, CaseIterable, Sendable { case left, right }

    static let statusPositionKey = "nativeComposerStatusPositionV1"

    public var statusPosition: StatusPosition {
        values[Self.statusPositionKey]?.stringValue.flatMap(StatusPosition.init(rawValue:)) ?? .left
    }

    public func delta(statusPosition position: StatusPosition) -> [String: JSONValue] {
        [Self.statusPositionKey: .string(position.rawValue)]
    }

    // MARK: Folder colors

    /// A project folder's color, so each window shows which project it's in (native app only;
    /// other apps keep the key as it is).
    public enum FolderColor: String, CaseIterable, Sendable {
        case red, orange, yellow, green, teal, blue, indigo, purple, pink, gray
    }

    static let folderColorsKey = "nativeFolderColorsV1"

    public func folderColor(for path: String) -> FolderColor? {
        values[Self.folderColorsKey]?[Self.folderKey(path)]?.stringValue.flatMap(FolderColor.init(rawValue:))
    }

    public func delta(folderColor color: FolderColor?, for path: String) -> [String: JSONValue] {
        var map = values[Self.folderColorsKey]?.objectValue ?? [:]
        map[Self.folderKey(path)] = color.map { .string($0.rawValue) }
        return [Self.folderColorsKey: .object(map)]
    }

    private static func folderKey(_ path: String) -> String {
        var key = path.trimmingCharacters(in: .whitespaces)
        while key.count > 1, key.hasSuffix("/") || key.hasSuffix("\\") { key.removeLast() }
        return key
    }
}

/// The settings document as the relay stores it: `{t:'encrypted', c}` sealed for the account's
/// devices (kind `account_settings`), or `{t:'plain', v}` on plain accounts.
public enum AccountSettingsContent {
    /// The document, `[:]` when there is none yet, nil when this device can't read it.
    public static func open(_ content: JSONValue?, keys: AccountKeys?) -> [String: JSONValue]? {
        guard let content, !content.isNull else { return [:] }
        switch content["t"]?.stringValue {
        case "plain":
            return content["v"]?.objectValue ?? (content["v"]?.isNull == true ? [:] : nil)
        case "encrypted":
            guard let keys, let ciphertext = content["c"]?.stringValue else { return nil }
            let opened = AccountScopedBlob.open(ciphertext, kind: .accountSettings, machineKey: keys.content.secretKey)
                ?? AccountScopedBlob.openHeaderless(ciphertext, keys: [keys.content.secretKey] + (keys.masterSecret.map { [$0] } ?? []))
            return opened?.objectValue
        default:
            return nil
        }
    }

    public static func seal(_ values: [String: JSONValue], keys: AccountKeys?, plain: Bool) throws -> JSONValue {
        if plain { return ["t": "plain", "v": .object(values)] }
        guard let keys else { throw HappierCrypto.Failure.invalidLength }
        return ["t": "encrypted", "c": .string(try AccountScopedBlob.seal(.object(values), kind: .accountSettings, machineKey: keys.content.secretKey))]
    }
}
