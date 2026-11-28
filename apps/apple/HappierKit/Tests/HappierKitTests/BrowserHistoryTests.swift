import Foundation
import Testing
@testable import HappierKit

/// The integrated browser remembers the pages the user visits and suggests them while an address
/// is typed: sites whose name starts with what was typed first, then pages that mention it.
@Suite struct BrowserHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func aRevisitedPageIsOneEntryThatCountsItsVisits() {
        var history = BrowserHistory()
        history.recordVisit(url: url("https://github.com/"), title: "GitHub", at: now)
        history.recordVisit(url: url("https://github.com/#readme"), title: "", at: now.addingTimeInterval(60))

        #expect(history.entries.count == 1)
        #expect(history.entries[0].visitCount == 2)
        // An empty title (a page still loading) keeps the one already known.
        #expect(history.entries[0].title == "GitHub")
        #expect(history.entries[0].lastVisited == now.addingTimeInterval(60))
    }

    @Test func onlyWebPagesAreRemembered() {
        var history = BrowserHistory()
        history.recordVisit(url: url("about:blank"), title: "", at: now)
        history.recordVisit(url: url("data:text/html,hi"), title: "", at: now)
        history.recordVisit(url: url("http://localhost:3000/"), title: "Dev", at: now)
        #expect(history.entries.map(\.url) == [url("http://localhost:3000/")])
    }

    @Test func sitesStartingWithWhatWasTypedComeBeforePagesThatOnlyMentionIt() {
        var history = BrowserHistory()
        history.recordVisit(url: url("https://news.ycombinator.com/item?id=1"), title: "Show HN: a git client", at: now)
        history.recordVisit(url: url("https://news.ycombinator.com/item?id=1"), title: "Show HN: a git client", at: now)
        history.recordVisit(url: url("https://www.github.com/happier-dev"), title: "Happier", at: now)
        history.recordVisit(url: url("https://gitlab.com/"), title: "GitLab", at: now.addingTimeInterval(-60))

        let hosts = history.suggestions(for: "git", limit: 10).map { $0.url.host() }
        // "www." is not part of what people type; the HN page only mentions git, however often visited.
        #expect(hosts == ["www.github.com", "gitlab.com", "news.ycombinator.com"])
    }

    @Test func typedSchemesAndPathsMatchToo() {
        var history = BrowserHistory()
        history.recordVisit(url: url("https://developer.apple.com/account/resources/identifiers/list"), title: "Identifiers", at: now)
        history.recordVisit(url: url("https://developer.apple.com/documentation"), title: "Docs", at: now)

        #expect(history.suggestions(for: "https://developer.apple.com/acc", limit: 10).map(\.title) == ["Identifiers"])
        #expect(history.suggestions(for: "  IDENTIF ", limit: 10).map(\.title) == ["Identifiers"])
        #expect(history.suggestions(for: "", limit: 10).isEmpty)
        #expect(history.suggestions(for: "developer", limit: 1).count == 1)
    }

    @Test func amongEqualMatchesTheMoreVisitedAndThenTheMoreRecentComeFirst() {
        var history = BrowserHistory()
        history.recordVisit(url: url("https://vercel.com/old"), title: "Old", at: now.addingTimeInterval(-3_600))
        history.recordVisit(url: url("https://vercel.com/new"), title: "New", at: now)
        history.recordVisit(url: url("https://vercel.com/dash"), title: "Dashboard", at: now.addingTimeInterval(-7_200))
        history.recordVisit(url: url("https://vercel.com/dash"), title: "Dashboard", at: now.addingTimeInterval(-7_100))

        #expect(history.suggestions(for: "vercel", limit: 10).map(\.title) == ["Dashboard", "New", "Old"])
    }

    @Test func pagesNotVisitedForAYearAreForgotten() {
        var history = BrowserHistory()
        history.recordVisit(url: url("https://old.example/"), title: "Old", at: now.addingTimeInterval(-BrowserHistory.retention - 1))
        history.recordVisit(url: url("https://new.example/"), title: "New", at: now)
        history.removeExpired(now: now)
        #expect(history.entries.map(\.title) == ["New"])
    }

    @Test func historySurvivesASaveAndLoad() throws {
        var history = BrowserHistory()
        history.recordVisit(url: url("https://github.com/"), title: "GitHub", at: now)
        let decoded = try JSONDecoder().decode(BrowserHistory.self, from: JSONEncoder().encode(history))
        #expect(decoded == history)
    }
}
