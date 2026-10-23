import RackoonCore
import XCTest

/// The same cases as Android's ReconnectPolicyTests.
final class ReconnectPolicyTests: XCTestCase {
    func testOnlyALostConnectionIsRetried() {
        var p = ReconnectPolicy()
        XCTAssertEqual(p.onEnded(.remoteExit(0), connectedFor: 1), .giveUp)
        XCTAssertEqual(p.onEnded(.remoteExit(130), connectedFor: 1), .giveUp)
        XCTAssertEqual(p.onEnded(.closedByUser, connectedFor: 1), .giveUp)
    }

    func testBackoffThenGiveUp() {
        var p = ReconnectPolicy()
        let delays = (0..<5).map { _ -> TimeInterval in
            if case .retry(let d, _, _) = p.onEnded(.connectionLost, connectedFor: 0) { return d }
            return -1
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 15])
        XCTAssertEqual(p.onEnded(.connectionLost, connectedFor: 0), .giveUp)
    }

    func testALongSessionEarnsAFreshBudgetAndResetForgets() {
        var p = ReconnectPolicy()
        for _ in 0..<5 { _ = p.onEnded(.connectionLost, connectedFor: 0) }
        XCTAssertEqual(p.onEnded(.connectionLost, connectedFor: 10), .retry(delay: 1, attempt: 1, of: 5))
        _ = p.onEnded(.connectionLost, connectedFor: 0)
        p.reset()
        XCTAssertEqual(p.onEnded(.connectionLost, connectedFor: 0), .retry(delay: 1, attempt: 1, of: 5))
    }
}
