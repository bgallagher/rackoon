import Foundation
import RackoonCore
@testable import RackoonSSHEmbedded
import XCTest

/// The transport's own error texts are the ones Core's embedded explanations recognise.
final class ErrorExplanationTests: XCTestCase {
    private func kind(_ error: EmbeddedSSHError, _ signIn: SignInMethod? = .key) -> ConnectionFailure.Kind? {
        ConnectionFailure.explain(error.localizedDescription, signIn: signIn, device: "iPhone")?.kind
    }

    func testEveryNetworkAndSignInErrorIsExplained() {
        XCTAssertEqual(kind(.authFailed("the server refused it (it accepts: publickey)")), .authRefused)
        XCTAssertEqual(kind(.unreachable("Unable to resolve host nas.local")), .unresolved)
        XCTAssertEqual(kind(.unreachable("connect(descriptor:addr:size:): Connection refused (errno: 61)")), .unreachable)
        XCTAssertEqual(kind(.unreachable("timed out")), .unreachable)
        XCTAssertEqual(kind(.unreachable("timed out signing in")), .unreachable)
        XCTAssertEqual(kind(.connectionLost("the server closed the connection")), .unreachable)
    }
}
