import Foundation
import Testing
@testable import HappierKit

@Suite struct UserFacingErrorTests {
    @Test func networkErrorsBecomeReadableMessages() {
        #expect(UserFacingError.message(for: URLError(.timedOut)) == UserFacingError.timedOut)
        #expect(UserFacingError.message(for: URLError(.notConnectedToInternet)) == UserFacingError.offline)
        #expect(UserFacingError.message(for: URLError(.networkConnectionLost)) == UserFacingError.offline)
        #expect(!UserFacingError.message(for: URLError(.badServerResponse)).contains("NSURLErrorDomain"))
    }

    @Test func serverAndRpcErrorsKeepTheirOwnMessage() {
        let server = HTTPClient.ServerError(status: 409, path: "/v2/x", body: ["error": "requested-action-conflict"])
        #expect(UserFacingError.message(for: server).contains("requested-action-conflict"))
        #expect(UserFacingError.message(for: HappierStore.RPCError(message: "Machine offline", code: nil)) == "Machine offline")
    }

    @Test func cancellationIsSilent() {
        #expect(UserFacingError.isSilent(CancellationError()))
        #expect(UserFacingError.isSilent(URLError(.cancelled)))
        #expect(!UserFacingError.isSilent(URLError(.timedOut)))
    }
}
