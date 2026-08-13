//
//  AppResetService.swift
//  Quotio
//
//  Full factory reset of Quotio-owned state (issue #373).
//
//  Quotio persists state in places app uninstallers do not reach (Keychain
//  records and the Launch at Login registration survive deleting the app bundle
//  and its containers), so users who hit a corrupted state could never actually
//  start fresh. This service quiesces every Quotio writer, wipes every store
//  Quotio itself owns and relaunches the app into onboarding.
//
//  It deliberately does NOT touch user-owned or third-party data:
//  - Provider auth files in ~/.cli-proxy-api (usable by CLIProxyAPI directly)
//  - Credentials owned by other CLI tools (~/.codex, ~/.claude, gh, ...)
//  - Local IDE databases read during quota scans (Cursor, Trae, Antigravity),
//    including ~/Library/Application Support/Antigravity/**
//  - Backups of the user's CLI agent configuration files, which are written
//    next to the agents' own configs
//

import AppKit
import Foundation
import ServiceManagement

enum AppResetService {

    // MARK: - Inventory

    /// Every Quotio-owned on-disk store, as a closed set.
    ///
    /// Adding a persistent location to the app means adding a case here; the
    /// inventory test asserts that this enum and `Inventory.stateLocations`
    /// stay in one-to-one correspondence, so a new store cannot silently
    /// escape "Reset Quotio".
    nonisolated enum StoreID: String, CaseIterable, Sendable {
        /// `~/Library/Application Support/Quotio` — proxy binaries under
        /// `proxy/`, `CLIProxyAPI`, `config.yaml`, `request-history.json`,
        /// `Monitor/accounts-v1.json`, `Monitor/snapshots-v1.json`,
        /// `Monitor/antigravity-shadow-v1.json`.
        case applicationSupport

        /// `~/Library/Application Support/<bundle-id>` — PostHog 3.64.1's store.
        /// The SDK keeps the anonymous/device identity, remote config and the
        /// pending event queues in `<bundle-id>/<project-token>/`, and migrates
        /// pre-3.48 files from `<bundle-id>/` itself, so the whole
        /// bundle-id-named directory is telemetry state Quotio owns. Nothing
        /// else in the app writes there: every other Quotio path is under
        /// `Application Support/Quotio`.
        case telemetry

        /// `~/Library/Caches/<bundle-id>` — URL cache and other app caches.
        case caches

        /// `~/Library/HTTPStorages/<bundle-id>` — URLSession cookie/credential
        /// storage keyed by the app's bundle id.
        case httpStorages

        /// `~/Library/HTTPStorages/<bundle-id>.binarycookies` — the sibling
        /// cookie file macOS writes next to the directory above.
        case httpCookies

        /// `~/.quotio/antigravity-profiles` — per-account device fingerprint
        /// profiles Quotio generates for Antigravity account switching. Written
        /// by Quotio, keyed by account e-mail, and account-linked, so a reset
        /// must remove them. Antigravity's OWN database
        /// (`~/Library/Application Support/Antigravity/**`) is external and is
        /// never touched.
        case antigravityProfiles
    }

    nonisolated struct StateLocation: Equatable, Sendable {
        let id: StoreID
        let url: URL
    }

    /// Declarative list of every persistent store Quotio owns.
    ///
    /// New UserDefaults keys are covered automatically via the persistent
    /// domain; new keychain services must be added to
    /// `KeychainHelper.quotioOwnedServices`; new file locations must be added
    /// to `StoreID` and built in `current(...)`. System state that is neither
    /// (the Launch at Login registration) is handled explicitly by `wipe`.
    nonisolated struct Inventory: Sendable {
        /// UserDefaults persistent domain removed wholesale, so every key the
        /// app has ever written (settings, persisted.ideQuotas, onboarding
        /// flags, menu bar selection, ...) is cleared without enumeration.
        let defaultsDomain: String

        /// Keychain services whose generic-password items Quotio created
        /// (management keys, Warp tokens, Monitor OAuth credentials),
        /// including legacy service names from earlier releases.
        let keychainServices: [String]

        /// Files and directories Quotio owns on disk. Removed recursively.
        let stateLocations: [StateLocation]

        /// Whether to unregister `SMAppService.mainApp`. Launch at Login is
        /// system state rather than a Quotio store, so a reset that skipped it
        /// would leave the "fresh install" registered to start at login.
        let unregistersLaunchAtLogin: Bool

        /// - Parameters:
        ///   - libraryURL: `~/Library`. Injected by tests so no assertion ever
        ///     runs against the developer's real Quotio state.
        ///   - homeURL: `~`. Injected by tests for the same reason.
        nonisolated static func current(
            fileManager: FileManager = .default,
            libraryURL: URL? = nil,
            homeURL: URL? = nil,
            bundleID: String? = nil,
            unregistersLaunchAtLogin: Bool = true
        ) -> Inventory {
            let bundleID = bundleID ?? Bundle.main.bundleIdentifier ?? "dev.quotio.desktop"
            let home = homeURL ?? fileManager.homeDirectoryForCurrentUser
            let library = libraryURL
                ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Library", isDirectory: true)

            let applicationSupport = library.appendingPathComponent("Application Support", isDirectory: true)
            let httpStorages = library.appendingPathComponent("HTTPStorages", isDirectory: true)

            let locations: [StateLocation] = [
                StateLocation(
                    id: .applicationSupport,
                    url: applicationSupport.appendingPathComponent("Quotio", isDirectory: true)
                ),
                StateLocation(
                    id: .telemetry,
                    url: applicationSupport.appendingPathComponent(bundleID, isDirectory: true)
                ),
                StateLocation(
                    id: .caches,
                    url: library.appendingPathComponent("Caches", isDirectory: true)
                        .appendingPathComponent(bundleID, isDirectory: true)
                ),
                StateLocation(
                    id: .httpStorages,
                    url: httpStorages.appendingPathComponent(bundleID, isDirectory: true)
                ),
                StateLocation(
                    id: .httpCookies,
                    url: httpStorages.appendingPathComponent("\(bundleID).binarycookies", isDirectory: false)
                ),
                StateLocation(
                    id: .antigravityProfiles,
                    url: home.appendingPathComponent(".quotio/antigravity-profiles", isDirectory: true)
                ),
            ]

            return Inventory(
                defaultsDomain: bundleID,
                keychainServices: KeychainHelper.quotioOwnedServices,
                stateLocations: locations,
                unregistersLaunchAtLogin: unregistersLaunchAtLogin
            )
        }
    }

    // MARK: - Result

    /// What a wipe failed to remove. A reset that reports failures must not
    /// relaunch: presenting an incomplete wipe as a fresh install is exactly
    /// the "reset did not reset" problem issue #373 describes.
    nonisolated struct ResetReport: Sendable, Equatable {
        /// Human-readable descriptions of every store that could not be wiped.
        var failures: [String] = []

        var isComplete: Bool { failures.isEmpty }
    }

    // MARK: - Orchestration

    /// Quiesces everything Quotio is running, wipes all Quotio-owned state, and
    /// relaunches the app so it starts from clean onboarding.
    ///
    /// Teardown order matters: every writer is stopped and awaited *before* the
    /// stores are deleted, so nothing can re-create a store during the wipe or
    /// during the handoff to the new process.
    ///
    /// - Returns: the report. Only an empty report relaunches; otherwise the
    ///   current app stays open so the caller can surface an actionable error.
    @MainActor
    @discardableResult
    static func performFullReset(using viewModel: QuotaViewModel) async -> ResetReport {
        Log.debug("Full reset requested: quiescing services")

        // 1. Telemetry first: PostHog flushes its queues on a timer and would
        //    otherwise re-create its store directory after the wipe.
        TelemetryService.shared.shutdownForReset()

        // 2. Background pollers.
        AtomFeedUpdateService.shared.stopPolling()

        // 3. Cancel and AWAIT every Quotio writer (schedulers, proxy, request
        //    tracker disk queue, in-flight Monitor refreshes).
        await viewModel.quiesceForReset()

        // 4. Tunnel teardown, awaited.
        await viewModel.tunnelManager.stopTunnel()

        // 5. Reads UserDefaults (proxyPort/useBridgeMode) to find orphaned proxy
        //    processes, so it must run BEFORE the defaults domain is removed.
        CLIProxyManager.terminateProxyOnShutdown()

        let report = wipe(inventory: .current())

        guard report.isComplete else {
            Log.warning("Reset: incomplete, staying open (\(report.failures.count) failures)")
            return report
        }

        relaunch()
        return report
    }

    /// Wipes every store in the inventory. Each target is attempted
    /// independently — one failure must not skip the remaining stores — and
    /// every failure is aggregated into the returned report.
    nonisolated static func wipe(
        inventory: Inventory,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        deleteKeychainService: (String) -> KeychainHelper.ServiceWipeResult = {
            KeychainHelper.deleteAllItems(service: $0)
        },
        unregisterLaunchAtLogin: () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) -> ResetReport {
        var report = ResetReport()

        defaults.removePersistentDomain(forName: inventory.defaultsDomain)
        defaults.synchronize()
        Log.debug("Reset: removed defaults domain \(inventory.defaultsDomain)")

        for service in inventory.keychainServices {
            if case .failed(let status) = deleteKeychainService(service) {
                report.failures.append("Keychain service \(service) (OSStatus \(status))")
            }
        }
        Log.debug("Reset: cleared \(inventory.keychainServices.count) keychain services")

        for location in inventory.stateLocations {
            guard fileManager.fileExists(atPath: location.url.path) else { continue }
            do {
                try fileManager.removeItem(at: location.url)
                Log.debug("Reset: removed \(location.url.path)")
            } catch {
                Log.warning("Reset: failed to remove \(location.url.path): \(error.localizedDescription)")
                report.failures.append("\(location.url.path) (\(error.localizedDescription))")
            }
        }

        if inventory.unregistersLaunchAtLogin {
            do {
                try unregisterLaunchAtLogin()
                Log.debug("Reset: unregistered launch at login")
            } catch {
                Log.warning("Reset: failed to unregister launch at login: \(error.localizedDescription)")
                report.failures.append("Launch at Login (\(error.localizedDescription))")
            }
        }

        return report
    }

    // MARK: - Relaunch

    /// Relaunches a fresh instance and exits immediately.
    ///
    /// `exit(0)` deliberately bypasses `applicationWillTerminate`, so no
    /// termination handler can write back to the stores that were just wiped.
    /// That also means quit-time behaviour which rewrites files OUTSIDE the
    /// inventory — such as the opt-in agent-config restore — does not run: a
    /// reset must not silently rewrite the user's own `~/.claude`, `~/.codex`
    /// and other agent configs, which are external and are never part of a
    /// Quotio reset.
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
