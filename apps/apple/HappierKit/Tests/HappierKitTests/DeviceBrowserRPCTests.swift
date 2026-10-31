import Foundation
import Testing
@testable import HappierKit

/// Integrated browser RPC (`packages/protocol/src/deviceBrowser/deviceBrowserRpc.ts`): the app serves
/// `<machineId>:device.browser.v1.<slot>` and answers with the machine's content key.
@Suite struct DeviceBrowserRPCTests {
    @MainActor final class FakeHost: DeviceBrowserHost {
        var received: [DeviceBrowserRequest] = []
        var sessions: [String] = []
        func perform(_ command: DeviceBrowserCommand) async -> DeviceBrowserResponse {
            received.append(command.request)
            sessions.append(command.sessionId)
            return .success(.init(device: .init(name: "Mac mini", platform: .macos),
                                  tabs: [.init(id: "t1", url: "https://example.com/", title: "Example", selected: true, loading: false)]))
        }
    }

    @Test func namesMethodsUnderTheMachineNamespace() {
        #expect(DeviceBrowserRPC.method(machineId: "m1", slot: .focused) == "m1:device.browser.v1.focused")
        #expect(DeviceBrowserRPC.parse(method: "m1:device.browser.v1.host")?.machineId == "m1")
        #expect(DeviceBrowserRPC.parse(method: "m1:device.browser.v1.host")?.slot == .host)
        #expect(DeviceBrowserRPC.parse(method: "m1:spawn-happy-session") == nil)
        #expect(DeviceBrowserRPC.parse(method: "m1:device.browser.v1.other") == nil)
        #expect(DeviceBrowserRPC.methods(machineIds: ["m1", "m2"], slots: [.host]) == ["m1:device.browser.v1.host", "m2:device.browser.v1.host"])
    }

    @Test func decodesTheSameOperationsTheContractAccepts() throws {
        #expect(try DeviceBrowserRequest(json: ["op": "navigate", "url": "https://a.dev", "newTab": true])
            == .navigate(tabId: nil, url: "https://a.dev", action: .go, newTab: true))
        #expect(try DeviceBrowserRequest(json: ["op": "navigate", "action": "back"]) == .navigate(tabId: nil, url: nil, action: .back, newTab: false))
        #expect(try DeviceBrowserRequest(json: ["op": "click", "ref": "e3"]) == .click(tabId: nil, target: .ref("e3")))
        #expect(try DeviceBrowserRequest(json: ["op": "type", "text": "hola", "submit": true])
            == .type(tabId: nil, target: nil, text: "hola", clear: false, submit: true))
        #expect(try DeviceBrowserRequest(json: ["op": "wait", "text": "Listo", "timeoutMs": 5000])
            == .wait(tabId: nil, condition: .text("Listo"), timeoutMs: 5000))
        #expect(try DeviceBrowserRequest(json: ["op": "tabs", "action": "select", "tabId": "t1"]) == .tabs(action: .select, tabId: "t1", url: nil))
        for invalid: JSONValue in [
            ["op": "navigate"], ["op": "click"], ["op": "click", "ref": "e1", "selector": "a"], ["op": "type", "ref": "e1"],
            ["op": "wait", "timeoutMs": 5000], ["op": "wait", "durationMs": 10, "timeoutMs": 999_999],
            ["op": "tabs", "action": "close"], ["op": "nope"],
        ] {
            #expect(throws: DeviceBrowserError.self) { try DeviceBrowserRequest(json: invalid) }
        }
    }

    @Test @MainActor func answersEncryptedRequestsWithTheMachineKey() async throws {
        let cipher = ContentCipher.aesGCM(key: Data(repeating: 7, count: 32))
        let host = FakeHost()
        let params = JSONValue.string(try cipher.encryptBase64(["op": "tabs", "action": "list", "sessionId": "sess_a"]))

        let reply = await DeviceBrowserRPC.respond(params: params, cipher: cipher, host: host)

        #expect(host.received == [.tabs(action: .list, tabId: nil, url: nil)])
        #expect(host.sessions == ["sess_a"])
        let decoded = try cipher.decryptBase64(try #require(reply.stringValue))
        #expect(decoded["ok"] == true)
        #expect(decoded["device"]?["platform"] == "macos")
        #expect(decoded["tabs"]?[0]?["id"] == "t1")
    }

    @Test @MainActor func reportsInvalidRequestsWithoutRunningThem() async throws {
        let host = FakeHost()
        let reply = await DeviceBrowserRPC.respond(params: ["op": "click", "sessionId": "sess_a"], cipher: nil, host: host)
        #expect(host.received.isEmpty)
        #expect(reply["ok"] == false)
        #expect(reply["errorCode"] == "invalid_request")
    }
    @Test @MainActor func routesOnlyServedSlotsOfKnownMachines() async throws {
        let marker = Data(#"{"t":"plain","v":null}"#.utf8).base64EncodedString()
        let doc = Data(#"{"t":"plain","v":{"host":"devbox"}}"#.utf8).base64EncodedString()
        let machine = try Machine(row: ["id": "m2", "active": true, "dataEncryptionKey": .string(marker), "metadata": .string(doc)], keys: nil)
        let host = FakeHost()

        let served = await DeviceBrowserRPC.reply(to: ["method": "m2:device.browser.v1.host", "params": ["op": "status", "sessionId": "sess_a"]],
                                                  machines: [machine], slots: [.host], host: host)
        #expect(served?["ok"] == true)
        let unserved = await DeviceBrowserRPC.reply(to: ["method": "m2:device.browser.v1.focused", "params": ["op": "status", "sessionId": "sess_a"]],
                                                    machines: [machine], slots: [.host], host: host)
        #expect(unserved?["errorCode"] == "disabled")
        let other = await DeviceBrowserRPC.reply(to: ["method": "m2:spawn-happy-session", "params": [:]],
                                                 machines: [machine], slots: [.host], host: host)
        #expect(other == nil)
        #expect(host.received == [.status])
    }
}
