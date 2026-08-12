import XCTest

@testable import Quotio

final class AppResetServiceTests: XCTestCase {

    // MARK: - Inventory coverage

    /// The reset inventory is the registry of every Quotio-owned store.
    /// A new keychain service must be added to `KeychainHelper.quotioOwnedServices`
    /// (and this list) or this test fails, so future stores cannot silently
    /// escape "Reset Quotio" (issue #373).
    func testInventoryCoversAllQuotioKeychainServices() {
        let inventory = AppResetService.Inventory.current()
        XCTAssertEqual(inventory.keychainServices, KeychainHelper.quotioOwnedServices)

        let required = [
            // Current services
            "dev.quotio.desktop.remote-management",
            "dev.quotio.desktop.local-management",
            "dev.quotio.desktop.warp",
            "dev.quotio.desktop.monitor-auth",
            // Legacy service names still cleared for upgraded installs
            "proseek.io.vn.Quotio.remote-management",
            "com.quotio.remote-management",
            "proseek.io.vn.Quotio.local-management",
            "com.quotio.local-management",
            "proseek.io.vn.Quotio.warp",
            "com.quotio.warp",
        ]
        for service in required {
            XCTAssertTrue(
                inventory.keychainServices.contains(service),
                "Reset inventory must clear keychain service \(service)"
            )
        }
        XCTAssertEqual(Set(inventory.keychainServices).count, inventory.keychainServices.count)
    }

    func testInventoryCoversDefaultsDomainAndStateDirectories() {
        let inventory = AppResetService.Inventory.current()

        // Tests are hosted in Quotio.app, so this is the app's real domain.
        XCTAssertEqual(inventory.defaultsDomain, Bundle.main.bundleIdentifier)

        let paths = inventory.stateDirectories.map(\.path)
        XCTAssertTrue(
            paths.contains { $0.hasSuffix("Application Support/Quotio") },
            "Reset must remove ~/Library/Application Support/Quotio (proxy binaries, config.yaml, Monitor snapshots, request history): \(paths)"
        )
        XCTAssertTrue(
            paths.contains { $0.contains("/Caches/") && $0.hasSuffix(inventory.defaultsDomain) },
            "Reset must remove the app's caches directory: \(paths)"
        )

        // Reset must never reach into user-owned credential locations.
        for path in paths {
            XCTAssertFalse(path.contains(".cli-proxy-api"), "Reset must not touch ~/.cli-proxy-api")
            XCTAssertFalse(path.contains(".codex"), "Reset must not touch other tools' credentials")
        }
    }

    // MARK: - Wipe behavior

    func testWipeClearsAllKnownPersistedDefaultsKeys() throws {
        let suiteName = "dev.quotio.tests.reset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Known persisted keys across the app's stores, including the ones the
        // ghost-state report in issue #373 hit (persisted.ideQuotas, onboarding).
        let knownKeys = [
            "appMode", "operatingMode", "connectionMode", "hasCompletedOnboarding",
            "migratedToOperatingMode", "remoteConnectionConfig",
            "persisted.ideQuotas", "persisted.disabledAuthFiles", "quotio.authFiles.lastChanged",
            "proxyPort", "proxyURL", "useBridgeMode", "autoStartProxy", "autoStartTunnel",
            "autoRestartTunnel", "allowNetworkAccess", "selectedProxyBinarySource",
            "hasExplicitProxyBinarySourceSelection", "lastProxyUpdateCheckDate",
            "menuBarSelectedQuotaItems", "menuBarColorMode", "showMenuBarIcon",
            "customProviders", "fallbackConfiguration", "notificationsEnabled",
            "quotaAlertThreshold", "shareAnonymousUsage", "anonymousInstallID",
            "appLanguage", "showInDock", "updateChannel", "KiroMachineId",
        ]
        for key in knownKeys {
            defaults.set("some-value", forKey: key)
        }

        let inventory = AppResetService.Inventory(
            defaultsDomain: suiteName,
            keychainServices: [],
            stateDirectories: []
        )
        AppResetService.wipe(inventory: inventory, defaults: defaults, deleteKeychainService: { _ in })

        for key in knownKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must not survive a reset")
        }
    }

    func testWipeRemovesStateDirectoriesAndKeepsUserOwnedSiblings() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let quotioDir = root.appendingPathComponent("Quotio", isDirectory: true)
        let monitorSnapshot = quotioDir.appendingPathComponent("Monitor/snapshots-v1.json")
        let userOwned = root.appendingPathComponent(".cli-proxy-api/user-auth.json")
        try fileManager.createDirectory(
            at: monitorSnapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: userOwned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: monitorSnapshot)
        try Data("{}".utf8).write(to: userOwned)
        defer { try? fileManager.removeItem(at: root) }

        let inventory = AppResetService.Inventory(
            defaultsDomain: "dev.quotio.tests.reset.\(UUID().uuidString)",
            keychainServices: [],
            stateDirectories: [quotioDir]
        )
        AppResetService.wipe(inventory: inventory, deleteKeychainService: { _ in })

        XCTAssertFalse(fileManager.fileExists(atPath: quotioDir.path))
        XCTAssertFalse(fileManager.fileExists(atPath: monitorSnapshot.path))
        XCTAssertTrue(
            fileManager.fileExists(atPath: userOwned.path),
            "User-owned files outside the inventory must survive a reset"
        )
    }

    func testWipeRequestsDeletionOfEveryKeychainService() {
        var deleted: [String] = []
        let inventory = AppResetService.Inventory(
            defaultsDomain: "dev.quotio.tests.reset.\(UUID().uuidString)",
            keychainServices: KeychainHelper.quotioOwnedServices,
            stateDirectories: []
        )
        AppResetService.wipe(inventory: inventory, deleteKeychainService: { deleted.append($0) })

        XCTAssertEqual(deleted, KeychainHelper.quotioOwnedServices)
    }

    /// Management keys and Monitor credentials use dynamic account names, so
    /// the reset must delete by service, not by known accounts.
    func testDeleteAllItemsRemovesEveryAccountUnderService() throws {
        let service = "dev.quotio.tests.reset.\(UUID().uuidString)"
        guard KeychainHelper.writeExternalCredential(Data("a".utf8), service: service, account: "account-a"),
              KeychainHelper.writeExternalCredential(Data("b".utf8), service: service, account: "account-b")
        else {
            throw XCTSkip("Keychain is not writable in this environment")
        }

        KeychainHelper.deleteAllItems(service: service)

        XCTAssertNil(KeychainHelper.readExternalCredential(service: service, account: "account-a"))
        XCTAssertNil(KeychainHelper.readExternalCredential(service: service, account: "account-b"))
    }
}
