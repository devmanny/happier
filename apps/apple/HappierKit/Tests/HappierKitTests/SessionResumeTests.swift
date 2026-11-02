import Foundation
import Testing
@testable import HappierKit

struct SessionResumeTests {
    private func session(_ metadata: JSONValue) throws -> Session {
        try Session(row: ["id": "existing", "seq": 42, "active": false, "encryptionMode": "plain",
                          "metadata": .string(String(decoding: try metadata.encoded(), as: UTF8.self))], keys: nil)
    }

    @Test func resumesTheExistingConversationWithoutSeedingNewDefaults() throws {
        let source = try session(["machineId": "mac", "path": "/work/project", "flavor": "claude",
                                  "claudeSessionId": "provider-thread", "permissionMode": "read-only",
                                  "modelOverrideV1": ["modelId": "saved-model", "updatedAt": 123]])
        let request = try SessionResumeRequest(session: source, requestId: "user-click")
        #expect(request.machineId == "mac")
        #expect(request.params["type"] == "resume-session")
        #expect(request.params["sessionId"] == "existing")
        #expect(request.params["directory"] == "/work/project")
        #expect(request.params["backendTarget"] == ["kind": "builtInAgent", "agentId": "claude"])
        #expect(request.params["executionAuthorization"] == ["provenance": "user_request", "requestId": "user-click"])
        // The daemon restores these from the saved session, with no newer client override.
        #expect(request.params["modelId"] == nil && request.params["permissionMode"] == nil)
        #expect(request.params["text"] == nil && request.params["initialPrompt"] == nil)
    }

    @Test func keepsTheSavedRuntimeIdentityOverAnOldFlavor() throws {
        let runtime: JSONValue = ["v": 1, "providerId": "codex", "provider": ["backendMode": "appServer", "vendorSessionId": "thread"]]
        let source = try session(["machineId": "mac", "path": "/work/project", "flavor": "claude", "agentRuntimeDescriptorV1": runtime])
        let request = try SessionResumeRequest(session: source, requestId: "click")
        #expect(request.params["backendTarget"] == ["kind": "builtInAgent", "agentId": "codex"])
        #expect(request.params["agentRuntimeDescriptorV1"] == runtime)
    }

    @Test func preservesConfiguredBackendsAndRejectsMissingIdentity() throws {
        let configured = try session(["machineId": "mac", "path": "/work", "flavor": "acp:my-agent",
                                      "acpConfiguredBackendV1": ["v": 1, "backendId": "my-agent"]])
        #expect(try SessionResumeRequest(session: configured, requestId: "click").params["backendTarget"]
            == ["kind": "configuredAcpBackend", "backendId": "my-agent"])
        let invalid: [JSONValue] = [
            ["path": "/work", "flavor": "claude"],
            ["machineId": "mac", "flavor": "claude"],
            ["machineId": "mac", "path": "/work", "flavor": "unknown"],
            ["machineId": "mac", "path": "/work", "flavor": "codex", "agentRuntimeDescriptorV1": ["v": 2]],
        ]
        for metadata in invalid {
            let source = try session(metadata)
            #expect(throws: HappierStore.RPCError.self) { try SessionResumeRequest(session: source, requestId: "click") }
        }
    }

    @Test func onlyTheExactSessionAcknowledgementSucceeds() throws {
        try SessionResumeRequest.validate(["type": "success", "sessionId": "existing"], sessionId: "existing")
        let invalid: [JSONValue] = [["type": "success", "sessionId": "new-session"], ["type": "success"],
                                   ["type": "error", "errorMessage": "Computer offline"]]
        for response in invalid {
            #expect(throws: HappierStore.RPCError.self) { try SessionResumeRequest.validate(response, sessionId: "existing") }
        }
    }

    @MainActor @Test func failedResumePreservesHistoryAndAllowsRetry() async throws {
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        let source = try session(["machineId": "mac", "path": "/work", "flavor": "claude"])
        store.sessions[source.id] = source
        #expect(await store.resumeSession(source.id) == false)
        #expect(store.sessions[source.id] == source)
        #expect(store.resumingSessions[source.id] == nil)
        #expect(store.lastError != nil)
        #expect(store.openRequest == nil)
    }
}
