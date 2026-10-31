import Foundation
import HappierKit
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Agent operations on the integrated browser (`browser_*` MCP tools of a session).
extension BrowserModel: DeviceBrowserHost {
    /// Default snapshot budget: keeps one page read within an agent's context window.
    static let defaultSnapshotChars = 40_000
    /// Navigation answers before the CLI's 60 s call budget (`resolveDeviceBrowserTimeoutMs`).
    static let navigationTimeout: Duration = .seconds(45)
    static let defaultWaitMs = 10_000
    /// Largest full-page capture, in points; bounds the bitmap WebKit is asked to render.
    static let maxFullPageHeight: CGFloat = 16_000

    func perform(_ request: DeviceBrowserRequest) async -> DeviceBrowserResponse {
        guard agentAccessEnabled else {
            return .failure(.init(.disabled, "Agent access to the browser is turned off in Happier Settings."))
        }
        noteAgentActivity()
        defer { noteAgentActivity() }
        do {
            return .success(try await run(request))
        } catch let error as DeviceBrowserError {
            return .failure(error)
        } catch {
            return .failure(.init(.scriptError, Self.message(error)))
        }
    }

    private func run(_ request: DeviceBrowserRequest) async throws -> DeviceBrowserResult {
        switch request {
        case .status:
            return result(tab: selectedTab)

        case .navigate(let tabId, let url, let action, let newTab):
            let tab: BrowserTab
            if newTab {
                tab = self.newTab()
            } else {
                tab = try self.tab(tabId, createIfNone: true)
            }
            switch action {
            case .go:
                guard let url = url.flatMap(Self.url(fromTyped:)) else { throw DeviceBrowserError(.invalidRequest, "Invalid URL") }
                tab.webView.load(URLRequest(url: url))
            case .back:
                guard tab.webView.goBack() != nil else { throw DeviceBrowserError(.navigationFailed, "No page to go back to") }
            case .forward:
                guard tab.webView.goForward() != nil else { throw DeviceBrowserError(.navigationFailed, "No page to go forward to") }
            case .reload:
                tab.webView.reload()
            }
            try await settle(tab)
            return try await settledResult(tab)

        case .screenshot(let tabId, let fullPage):
            let tab = try self.tab(tabId)
            return result(tab: tab, image: try await screenshot(tab, fullPage: fullPage))

        case .snapshot(let tabId, let maxChars):
            let tab = try self.tab(tabId)
            let value = try await call(BrowserScripts.snapshot, in: tab, ["maxChars": maxChars ?? Self.defaultSnapshotChars])
            let header = "Page: \(tab.title)\nURL: \(tab.webView.url?.absoluteString ?? "")\n\n"
            return result(tab: tab, text: header + (value?["text"]?.stringValue ?? ""), truncated: value?["truncated"]?.boolValue)

        case .click(let tabId, let target):
            let tab = try self.tab(tabId)
            let value = try await call(BrowserScripts.click, in: tab, Self.arguments(target))
            try Self.checkElement(value, target)
            try? await Task.sleep(for: .milliseconds(300))
            await settleIfLoading(tab)
            return result(tab: tab, value: value)

        case .type(let tabId, let target, let text, let clear, let submit):
            let tab = try self.tab(tabId)
            var arguments = Self.arguments(target)
            arguments["text"] = text
            arguments["clear"] = clear
            arguments["submit"] = submit
            let value = try await call(BrowserScripts.type, in: tab, arguments)
            if value?["error"]?.stringValue == "not_editable" {
                throw DeviceBrowserError(.elementNotFound, "The element does not accept text")
            }
            try Self.checkElement(value, target)
            if submit {
                try? await Task.sleep(for: .milliseconds(300))
                await settleIfLoading(tab)
            }
            return result(tab: tab, value: value)

        case .scroll(let tabId, let target, let deltaX, let deltaY, let edge):
            let tab = try self.tab(tabId)
            var arguments = Self.arguments(target)
            arguments["deltaX"] = deltaX
            arguments["deltaY"] = deltaY
            arguments["to"] = edge?.rawValue ?? ""
            let value = try await call(BrowserScripts.scroll, in: tab, arguments)
            try Self.checkElement(value, target)
            return result(tab: tab, value: value)

        case .evaluate(let tabId, let script):
            let tab = try self.tab(tabId)
            return result(tab: tab, value: try await evaluate(script, in: tab))

        case .wait(let tabId, let condition, let timeoutMs):
            let tab = try self.tab(tabId)
            try await wait(for: condition, in: tab, timeoutMs: timeoutMs ?? Self.defaultWaitMs)
            return result(tab: tab)

        case .tabs(let action, let tabId, let url):
            switch action {
            case .list:
                break
            case .new:
                let tab = newTab(url: url.flatMap(Self.url(fromTyped:)))
                if url != nil {
                    try await settle(tab)
                    return try await settledResult(tab)
                }
            case .select:
                selectedTabId = try self.tab(tabId).id
            case .close:
                closeTab(try self.tab(tabId).id)
            }
            return result(tab: selectedTab)
        }
    }

    // MARK: - Helpers

    private func tab(_ id: String?, createIfNone: Bool = false) throws -> BrowserTab {
        if let id {
            guard let tab = tabs.first(where: { $0.id == id }) else { throw DeviceBrowserError(.tabNotFound, "No tab \(id)") }
            return tab
        }
        if let tab = selectedTab { return tab }
        if createIfNone { return newTab() }
        throw DeviceBrowserError(.tabNotFound, "No open tab; navigate to a URL first")
    }

    private func info(_ tab: BrowserTab, title: String? = nil) -> DeviceBrowserTab {
        .init(id: tab.id, url: tab.webView.url?.absoluteString ?? "", title: title ?? tab.webView.title ?? "",
              selected: tab.id == selectedTab?.id, loading: tab.webView.isLoading)
    }

    /// Right after a load WebKit may not have published the title yet; the page itself has it.
    private func settledResult(_ tab: BrowserTab) async throws -> DeviceBrowserResult {
        var result = result(tab: tab)
        if tab.webView.title?.isEmpty ?? true, let title = try? await call("return document.title", in: tab)?.stringValue {
            result.tab = info(tab, title: title)
            result.tabs = tabs.map { $0.id == tab.id ? info($0, title: title) : info($0) }
        }
        return result
    }

    private func result(tab: BrowserTab?, text: String? = nil, truncated: Bool? = nil, value: JSONValue? = nil,
                        image: DeviceBrowserImage? = nil) -> DeviceBrowserResult {
        .init(device: Self.device, tab: tab.map { info($0) }, tabs: tabs.map { info($0) }, text: text, truncated: truncated, value: value, image: image)
    }

    /// Waits for the started navigation to finish (or fail), bounded by `navigationTimeout`.
    /// Same-document navigations (hash, pushState) never report a finish: once the view stops
    /// loading for two consecutive checks, the wait ends too. A timeout keeps whatever loaded.
    private func settle(_ tab: BrowserTab) async throws {
        let webView = tab.webView
        let watcher = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + Self.navigationTimeout
            var idleChecks = 0
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                idleChecks = webView.isLoading ? 0 : idleChecks + 1
                if idleChecks >= 2 { break }
            }
            guard !Task.isCancelled else { return }
            self?.finishWaiting(webView)
        }
        defer { watcher.cancel() }
        if let error = await waitForNavigation(of: webView) {
            throw DeviceBrowserError(.navigationFailed, Self.message(error))
        }
    }

    private func settleIfLoading(_ tab: BrowserTab) async {
        guard tab.webView.isLoading else { return }
        try? await settle(tab)
    }

    private func finishWaiting(_ webView: WKWebView) {
        for waiter in navigationWaiters.removeValue(forKey: ObjectIdentifier(webView)) ?? [] { waiter.resume(returning: nil) }
    }

    private func call(_ body: String, in tab: BrowserTab, _ arguments: [String: Any] = [:],
                      world: WKContentWorld = .defaultClient) async throws -> JSONValue? {
        do {
            let value = try await tab.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
            return try value.map(Self.json(from:))
        } catch let error as DeviceBrowserError {
            throw error
        } catch {
            throw DeviceBrowserError(.scriptError, Self.message(error))
        }
    }

    /// The agent's script as a function body; a bare expression (`document.title`) is returned as is.
    private func evaluate(_ script: String, in tab: BrowserTab) async throws -> JSONValue? {
        do {
            return try await call("return (\n\(script)\n);", in: tab, world: .page)
        } catch let error as DeviceBrowserError where error.message.contains("SyntaxError") {
            return try await call(script, in: tab, world: .page)
        }
    }

    private func wait(for condition: DeviceBrowserWaitCondition, in tab: BrowserTab, timeoutMs: Int) async throws {
        if case .duration(let ms) = condition {
            try? await Task.sleep(for: .milliseconds(ms))
            return
        }
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline {
            switch condition {
            case .urlIncludes(let part):
                if tab.webView.url?.absoluteString.contains(part) == true { return }
            case .selector(let selector):
                if try await call(BrowserScripts.waitCondition, in: tab, ["selector": selector, "text": ""])?.boolValue == true { return }
            case .text(let text):
                if try await call(BrowserScripts.waitCondition, in: tab, ["selector": "", "text": text])?.boolValue == true { return }
            case .duration:
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw DeviceBrowserError(.timeout, "The condition did not hold within \(timeoutMs) ms")
    }

    private func screenshot(_ tab: BrowserTab, fullPage: Bool) async throws -> DeviceBrowserImage {
        let webView = tab.webView
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        var restoreFrame: CGRect?
        if fullPage, let size = try await call(BrowserScripts.pageSize, in: tab),
           let height = size["height"]?.doubleValue, CGFloat(height) > webView.bounds.height {
            // WebKit renders only what the view covers: grow it to the page, capture, put it back.
            restoreFrame = webView.frame
            var frame = webView.frame
            frame.size.height = min(CGFloat(height), Self.maxFullPageHeight)
            webView.frame = frame
            try? await Task.sleep(for: .milliseconds(250))
        }
        defer { if let restoreFrame { webView.frame = restoreFrame } }
        // One pixel per point keeps captures light for the agent's context.
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        let image = try await webView.takeSnapshot(configuration: configuration)
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw DeviceBrowserError(.unavailable, "Could not encode the screenshot")
        }
        return .init(png: png, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        #else
        // Snapshots come at the screen scale (3x on iPhone); redraw at one pixel per point.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let flattened = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
        guard let png = flattened.pngData() else { throw DeviceBrowserError(.unavailable, "Could not encode the screenshot") }
        return .init(png: png, width: Int(flattened.size.width), height: Int(flattened.size.height))
        #endif
    }

    private static func arguments(_ target: DeviceBrowserElementTarget?) -> [String: Any] {
        switch target {
        case .ref(let ref): ["ref": ref, "selector": ""]
        case .selector(let selector): ["ref": "", "selector": selector]
        case nil: ["ref": "", "selector": ""]
        }
    }

    private static func checkElement(_ value: JSONValue?, _ target: DeviceBrowserElementTarget?) throws {
        guard value?["error"]?.stringValue == "not_found" else { return }
        let what = switch target {
        case .ref(let ref): "ref \(ref) (take a new browser_snapshot)"
        case .selector(let selector): "selector \(selector)"
        case nil: "a focused element"
        }
        throw DeviceBrowserError(.elementNotFound, "No element for \(what)")
    }

    /// WebKit's script results (Foundation values) as JSON.
    static func json(from value: Any) throws -> JSONValue {
        switch value {
        case let string as String: return .string(string)
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]: return .array(try array.map(json(from:)))
        case let dictionary as [String: Any]: return .object(try dictionary.mapValues(json(from:)))
        case is NSNull: return .null
        case let date as Date: return .string(ISO8601DateFormatter().string(from: date))
        default: throw DeviceBrowserError(.scriptError, "The result is not JSON-serializable (\(type(of: value)))")
        }
    }

    static func message(_ error: Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String { return message }
        return nsError.localizedDescription
    }
}
