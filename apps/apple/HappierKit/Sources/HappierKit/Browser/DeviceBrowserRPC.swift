import Foundation

/// Integrated browser driven by session agents. Mirrors
/// `packages/protocol/src/deviceBrowser/deviceBrowserRpc.ts` (the canonical contract).
///
/// The app's user-scoped socket registers `<machineId>:device.browser.v1.<slot>` for each machine it
/// knows; a session on that machine calls it like any machine RPC, so params and result use that
/// machine's content key (plain machines stay plain). Slots are last-registration-wins on the
/// relay; the CLI tries `focused` first and `host` only when nobody serves `focused`.
public enum DeviceBrowserSlot: String, CaseIterable, Sendable, Hashable {
    /// The device whose browser UI the user opened most recently.
    case focused
    /// An always-connected Mac app.
    case host
}

public enum DeviceBrowserErrorCode: String, Sendable {
    case invalidRequest = "invalid_request"
    case disabled
    case tabNotFound = "tab_not_found"
    case elementNotFound = "element_not_found"
    case navigationFailed = "navigation_failed"
    case scriptError = "script_error"
    case timeout
    case unavailable
}

public struct DeviceBrowserError: Error, Equatable, Sendable {
    public let code: DeviceBrowserErrorCode
    public let message: String
    public init(_ code: DeviceBrowserErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum DeviceBrowserElementTarget: Equatable, Sendable {
    case ref(String)
    case selector(String)
}

public enum DeviceBrowserWaitCondition: Equatable, Sendable {
    case selector(String)
    case text(String)
    case urlIncludes(String)
    case duration(Int)
}

public enum DeviceBrowserRequest: Equatable, Sendable {
    public enum NavigationAction: String, Sendable { case go, back, forward, reload }
    public enum TabsAction: String, Sendable { case list, new, select, close }
    public enum ScrollEdge: String, Sendable { case top, bottom }

    case status
    case navigate(tabId: String?, url: String?, action: NavigationAction, newTab: Bool)
    case screenshot(tabId: String?, fullPage: Bool)
    case snapshot(tabId: String?, maxChars: Int?)
    case click(tabId: String?, target: DeviceBrowserElementTarget)
    case type(tabId: String?, target: DeviceBrowserElementTarget?, text: String, clear: Bool, submit: Bool)
    case scroll(tabId: String?, target: DeviceBrowserElementTarget?, deltaX: Double, deltaY: Double, to: ScrollEdge?)
    case evaluate(tabId: String?, script: String)
    case wait(tabId: String?, condition: DeviceBrowserWaitCondition, timeoutMs: Int?)
    case tabs(action: TabsAction, tabId: String?, url: String?)

    /// The protocol bounds one wait step (`DEVICE_BROWSER_MAX_WAIT_MS`) inside the relay's 300 s forward.
    public static let maxWaitMs = 120_000

    public var tabId: String? {
        switch self {
        case .status: nil
        case .navigate(let tabId, _, _, _), .screenshot(let tabId, _), .snapshot(let tabId, _), .click(let tabId, _),
             .type(let tabId, _, _, _, _), .scroll(let tabId, _, _, _, _), .evaluate(let tabId, _), .wait(let tabId, _, _):
            tabId
        case .tabs(_, let tabId, _): tabId
        }
    }

    public init(json: JSONValue) throws(DeviceBrowserError) {
        guard let object = json.objectValue, let op = object["op"]?.stringValue else { throw Self.invalid("op is required") }
        func string(_ key: String) throws(DeviceBrowserError) -> String? {
            guard let value = object[key], !value.isNull else { return nil }
            guard let text = value.stringValue else { throw Self.invalid("\(key) must be a string") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Self.invalid("\(key) must not be empty") }
            return trimmed
        }
        func bool(_ key: String) -> Bool { object[key]?.boolValue ?? false }
        func number(_ key: String) -> Double? { object[key]?.doubleValue }
        func positiveInt(_ key: String, max: Int? = nil) throws(DeviceBrowserError) -> Int? {
            guard let value = number(key) else { return nil }
            guard value > 0, value.rounded() == value else { throw Self.invalid("\(key) must be a positive integer") }
            if let max, value > Double(max) { throw Self.invalid("\(key) must be at most \(max)") }
            return Int(value)
        }
        func target(required: Bool) throws(DeviceBrowserError) -> DeviceBrowserElementTarget? {
            let ref = try string("ref"), selector = try string("selector")
            switch (ref, selector) {
            case (let ref?, nil): return .ref(ref)
            case (nil, let selector?): return .selector(selector)
            case (nil, nil):
                if required { throw Self.invalid("Provide exactly one of ref or selector") }
                return nil
            default: throw Self.invalid("Provide exactly one of ref or selector")
            }
        }
        let tabId = try string("tabId")
        switch op {
        case "status":
            self = .status
        case "navigate":
            guard let action = NavigationAction(rawValue: try string("action") ?? "go") else { throw Self.invalid("Unknown action") }
            let url = try string("url")
            if action == .go, url == nil { throw Self.invalid("url is required to navigate") }
            self = .navigate(tabId: tabId, url: url, action: action, newTab: bool("newTab"))
        case "screenshot":
            self = .screenshot(tabId: tabId, fullPage: bool("fullPage"))
        case "snapshot":
            self = .snapshot(tabId: tabId, maxChars: try positiveInt("maxChars"))
        case "click":
            self = .click(tabId: tabId, target: try target(required: true)!)
        case "type":
            guard let text = object["text"]?.stringValue else { throw Self.invalid("text is required") }
            self = .type(tabId: tabId, target: try target(required: false), text: text, clear: bool("clear"), submit: bool("submit"))
        case "scroll":
            let edge = try string("to")
            guard edge == nil || ScrollEdge(rawValue: edge!) != nil else { throw Self.invalid("to must be top or bottom") }
            self = .scroll(tabId: tabId, target: try target(required: false), deltaX: number("deltaX") ?? 0,
                           deltaY: number("deltaY") ?? 0, to: edge.flatMap(ScrollEdge.init(rawValue:)))
        case "evaluate":
            guard let script = object["script"]?.stringValue, !script.isEmpty else { throw Self.invalid("script is required") }
            self = .evaluate(tabId: tabId, script: script)
        case "wait":
            let timeout = try positiveInt("timeoutMs", max: Self.maxWaitMs)
            let condition: DeviceBrowserWaitCondition
            if let selector = try string("selector") { condition = .selector(selector) }
            else if let text = try string("text") { condition = .text(text) }
            else if let url = try string("urlIncludes") { condition = .urlIncludes(url) }
            else if let duration = try positiveInt("durationMs", max: Self.maxWaitMs) { condition = .duration(duration) }
            else { throw Self.invalid("Provide selector, text, urlIncludes or durationMs") }
            self = .wait(tabId: tabId, condition: condition, timeoutMs: timeout)
        case "tabs":
            guard let action = TabsAction(rawValue: try string("action") ?? "") else { throw Self.invalid("Unknown tabs action") }
            if action == .select || action == .close, tabId == nil { throw Self.invalid("tabId is required") }
            self = .tabs(action: action, tabId: tabId, url: try string("url"))
        default:
            throw Self.invalid("Unknown operation \(op)")
        }
    }

    private static func invalid(_ message: String) -> DeviceBrowserError { .init(.invalidRequest, message) }
}

public struct DeviceBrowserDevice: Equatable, Sendable {
    public enum Platform: String, Sendable { case ios, ipados, macos }
    public let name: String
    public let platform: Platform
    public init(name: String, platform: Platform) {
        self.name = name
        self.platform = platform
    }
}

public struct DeviceBrowserTab: Equatable, Sendable {
    public let id: String
    public let url: String
    public let title: String
    /// The calling session's current tab (not what the user is looking at).
    public let selected: Bool
    public let loading: Bool
    public let sessionTitle: String?
    public init(id: String, url: String, title: String, selected: Bool, loading: Bool, sessionTitle: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.selected = selected
        self.loading = loading
        self.sessionTitle = sessionTitle
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "url": .string(url), "title": .string(title), "selected": .bool(selected), "loading": .bool(loading),
        ]
        if let sessionTitle { object["sessionTitle"] = .string(sessionTitle) }
        return .object(object)
    }
}

public struct DeviceBrowserImage: Equatable, Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
    public init(png: Data, width: Int, height: Int) {
        self.png = png
        self.width = width
        self.height = height
    }
}

public struct DeviceBrowserResult: Equatable, Sendable {
    public var device: DeviceBrowserDevice
    public var tab: DeviceBrowserTab?
    public var tabs: [DeviceBrowserTab]?
    public var text: String?
    public var truncated: Bool?
    public var value: JSONValue?
    public var image: DeviceBrowserImage?

    public init(device: DeviceBrowserDevice, tab: DeviceBrowserTab? = nil, tabs: [DeviceBrowserTab]? = nil, text: String? = nil,
                truncated: Bool? = nil, value: JSONValue? = nil, image: DeviceBrowserImage? = nil) {
        self.device = device
        self.tab = tab
        self.tabs = tabs
        self.text = text
        self.truncated = truncated
        self.value = value
        self.image = image
    }
}

public enum DeviceBrowserResponse: Equatable, Sendable {
    case success(DeviceBrowserResult)
    case failure(DeviceBrowserError)

    public var json: JSONValue {
        switch self {
        case .failure(let error):
            return ["ok": false, "errorCode": .string(error.code.rawValue), "error": .string(error.message)]
        case .success(let result):
            var object: [String: JSONValue] = [
                "ok": true,
                "device": ["name": .string(result.device.name), "platform": .string(result.device.platform.rawValue)],
            ]
            if let tab = result.tab { object["tab"] = tab.json }
            if let tabs = result.tabs { object["tabs"] = .array(tabs.map(\.json)) }
            if let text = result.text { object["text"] = .string(text) }
            if let truncated = result.truncated { object["truncated"] = .bool(truncated) }
            if let value = result.value { object["value"] = value }
            if let image = result.image {
                object["image"] = ["mimeType": "image/png", "data": .string(image.png.base64EncodedString()),
                                   "width": .number(Double(image.width)), "height": .number(Double(image.height))]
            }
            return .object(object)
        }
    }
}

/// Executes browser operations; implemented by the app's WebKit browser.
@MainActor public protocol DeviceBrowserHost: AnyObject {
    func perform(_ command: DeviceBrowserCommand) async -> DeviceBrowserResponse
}

public enum DeviceBrowserRPC {
    static let methodPrefix = "device.browser.v1."

    public static func method(machineId: String, slot: DeviceBrowserSlot) -> String {
        "\(machineId):\(methodPrefix)\(slot.rawValue)"
    }

    public static func parse(method: String) -> (machineId: String, slot: DeviceBrowserSlot)? {
        guard let colon = method.firstIndex(of: ":") else { return nil }
        let machineId = String(method[..<colon])
        let suffix = method[method.index(after: colon)...]
        guard !machineId.isEmpty, suffix.hasPrefix(methodPrefix),
              let slot = DeviceBrowserSlot(rawValue: String(suffix.dropFirst(methodPrefix.count))) else { return nil }
        return (machineId, slot)
    }

    /// Every method this device should serve, in a stable order.
    public static func methods(machineIds: [String], slots: Set<DeviceBrowserSlot>) -> [String] {
        machineIds.flatMap { id in DeviceBrowserSlot.allCases.filter(slots.contains).map { method(machineId: id, slot: $0) } }
    }

    /// Decrypts, validates and runs one request, and encrypts the answer the way machine RPC results
    /// travel (`base64(cipher(json))`, or bare JSON for plain machines).
    @MainActor public static func respond(params: JSONValue, cipher: ContentCipher?, host: DeviceBrowserHost) async -> JSONValue {
        let response: DeviceBrowserResponse
        do {
            let decoded: JSONValue
            if let cipher {
                guard let text = params.stringValue else { throw DeviceBrowserError(.invalidRequest, "Expected encrypted params") }
                do { decoded = try cipher.decryptBase64(text) } catch { throw DeviceBrowserError(.invalidRequest, "Undecryptable params") }
            } else {
                decoded = params
            }
            response = await host.perform(try DeviceBrowserCommand(json: decoded))
        } catch let error as DeviceBrowserError {
            response = .failure(error)
        } catch {
            response = .failure(.init(.unavailable, String(describing: error)))
        }
        guard let cipher else { return response.json }
        return (try? cipher.encryptBase64(response.json)).map(JSONValue.string) ?? .null
    }
    /// Answers one relay `rpc-request` payload (`{method, params, requestId?}`), or nil when the
    /// method is not a browser method this app knows. A slot the app does not serve right now, or
    /// a disabled browser, answers `disabled` so a stale registration never runs anything.
    @MainActor public static func reply(to payload: JSONValue, machines: [Machine], slots: Set<DeviceBrowserSlot>,
                                        host: DeviceBrowserHost?) async -> JSONValue? {
        guard let method = payload["method"]?.stringValue, let target = parse(method: method) else { return nil }
        guard let machine = machines.first(where: { $0.id == target.machineId }) else {
            return DeviceBrowserResponse.failure(.init(.unavailable, "This device does not know machine \(target.machineId)")).json
        }
        guard let host, slots.contains(target.slot) else {
            let failure = DeviceBrowserResponse.failure(.init(.disabled, "The integrated browser is not available on this device"))
            guard let cipher = machine.cipher else { return failure.json }
            return (try? cipher.encryptBase64(failure.json)).map(JSONValue.string) ?? .null
        }
        return await respond(params: payload["params"] ?? .null, cipher: machine.cipher, host: host)
    }
}
