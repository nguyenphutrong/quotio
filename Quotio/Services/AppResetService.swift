//
//  AppResetService.swift
//  Quotio
//
//  Full factory reset of Quotio-owned state (issue #373).
//
//  Quotio persists state in places app uninstallers do not reach (Keychain
//  records survive deleting the app bundle and its containers), so users who
//  hit a corrupted state could never actually start fresh. This service wipes
//  every store Quotio itself owns and relaunches the app into onboarding.
//
//  It deliberately does NOT touch user-owned data:
//  - Provider auth files in ~/.cli-proxy-api (usable by CLIProxyAPI directly)
//  - Credentials owned by other CLI tools (~/.codex, gh, Claude, etc.)
//  - Local IDE databases read during quota scans (Cursor, Trae, Antigravity)
//  - Backups of the user's CLI agent configuration files
//

import AppKit
import Foundation

enum AppResetService {

    // MARK: - Inventory

    /// Declarative list of every persistent store Quotio owns.
    ///
    /// Any new Quotio-owned persistence added to the app MUST be covered here
    /// (new UserDefaults keys are covered automatically via the persistent
    /// domain; new keychain services must be added to
    /// `KeychainHelper.quotioOwnedServices`; new file locations must be added
    /// to `stateDirectories`). Unit tests assert this inventory stays in sync
    /// with the known stores.
    nonisolated struct Inventory {
        /// UserDefaults persistent domain removed wholesale, so every key the
        /// app has ever written (settings, persisted.ideQuotas, onboarding
        /// flags, menu bar selection, ...) is cleared without enumeration.
        let defaultsDomain: String

        /// Keychain services whose generic-password items Quotio created
        /// (management keys, Warp tokens, Monitor OAuth credentials),
        /// including legacy service names from earlier releases.
        let keychainServices: [String]

        /// Directories Quotio owns on disk. Removed recursively.
        let stateDirectories: [URL]

        nonisolated static func current(fileManager: FileManager = .default) -> Inventory {
            var directories: [URL] = []

            if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                // Proxy binaries, config.yaml, Monitor snapshots
                // (Monitor/accounts-v1.json, Monitor/snapshots-v1.json),
                // request-history.json.
                directories.append(appSupport.appendingPathComponent("Quotio", isDirectory: true))
            }

            let bundleID = Bundle.main.bundleIdentifier ?? "dev.quotio.desktop"
            if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                directories.append(caches.appendingPathComponent(bundleID, isDirectory: true))
            }

            return Inventory(
                defaultsDomain: bundleID,
                keychainServices: KeychainHelper.quotioOwnedServices,
                stateDirectories: directories
            )
        }
    }

    // MARK: - Orchestration

    /// Stops everything Quotio is running, wipes all Quotio-owned state, and
    /// relaunches the app so it starts from clean onboarding.
    @MainActor
    static func performFullReset(using viewModel: QuotaViewModel) async {
        Log.debug("Full reset requested: stopping services")

        // Stop background work before deleting the files/processes it uses.
        // Each step is best-effort; a failure must not block the wipe.
        AtomFeedUpdateService.shared.stopPolling()
        viewModel.stopProxy()
        await viewModel.tunnelManager.stopTunnel()

        // Reads UserDefaults (proxyPort/useBridgeMode) to find orphaned proxy
        // processes, so it must run BEFORE the defaults domain is removed.
        CLIProxyManager.terminateProxyOnShutdown()

        wipe(inventory: .current())

        relaunch()
    }

    /// Wipes every store in the inventory. Best-effort: each target is
    /// attempted independently and failures are logged, never thrown.
    nonisolated static func wipe(
        inventory: Inventory,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        deleteKeychainService: (String) -> Void = { KeychainHelper.deleteAllItems(service: $0) }
    ) {
        defaults.removePersistentDomain(forName: inventory.defaultsDomain)
        Log.debug("Reset: removed defaults domain \(inventory.defaultsDomain)")

        for service in inventory.keychainServices {
            deleteKeychainService(service)
        }
        Log.debug("Reset: cleared \(inventory.keychainServices.count) keychain services")

        for directory in inventory.stateDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            do {
                try fileManager.removeItem(at: directory)
                Log.debug("Reset: removed \(directory.path)")
            } catch {
                Log.warning("Reset: failed to remove \(directory.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Relaunch

    /// Relaunches a fresh instance and exits immediately, skipping normal
    /// termination handlers so no in-memory state is written back to the
    /// stores that were just wiped.
    @MainActor
    private static func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundlePath]
        do {
            try process.run()
        } catch {
            Log.warning("Reset: relaunch failed (\(error.localizedDescription)); quitting instead")
        }
        exit(0)
    }
}
