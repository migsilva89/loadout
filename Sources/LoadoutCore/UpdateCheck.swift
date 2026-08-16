import Foundation

/// Whether a newer Loadout has been published, and where to get it.
///
/// The app ships as a DMG people drag to Applications, so nothing tells them a new version exists
/// — the first release went out with no way at all to reach the people who had already downloaded
/// it. This is that way: one call to the GitHub releases API, a version comparison, and a link.
///
/// Deliberately not an auto-updater. It never downloads and never replaces anything: it says a
/// newer version is out and opens the release page. Replacing a signed app in place is the part
/// that goes wrong silently, and a link cannot.
public enum UpdateCheck {
    /// Where the releases live. The API endpoint answers with the newest non-draft, non-prerelease
    /// release, which is exactly the one a person should be offered.
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/migsilva89/loadout/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/migsilva89/loadout/releases/latest")!

    public struct Available: Equatable, Sendable {
        /// The published version, without the tag's leading "v" — "0.1.1", not "v0.1.1".
        public let version: String
        /// The release's own page, for the person to download from.
        public let page: URL

        public init(version: String, page: URL) {
            self.version = version
            self.page = page
        }
    }

    /// The running app's version, from the same `CFBundleShortVersionString` the build script
    /// writes from the git tag. A build run straight from Xcode or `swift run` has no bundle
    /// version; that returns nil and the check is skipped rather than comparing against garbage.
    public static func runningVersion(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !raw.isEmpty, raw != "dev"
        else { return nil }
        return raw
    }

    /// Asks GitHub what the newest release is, and answers with it only when it is newer than what
    /// is running. Any failure — offline, rate-limited, GitHub down — answers nil: a version check
    /// that interrupts somebody because their café wifi dropped is worse than no version check.
    ///
    /// - Parameter current: defaults to the running bundle's version.
    public static func newerRelease(
        than current: String? = runningVersion(),
        session: URLSession = .shared
    ) async -> Available? {
        guard let current else { return nil }
        var request = URLRequest(url: latestReleaseAPI)
        // GitHub asks for these two by name and answers unversioned requests less predictably.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Loadout/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data)
        else { return nil }

        return available(from: release, current: current)
    }

    /// The decision itself, split out from the network so it can be tested without one.
    static func available(from release: Release, current: String) -> Available? {
        let latest = normalise(release.tagName)
        guard isNewer(latest, than: normalise(current)) else { return nil }
        let page = URL(string: release.htmlURL) ?? releasesPage
        return Available(version: latest, page: page)
    }

    /// "v0.1.1" and "0.1.1" are the same version written two ways — the tag carries the "v" and
    /// the bundle does not.
    static func normalise(_ version: String) -> String {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" { trimmed.removeFirst() }
        return trimmed
    }

    /// Compares dotted numeric versions field by field, shorter one padded with zeros, so 0.2 beats
    /// 0.1.9 and 0.1.10 beats 0.1.9 — which a string comparison gets backwards.
    ///
    /// Anything after the numbers (a "-beta" suffix) is ignored rather than ranked: the API only
    /// hands back full releases, so a prerelease should never arrive here, and guessing an ordering
    /// for one would be inventing a rule nothing follows.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = fields(candidate), right = fields(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func fields(_ version: String) -> [Int] {
        version.split(separator: ".").map { field in
            Int(field.prefix { $0.isNumber }) ?? 0
        }
    }

    /// Only the two fields this needs, so an unrelated change to GitHub's payload cannot break it.
    struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
