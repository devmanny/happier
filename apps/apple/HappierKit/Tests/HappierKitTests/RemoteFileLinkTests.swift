import Foundation
import Testing
@testable import HappierKit

@MainActor
@Suite struct RemoteFileLinkTests {
    @Test func markdownLinkToReportUsesOriginalRemotePath() throws {
        let path = "/Users/manny/Reports/Conversiones-Intercom-2026-10-25/analisis.md"
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let bodies = [
            "[Read report](" + path + ")",
            #"[Read report](\/Users/manny/Reports/Conversiones-Intercom-2026-10-25/analisis.md)"#,
        ]
        for body in bodies {
            let text = try AttributedString(markdown: body, options: options)
            let url = try #require(text.runs.compactMap(\.link).first)
            let link = try #require(RemoteFileLink(url: url))
            #expect(link.path == path && link.name == "analisis.md")
        }
        // Percent-encoded slash is a separate URL contract from Markdown's literal escaped slash.
        let encoded = try AttributedString(markdown: "[Read report](%2FUsers%2Fmanny%2FReports%2Fanalisis.md#summary)", options: options)
        let encodedURL = try #require(encoded.runs.compactMap(\.link).first)
        #expect(RemoteFileLink(url: encodedURL)?.path == "/Users/manny/Reports/analisis.md")
    }

    @Test func localFileURLsAndExplicitMarkdownRelativesDecodeExactlyOnce() throws {
        let examples = [
            ("file:///tmp/Report%20one.md#summary", "/tmp/Report one.md", "Report one.md"),
            ("file://localhost/tmp/report.md?view=1#part", "/tmp/report.md", "report.md"),
            ("./docs/report.md#part", "./docs/report.md", "report.md"),
            ("../report.md", "../report.md", "report.md"),
            ("docs/report.md?q=ignored", "docs/report.md", "report.md"),
            ("report.md", "report.md", "report.md"),
            ("example.com", "example.com", "example.com"),
            ("/tmp/literal%2520name.md", "/tmp/literal%20name.md", "literal%20name.md"),
            ("/tmp/literal%23name.md#section", "/tmp/literal#name.md", "literal#name.md"),
            ("~/report.md", "~/report.md", "report.md"),
            ("C:/Reports/report.md", "C:/Reports/report.md", "report.md"),
            (#"C:\Reports\report.md"#, #"C:\Reports\report.md"#, "report.md"),
            ("file:///C:/Reports/report.md", "C:/Reports/report.md", "report.md"),
        ]
        for (input, path, name) in examples {
            let url = try #require(URL(string: input))
            let link = try #require(RemoteFileLink(url: url))
            #expect(link.path == path && link.name == name)
        }
    }

    @Test func webCustomAuthorityAndEmptyTargetsKeepSystemURLHandling() throws {
        for input in ["https://example.com/report.md", "http://example.com/report.md", "mailto:test@example.com",
                      "happier://session/test", "custom:/tmp/report.md", "x://host/report.md", "x://user:pass@host:42/report.md",
                      "c://host/report.md", "file://other-computer/tmp/report.md",
                      "//example.com/report.md", "#section", "?query=1", "", "/", "/tmp/", "file://localhost"] {
            if let url = URL(string: input) { #expect(RemoteFileLink(url: url) == nil) }
        }
        let webRelative = try #require(URL(string: "report.md", relativeTo: URL(string: "https://example.com/")))
        #expect(RemoteFileLink(url: webRelative) == nil)
    }

    @Test func machineFallbackPreservesRemoteAbsolutePathsInsteadOfPrefixingProject() {
        #expect(HappierStore.attachmentPathForMachine("/Users/manny/Reports/report.md", sessionPath: "/project") == "/Users/manny/Reports/report.md")
        #expect(HappierStore.attachmentPathForMachine("C:/Reports/report.md", sessionPath: "C:/Project") == "C:/Reports/report.md")
        #expect(HappierStore.attachmentPathForMachine(#"C:\Reports\report.md"#, sessionPath: #"C:\Project"#) == #"C:\Reports\report.md"#)
        #expect(HappierStore.attachmentPathForMachine("docs/report.md", sessionPath: "/project") == "/project/docs/report.md")
    }

    @Test func immutableAttachmentUsesCacheButMutableLinkRefreshDoesNotReturnStaleFile() async throws {
        let sessionId = "remote-file-test-" + UUID().uuidString
        let file = MessageAttachment(name: "report.md", path: "/remote/report.md")
        let cache = HappierStore.attachmentCacheURL(for: file, sessionId: sessionId)
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let cachedBytes = Data("previous report version".utf8)
        try cachedBytes.write(to: cache)
        let store = HappierStore(server: URL(string: "http://127.0.0.1:1")!)
        store.lastError = "Unrelated error"
        #expect(try await store.attachmentFile(file, in: sessionId) == cache)
        do {
            _ = try await store.attachmentFile(file, in: sessionId, refresh: true)
            Issue.record("A fresh open must attempt the remote transfer instead of returning stale cached bytes")
        } catch {
            #expect(error is HappierStore.RPCError)
        }
        #expect(try Data(contentsOf: cache) == cachedBytes)
        #expect(store.lastError == "Unrelated error")
    }

    /// A link in a conversation: a file on the session's computer opens its preview, a web page asks
    /// where to open (Happier's browser or the default one), anything else goes to the system.
    @Test func conversationLinksSplitIntoFilesWebPagesAndOthers() throws {
        #expect(ConversationLink(URL(string: "/Users/manny/report.md")!) == .file(RemoteFileLink(url: URL(string: "/Users/manny/report.md")!)!))
        for web in ["https://example.com/a?b=1", "http://localhost:3000/", "HTTPS://Example.com"] {
            #expect(ConversationLink(URL(string: web)!) == .webPage(URL(string: web)!), "\(web)")
        }
        for other in ["mailto:a@b.c", "tel:+5215555", "happier-native://inbox"] {
            #expect(ConversationLink(URL(string: other)!) == .other(URL(string: other)!), "\(other)")
        }
    }
}
