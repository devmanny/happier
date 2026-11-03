import Foundation
import Testing
@testable import HappierKit

@Suite struct SessionTokenUsageTests {
    private func usage(_ tokens: Int) -> SessionTokenUsage {
        SessionTokenUsage(response: ["usage": [["tokens": ["total": .number(Double(tokens)), "input": 8, "output": 2], "reportCount": 1]]])
    }

    @Test func usesReportedTotalWithoutAddingComponentsAgain() {
        let response: JSONValue = ["usage": [
            ["tokens": ["total": 100, "input": 80, "output": 20], "reportCount": 1],
            ["tokens": ["total": 50, "input": 30, "output": 20], "reportCount": 1],
        ]]
        #expect(SessionTokenUsage(response: response).tokens == 150)
        #expect(usage(0).tokens == 0)
        #expect(SessionTokenUsage(response: ["usage": []]).tokens == nil)
        #expect(SessionTokenUsage(response: ["usage": [["tokens": ["input": 5], "reportCount": 1]]]).tokens == nil)
    }

    @Test func ignoresCostOnlyBucketsWithoutInventingZeroTokenUsage() {
        let costOnly: JSONValue = ["tokens": [:], "cost": ["total": 1], "reportCount": 1]
        #expect(SessionTokenUsage(response: ["usage": [costOnly]]).tokens == nil)
        #expect(SessionTokenUsage(response: ["usage": [costOnly, ["tokens": ["total": 25], "reportCount": 1]]]).tokens == 25)
    }

    @Test func includesGrandchildrenOnceAndKeepsOwnSeparate() {
        let parents = ["child": "parent", "grandchild": "child", "other": "outside"]
        let reports = ["parent": usage(100), "child": usage(50), "grandchild": usage(25), "other": usage(900)]
        let parent = SessionTokenSummary(sessionId: "parent", parents: parents, usage: reports)
        #expect(parent.own == 100)
        #expect(parent.descendants == 75)
        #expect(parent.total == 175)
        #expect(parent.descendantCount == 2)
        #expect(parent.missingCount == 0)
        #expect(SessionTokenSummary(sessionId: "child", parents: parents, usage: reports).total == 75)
    }

    @Test func missingReportsArePartialAndCyclesNeverDoubleCount() {
        let parents = ["a": "c", "b": "a", "c": "b"]
        let summary = SessionTokenSummary(sessionId: "a", parents: parents, usage: ["a": usage(10), "b": usage(20)])
        #expect(summary.total == 30)
        #expect(summary.descendantCount == 2)
        #expect(summary.missingCount == 1)
        #expect(SessionTokenSummary.memberIds("a", parents: parents) == ["a", "b", "c"])
    }
}

/// HTTP is the mocked boundary; the request, response parser and aggregation stay real.
private final class SessionUsageURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        #expect(request.url?.path == "/v1/usage/query")
        #expect(request.httpMethod == "POST")
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 256)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        #expect((try? JSONValue.parse(body)) == ["sessionId": "one-session"])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"usage":[{"tokens":{"total":123,"input":120,"output":3},"reportCount":1}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension SessionTokenUsageTests {
    @Test func readsOnlyTheRequestedSessionAggregate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionUsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = HappierAPI(server: URL(string: "https://usage.invalid")!, token: "test", session: session)
        let usage = try await api.sessionTokenUsage(sessionId: "one-session")
        #expect(usage.tokens == 123)
    }
}
