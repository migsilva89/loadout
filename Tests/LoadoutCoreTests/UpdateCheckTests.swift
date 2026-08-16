import XCTest
@testable import LoadoutCore

/// The version comparison behind "a newer Loadout is available". Tested without a network: the
/// decision is the part that can be wrong quietly, and a wrong one either nags people who are
/// already current or leaves them on a broken build forever.
final class UpdateCheckTests: XCTestCase {
    private func release(_ tag: String, page: String = "https://github.com/migsilva89/loadout/releases/tag/x") -> UpdateCheck.Release {
        UpdateCheck.Release(tagName: tag, htmlURL: page)
    }

    func testATagIsNewerThanTheRunningVersion() {
        let found = UpdateCheck.available(from: release("v0.1.1"), current: "0.1.0")
        XCTAssertEqual(found?.version, "0.1.1")
    }

    func testTheSameVersionIsNotAnUpdate() {
        XCTAssertNil(UpdateCheck.available(from: release("v0.1.0"), current: "0.1.0"))
    }

    func testAnOlderPublishedVersionIsNotAnUpdate() {
        XCTAssertNil(UpdateCheck.available(from: release("v0.0.9"), current: "0.1.0"))
    }

    /// The one a string comparison gets backwards: "0.1.10" sorts before "0.1.9" as text.
    func testTenIsNewerThanNine() {
        XCTAssertTrue(UpdateCheck.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.9", than: "0.1.10"))
    }

    /// A shorter version is padded rather than treated as smaller: 0.2 is 0.2.0, which beats 0.1.9.
    func testAShorterVersionIsPaddedWithZeros() {
        XCTAssertTrue(UpdateCheck.isNewer("0.2", than: "0.1.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.2", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))
    }

    /// The tag carries a "v" and the bundle does not; they are the same version written two ways.
    func testTheTagsLeadingVIsIgnored() {
        XCTAssertEqual(UpdateCheck.normalise("v0.1.1"), "0.1.1")
        XCTAssertEqual(UpdateCheck.normalise(" 0.1.1 "), "0.1.1")
        XCTAssertNil(UpdateCheck.available(from: release("v0.1.0"), current: "v0.1.0"))
    }

    func testTheReleasesOwnPageIsWhereItSends() {
        let page = "https://github.com/migsilva89/loadout/releases/tag/v0.2.0"
        XCTAssertEqual(UpdateCheck.available(from: release("v0.2.0", page: page), current: "0.1.0")?.page.absoluteString, page)
    }
}
