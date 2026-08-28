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

    // MARK: - The three outcomes, over a stubbed network

    /// "Up to date" and "couldn't ask" used to be the same nil. They are different facts — one is
    /// GitHub answering, the other is never having reached it — and a pane that says "you're on
    /// the latest version" when the request failed is lying to somebody who asked a plain question.
    func testGitHubAnsweringWithANewerTagIsAnUpdate() async {
        let outcome = await check(status: 200, body: #"{"tag_name":"v0.2.0","html_url":"https://example.com/r"}"#)
        XCTAssertEqual(outcome, .available(UpdateCheck.Available(version: "0.2.0", page: URL(string: "https://example.com/r")!)))
    }

    func testGitHubAnsweringWithTheSameTagIsUpToDate() async {
        let outcome = await check(status: 200, body: #"{"tag_name":"v0.1.0","html_url":"https://example.com/r"}"#)
        XCTAssertEqual(outcome, .upToDate)
    }

    /// Offline, and the case that matters most: silence is not agreement.
    func testANetworkErrorIsUnreachableRatherThanUpToDate() async {
        let outcome = await check(error: URLError(.notConnectedToInternet))
        XCTAssertEqual(outcome, .unreachable)
    }

    /// Rate limiting is GitHub's usual way of saying no, and it arrives as a perfectly valid body.
    func testANon200IsUnreachable() async {
        let outcome = await check(status: 403, body: #"{"message":"API rate limit exceeded"}"#)
        XCTAssertEqual(outcome, .unreachable)
    }

    func testAPayloadThatIsNotTheExpectedShapeIsUnreachable() async {
        let notJSON = await check(status: 200, body: "<html>502 Bad Gateway</html>")
        XCTAssertEqual(notJSON, .unreachable)
        let missingTheTag = await check(status: 200, body: #"{"name":"0.2.0"}"#)
        XCTAssertEqual(missingTheTag, .unreachable)
    }

    /// Runs the real `check(against:)` against a stubbed URLSession, so every branch above is the
    /// shipping code path and not a rehearsal of it.
    private func check(status: Int = 200, body: String = "", error: URLError? = nil) async -> UpdateCheck.Outcome {
        StubProtocol.answer = (status, Data(body.utf8), error)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return await UpdateCheck.check(against: "0.1.0", session: URLSession(configuration: configuration))
    }
}

/// Answers whatever the test last set, so no test here touches the network.
private final class StubProtocol: URLProtocol {
    /// One test runs at a time and each sets this before asking; the unchecked annotation is that
    /// fact written down, not a claim that this would be safe under concurrency.
    nonisolated(unsafe) static var answer: (status: Int, body: Data, error: URLError?) = (200, Data(), nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let answer = Self.answer
        if let error = answer.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
