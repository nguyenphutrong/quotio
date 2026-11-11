import QuotioDomain
import XCTest
@testable import QuotioPresentation

final class MuseCodePresentationTests: XCTestCase {
    func testMuseCodeIsPresentedUnderItsProductName() {
        XCTAssertEqual(QuotaProvider.muse.displayName, "Muse Code")
        XCTAssertEqual(QuotaProvider.muse.logoAssetName, "meta")
        XCTAssertEqual(QuotaProvider.muse.menuBarIconAsset, "meta-menubar")
    }

    func testMuseCodeLogsInThroughTheProxyMetaRoute() {
        XCTAssertEqual(QuotaProvider.muse.oauthEndpoint, "/meta-auth-url")
    }
}
