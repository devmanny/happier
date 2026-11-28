import Foundation

/// Daemon CLI versions, ordered as the web client orders them (`compareVersions` in
/// `apps/ui/sources/utils/system/versionUtils.ts`): numeric parts, then a release after its
/// `preview` builds after its `dev` builds. Anything else can't be ordered.
public enum CLIVersion {
    /// First daemon whose strict `session.fork` schema accepts `requestId`
    /// (`MINIMUM_CLI_SESSION_FORK_REQUEST_ID_VERSION`).
    public static let forkRequestId = "0.2.10-dev.41"

    /// `version` is known to be `minimum` or later; one that can't be ordered isn't.
    public static func isAtLeast(_ version: String?, _ minimum: String) -> Bool {
        guard let version = version.flatMap(Parsed.init), let minimum = Parsed(minimum) else { return false }
        return !(version < minimum)
    }

    private struct Parsed: Comparable {
        let base: [Int]
        /// 0 dev, 1 preview, 2 release.
        let channel: Int
        let prerelease: [Int]

        init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let halves = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = halves.first, !first.isEmpty else { return nil }
            let base = first.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !base.isEmpty, base.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
            self.base = base.compactMap { $0 }
            guard halves.count == 2 else {
                channel = 2
                prerelease = []
                return
            }
            let parts = halves[1].split(separator: ".", omittingEmptySubsequences: false)
            switch parts.first {
            case "dev": channel = 0
            case "preview": channel = 1
            default: return nil
            }
            let numbers = parts.dropFirst().map { Int($0) }
            guard !numbers.isEmpty, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
            prerelease = numbers.compactMap { $0 }
        }

        static func < (lhs: Parsed, rhs: Parsed) -> Bool {
            if let order = compare(lhs.base, rhs.base) { return order }
            if lhs.channel != rhs.channel { return lhs.channel < rhs.channel }
            return compare(lhs.prerelease, rhs.prerelease) ?? false
        }

        /// Missing parts count as 0; nil when equal.
        private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Bool? {
            for index in 0..<max(lhs.count, rhs.count) {
                let left = index < lhs.count ? lhs[index] : 0, right = index < rhs.count ? rhs[index] : 0
                if left != right { return left < right }
            }
            return nil
        }
    }
}
