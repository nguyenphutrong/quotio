import XCTest

@testable import Quotio

final class AppResetServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Builds the real inventory against a throwaway root so no assertion ever
    /// runs against the developer's own Quotio state.
    private func sandboxedInventory(
        root: URL,
        bundleID: String = "dev.quotio.tests.bundle"
    ) -> AppResetService.Inventory {
        AppResetService.Inventory.current(
            libraryURL: root.appendingPathComponent("Library", isDirectory: true),
            homeURL: root,
            bundleID: bundleID,
            unregistersLaunchAtLogin: false
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotio-reset-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func write(_ contents: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

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

    /// `StoreID` is the closed set of Quotio-owned on-disk stores. Adding a
    /// persistence location to the app means adding a case AND building it in
    /// `Inventory.current`; this test fails on either half being missing, which
    /// is what stops a future store from escaping the reset.
    func testInventoryBuildsEveryDeclaredStoreExactlyOnce() throws {
        let inventory = sandboxedInventory(root: try makeRoot())
        let builtIDs = inventory.stateLocations.map(\.id)

        XCTAssertEqual(
            Set(builtIDs), Set(AppResetService.StoreID.allCases),
            "Every StoreID must be built by Inventory.current and vice versa"
        )
        XCTAssertEqual(
            builtIDs.count, AppResetService.StoreID.allCases.count,
            "A store must not be registered twice"
        )
    }

    func testInventoryPathsMatchTheDocumentedLayout() throws {
        let root = try makeRoot()
        let inventory = sandboxedInventory(root: root, bundleID: "dev.quotio.tests.bundle")
        let byID = Dictionary(uniqueKeysWithValues: inventory.stateLocations.map { ($0.id, $0.url.path) })

        XCTAssertEqual(inventory.defaultsDomain, "dev.quotio.tests.bundle")

        // Proxy binaries, config.yaml, Monitor snapshots, request history.
        XCTAssertEqual(
            byID[.applicationSupport],
            root.appendingPathComponent("Library/Application Support/Quotio").path)

        // PostHog 3.64.1 writes the anonymous/device identity, config and the
        // pending event queues to Application Support/<bundle-id>/<token>/.
        XCTAssertEqual(
            byID[.telemetry],
            root.appendingPathComponent("Library/Application Support/dev.quotio.tests.bundle").path)

        XCTAssertEqual(
            byID[.caches],
            root.appendingPathComponent("Library/Caches/dev.quotio.tests.bundle").path)

        XCTAssertEqual(
            byID[.httpStorages],
            root.appendingPathComponent("Library/HTTPStorages/dev.quotio.tests.bundle").path)
        XCTAssertEqual(
            byID[.httpCookies],
            root.appendingPathComponent("Library/HTTPStorages/dev.quotio.tests.bundle.binarycookies").path)

        // Per-account Antigravity device fingerprint profiles written by Quotio.
        XCTAssertEqual(
            byID[.antigravityProfiles],
            root.appendingPathComponent(".quotio/antigravity-profiles").path)
    }

    /// The reset must never reach into another tool's data. The Antigravity IDE
    /// database and CLI credential stores are read by Quotio but owned by them.
    func testInventoryNeverTargetsExternalToolData() throws {
        let inventory = sandboxedInventory(root: try makeRoot())
        let paths = inventory.stateLocations.map(\.url.path)

        let external = [
            ".cli-proxy-api",
            ".codex",
            ".claude",
            ".gemini",
            ".factory",
            ".aws",
            "Library/Application Support/Antigravity",
            "Library/Application Support/Cursor",
            "Library/Application Support/Trae",
            "Library/Application Support/Code",
            "Library/Application Support/Claude",
        ]
        for path in paths {
            for tool in external {
                XCTAssertFalse(
                    path.contains(tool),
                    "Reset must not touch external tool data (\(tool)) but targets \(path)"
                )
            }
        }

        // ~/.quotio is Quotio's own dot-directory, but only the profiles
        // subdirectory may be removed — never the directory as a whole.
        XCTAssertFalse(
            paths.contains { $0.hasSuffix("/.quotio") },
            "Reset must scope ~/.quotio to the antigravity-profiles subdirectory: \(paths)"
        )
    }

    func testInventoryUnregistersLaunchAtLoginByDefault() {
        XCTAssertTrue(
            AppResetService.Inventory.current().unregistersLaunchAtLogin,
            "Launch at Login is system state; a reset must unregister SMAppService.mainApp"
        )
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
            stateLocations: [],
            unregistersLaunchAtLogin: false
        )
        let report = AppResetService.wipe(
            inventory: inventory,
            defaults: defaults,
            deleteKeychainService: { _ in .cleared }
        )

        XCTAssertTrue(report.isComplete)
        for key in knownKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must not survive a reset")
        }
    }

    /// Every registered store is removed, and everything outside the inventory
    /// — including other tools' credentials that sit right next to them — is
    /// left alone.
    func testWipeRemovesEveryRegisteredStoreAndKeepsExternalData() throws {
        let fileManager = FileManager.default
        let root = try makeRoot()
        let inventory = sandboxedInventory(root: root)

        // Populate every registered store with a representative artifact.
        let appSupportRoot = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        let owned: [URL] = [
            try write("{}", to: appSupportRoot.appendingPathComponent("Quotio/Monitor/snapshots-v1.json")),
            try write("{}", to: appSupportRoot.appendingPathComponent("Quotio/request-history.json")),
            try write("bin", to: appSupportRoot.appendingPathComponent("Quotio/proxy/current/CLIProxyAPI")),
            // PostHog: <bundle-id>/<project-token>/posthog.<key>
            try write(
                "anon-id",
                to: appSupportRoot.appendingPathComponent(
                    "dev.quotio.tests.bundle/phc_projecttoken/posthog.anonymousId")),
            try write(
                "device-id",
                to: appSupportRoot.appendingPathComponent(
                    "dev.quotio.tests.bundle/phc_projecttoken/posthog.deviceId")),
            // PostHog pre-3.48 files live directly under <bundle-id>/.
            try write(
                "legacy",
                to: appSupportRoot.appendingPathComponent("dev.quotio.tests.bundle/posthog.queue.plist")),
            try write(
                "cache",
                to: root.appendingPathComponent("Library/Caches/dev.quotio.tests.bundle/urlcache.db")),
            try write(
                "cookies",
                to: root.appendingPathComponent("Library/HTTPStorages/dev.quotio.tests.bundle/cookies")),
            try write(
                "cookies",
                to: root.appendingPathComponent(
                    "Library/HTTPStorages/dev.quotio.tests.bundle.binarycookies")),
            // Per-account Antigravity device profiles written by Quotio.
            try write(
                "{}",
                to: root.appendingPathComponent(".quotio/antigravity-profiles/user_at_example_com.json")),
        ]

        // External data that must survive, deliberately adjacent to the above.
        let external: [URL] = [
            try write("{}", to: root.appendingPathComponent(".cli-proxy-api/user-auth.json")),
            try write("{}", to: root.appendingPathComponent(".codex/auth.json")),
            try write("{}", to: root.appendingPathComponent(".claude/.credentials.json")),
            try write("{}", to: root.appendingPathComponent(".claude/settings.json.backup.1736840000")),
            // The Antigravity IDE's own database, a sibling of the telemetry dir.
            try write(
                "sqlite",
                to: appSupportRoot.appendingPathComponent(
                    "Antigravity/User/globalStorage/state.vscdb")),
            try write(
                "sqlite",
                to: appSupportRoot.appendingPathComponent(
                    "Antigravity/User/globalStorage/storage.json")),
            try write("{}", to: appSupportRoot.appendingPathComponent("Cursor/User/globalStorage/state.vscdb")),
        ]

        let report = AppResetService.wipe(
            inventory: inventory,
            defaults: try XCTUnwrap(UserDefaults(suiteName: "dev.quotio.tests.reset.\(UUID().uuidString)")),
            deleteKeychainService: { _ in .cleared }
        )
        XCTAssertTrue(report.isComplete, "Unexpected failures: \(report.failures)")

        for url in owned {
            XCTAssertFalse(
                fileManager.fileExists(atPath: url.path),
                "Quotio-owned state must not survive a reset: \(url.path)")
        }
        for location in inventory.stateLocations {
            XCTAssertFalse(
                fileManager.fileExists(atPath: location.url.path),
                "\(location.id.rawValue) must be removed: \(location.url.path)")
        }
        for url in external {
            XCTAssertTrue(
                fileManager.fileExists(atPath: url.path),
                "External / user-owned data must survive a reset: \(url.path)")
        }
        // ~/.quotio itself is Quotio's, but only the profiles subtree is wiped.
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent(".quotio").path))
    }

    func testWipeRequestsDeletionOfEveryKeychainService() {
        var deleted: [String] = []
        let inventory = AppResetService.Inventory(
            defaultsDomain: "dev.quotio.tests.reset.\(UUID().uuidString)",
            keychainServices: KeychainHelper.quotioOwnedServices,
            stateLocations: [],
            unregistersLaunchAtLogin: false
        )
        let report = AppResetService.wipe(
            inventory: inventory,
            deleteKeychainService: {
                deleted.append($0)
                return .cleared
            }
        )

        XCTAssertEqual(deleted, KeychainHelper.quotioOwnedServices)
        XCTAssertTrue(report.isComplete)
    }

    // MARK: - Launch at Login

    func testWipeUnregistersLaunchAtLogin() {
        var unregistered = false
        let inventory = AppResetService.Inventory(
            defaultsDomain: "dev.quotio.tests.reset.\(UUID().uuidString)",
            keychainServices: [],
            stateLocations: [],
            unregistersLaunchAtLogin: true
        )

        let report = AppResetService.wipe(
            inventory: inventory,
            deleteKeychainService: { _ in .cleared },
            unregisterLaunchAtLogin: { unregistered = true }
        )

        XCTAssertTrue(unregistered, "SMAppService.mainApp must be unregistered by a reset")
        XCTAssertTrue(report.isComplete)
    }

    func testLaunchAtLoginUnregistrationFailureIsReported() {
        struct Failure: LocalizedError {
            var errorDescription: String? { "login item is locked" }
        }
        let inventory = AppResetService.Inventory(
            defaultsDomain: "dev.quotio.tests.reset.\(UUID().uuidString)",
            keychainServices: [],
            stateLocations: [],
            unregistersLaunchAtLogin: true
        )

        let report = AppResetService.wipe(
            inventory: inventory,
            deleteKeychainService: { _ in .cleared },
            unregisterLaunchAtLogin: { throw Failure() }
        )

        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].contains("Launch at Login"))
        XCTAssertTrue(report.failures[0].contains("login item is locked"))
    }

    // MARK: - Failure propagation

    func testKeychainFailureIsReportedAndDoesNotStopRemainingStores() throws {
        let root = try makeRoot()
        let quotioDir = root.appendingPathComponent("Library/Application Support/Quotio", isDirectory: true)
        try write("{}", to: quotioDir.appendingPathComponent("config.yaml"))

        let inventory = AppResetService.Inventory(
            defaultsDomain: "dev.quotio.tests.reset.\(UUID().uuidString)",
            keychainServices: ["service-a", "service-b"],
            stateLocations: [AppResetService.StateLocation(id: .applicationSupport, url: quotioDir)],
            unregistersLaunchAtLogin: false
        )

        let report = AppResetService.wipe(
            inventory: inventory,
            deleteKeychainService: { $0 == "service-a" ? .failed(errSecAuthFailed) : .cleared }
        )

        XCTAssertFalse(report.isComplete, "A failed keychain wipe must be reported")
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].contains("service-a"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: quotioDir.path),
            "One failure must not skip the remaining stores"
        )
    }

    func testUndeletableDirectoryIsReported() throws {
        let root = try makeRoot()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try write("{}", to: locked.appendingPathComponent("state.json"))
        // Read-only parent: the child cannot be unlinked.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }

        let inventory = AppResetService.Inventory(
            defaultsDomain: "dev.quotio.tests.reset.\(UUID().uuidString)",
            keychainServices: [],
            stateLocations: [AppResetService.StateLocation(id: .applicationSupport, url: locked)],
            unregistersLaunchAtLogin: false
        )

        let report = AppResetService.wipe(
            inventory: inventory,
            deleteKeychainService: { _ in .cleared }
        )

        // Running as root would defeat the permission bits; skip rather than
        // assert something the environment cannot honour.
        try XCTSkipIf(!FileManager.default.fileExists(atPath: locked.path), "Environment allows the delete")
        XCTAssertFalse(report.isComplete, "An undeletable store must be reported, not just logged")
        XCTAssertTrue(report.failures.contains { $0.contains(locked.path) })
    }

    // MARK: - Keychain wipe

    /// Management keys and Monitor credentials use dynamic account names, so
    /// the reset must delete by service, not by known accounts.
    func testDeleteAllItemsRemovesEveryAccountUnderService() throws {
        let service = "dev.quotio.tests.reset.\(UUID().uuidString)"
        guard KeychainHelper.writeExternalCredential(Data("a".utf8), service: service, account: "account-a"),
              KeychainHelper.writeExternalCredential(Data("b".utf8), service: service, account: "account-b")
        else {
            throw XCTSkip("Keychain is not writable in this environment")
        }

        XCTAssertEqual(KeychainHelper.deleteAllItems(service: service), .cleared)

        XCTAssertNil(KeychainHelper.readExternalCredential(service: service, account: "account-a"))
        XCTAssertNil(KeychainHelper.readExternalCredential(service: service, account: "account-b"))
    }

    /// Deleting a service that never had items still verifies emptiness rather
    /// than reporting a failure for `errSecItemNotFound`.
    func testDeleteAllItemsOnEmptyServiceReportsCleared() {
        let service = "dev.quotio.tests.reset.empty.\(UUID().uuidString)"
        XCTAssertEqual(KeychainHelper.deleteAllItems(service: service), .cleared)
    }
}
