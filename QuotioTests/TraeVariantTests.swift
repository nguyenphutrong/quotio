import XCTest
@testable import Quotio

/// Tests for Trae CN support (issue #265): the variant descriptor must point at
/// Trae CN's own install/storage locations, and the .traeCn provider must mirror
/// .trae everywhere scan/persistence/deletion behavior keys off provider traits.
final class TraeVariantTests: XCTestCase {

    // MARK: - Variant Descriptor

    func testInternationalVariantDescriptorPaths() {
        let variant = TraeVariantDescriptor.international
        XCTAssertEqual(variant.provider, .trae)
        XCTAssertEqual(variant.displayName, "Trae")
        XCTAssertEqual(
            variant.storageJsonPath,
            "~/Library/Application Support/Trae/User/globalStorage/storage.json"
        )
        XCTAssertTrue(variant.appPaths.contains("/Applications/Trae.app"))
        XCTAssertEqual(variant.defaultAPIHost, "https://api-sg-central.trae.ai")
        XCTAssertEqual(variant.webOrigin, "https://www.trae.ai")
        XCTAssertEqual(variant.fallbackAccountKey, "Trae User")
    }

    func testCnVariantDescriptorPaths() {
        // Trae CN ships as "Trae CN.app" (bundle id cn.trae.app) with its own
        // "~/Library/Application Support/Trae CN" directory (Homebrew cask trae-cn).
        let variant = TraeVariantDescriptor.cn
        XCTAssertEqual(variant.provider, .traeCn)
        XCTAssertEqual(variant.displayName, "Trae CN")
        XCTAssertEqual(
            variant.storageJsonPath,
            "~/Library/Application Support/Trae CN/User/globalStorage/storage.json"
        )
        XCTAssertTrue(variant.appPaths.contains("/Applications/Trae CN.app"))
        // No public source confirms Trae CN's API host, so none is hardcoded: the host is
        // taken from the auth blob (see TraeCnScanTests). The web origin is the cask's
        // documented homepage.
        XCTAssertNil(variant.defaultAPIHost)
        XCTAssertEqual(variant.webOrigin, "https://www.trae.com.cn")
        XCTAssertEqual(variant.fallbackAccountKey, "Trae CN User")
    }

    func testVariantsAreDistinct() {
        // Both editions can be installed side by side; their scan targets and
        // provider identities must never collide.
        XCTAssertNotEqual(TraeVariantDescriptor.international, TraeVariantDescriptor.cn)
        XCTAssertNotEqual(
            TraeVariantDescriptor.international.storageJsonPath,
            TraeVariantDescriptor.cn.storageJsonPath
        )
        XCTAssertNotEqual(
            TraeVariantDescriptor.international.provider,
            TraeVariantDescriptor.cn.provider
        )
        XCTAssertTrue(Set(TraeVariantDescriptor.international.appPaths)
            .isDisjoint(with: TraeVariantDescriptor.cn.appPaths))
    }

    // MARK: - Provider Identity

    func testTraeCnProviderIdentity() {
        XCTAssertEqual(AIProvider.traeCn.rawValue, "trae-cn")
        XCTAssertEqual(AIProvider(rawValue: "trae-cn"), .traeCn)
        XCTAssertEqual(AIProvider.traeCn.displayName, "Trae CN")
        XCTAssertNotEqual(AIProvider.traeCn.displayName, AIProvider.trae.displayName)
        XCTAssertNotEqual(AIProvider.traeCn.menuBarSymbol, AIProvider.trae.menuBarSymbol)
    }

    func testTraeCnMirrorsTraeProviderTraits() {
        // Deletion gating and auto-refresh exclusion for scanned IDE accounts key
        // off these traits (issues #29/#213), so Trae CN must match Trae exactly.
        XCTAssertTrue(AIProvider.traeCn.usesBrowserAuth)
        XCTAssertEqual(AIProvider.traeCn.usesBrowserAuth, AIProvider.trae.usesBrowserAuth)
        XCTAssertFalse(AIProvider.traeCn.supportsManualAuth)
        XCTAssertEqual(AIProvider.traeCn.supportsManualAuth, AIProvider.trae.supportsManualAuth)
        XCTAssertTrue(AIProvider.traeCn.isQuotaTrackingOnly)
        XCTAssertTrue(AIProvider.traeCn.supportsQuotaOnlyMode)
        XCTAssertFalse(AIProvider.traeCn.supportsLocalProxySetup)
        XCTAssertFalse(AIProvider.traeCn.usesCLIQuota)
    }

    func testTraeCnMonitorAccountUsesLocalIDESource() {
        // Monitor mode must classify scanned Trae CN accounts like Trae/Cursor ones.
        let account = MonitorRefreshCoordinator.makeQuotaDerivedAccount(
            provider: .traeCn,
            accountKey: "user@example.com",
            source: .localIDE,
            disabledIDs: []
        )
        XCTAssertEqual(account.provider, .traeCn)
        XCTAssertEqual(account.source, .localIDE)
    }

    // MARK: - IDE Scan Options

    @MainActor
    func testScanOptionsIncludeTraeCn() {
        var options = IDEScanOptions.defaultOptions
        XCTAssertFalse(options.scanTraeCn)
        XCTAssertFalse(options.hasIDEScanEnabled)

        options.scanTraeCn = true
        XCTAssertTrue(options.hasIDEScanEnabled)
        XCTAssertTrue(options.hasAnyScanEnabled)

        XCTAssertTrue(IDEScanOptions.allEnabled.scanTraeCn)
    }

    @MainActor
    func testScanOptionsAccessedPathsDistinguishTraeVariants() {
        let traeOnly = IDEScanOptions(scanCursor: false, scanTrae: true, scanTraeCn: false, scanCLITools: false)
        XCTAssertEqual(
            traeOnly.accessedPaths,
            ["~/Library/Application Support/Trae/User/globalStorage/storage.json"]
        )

        let traeCnOnly = IDEScanOptions(scanCursor: false, scanTrae: false, scanTraeCn: true, scanCLITools: false)
        XCTAssertEqual(
            traeCnOnly.accessedPaths,
            ["~/Library/Application Support/Trae CN/User/globalStorage/storage.json"]
        )

        let titles = IDEScanOptions.allEnabled.privacyNoticeItems.map(\.title)
        XCTAssertTrue(titles.contains("Trae IDE"))
        XCTAssertTrue(titles.contains("Trae CN IDE"))
    }
}
