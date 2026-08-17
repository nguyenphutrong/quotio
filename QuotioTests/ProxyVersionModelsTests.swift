import XCTest
@testable import Quotio

final class ProxyVersionModelsTests: XCTestCase {
    func testBundledProxyChecksumAcceptsSignedArtifactValue() {
        let signedChecksum = String(repeating: "A", count: 64)

        XCTAssertEqual(
            ProxyBinarySource.resolvedPlusLocalSHA256(bundleValue: signedChecksum),
            signedChecksum.lowercased()
        )
    }

    func testBundledProxyChecksumFallsBackForInvalidBundleValue() {
        XCTAssertEqual(
            ProxyBinarySource.resolvedPlusLocalSHA256(bundleValue: "not-a-checksum"),
            ProxyBinarySource.plusLocalSHA256
        )
    }
}
