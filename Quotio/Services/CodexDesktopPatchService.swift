//
//  CodexDesktopPatchService.swift
//  Quotio
//

import CryptoKit
import Foundation

nonisolated enum CodexDesktopPatchState: String, Sendable {
    case notFound
    case unpatched
    case patched
    case unsupported
}

nonisolated struct CodexDesktopPatchStatus: Sendable {
    let state: CodexDesktopPatchState
    let appPath: String?
    let message: String
}

actor CodexDesktopPatchService {
    private struct TextPatch {
        let needle: String
        let replacement: String
    }

    enum PatchError: LocalizedError {
        case macOSOnly
        case codexAppNotFound
        case npxNotFound
        case infoPlistNotFound(String)
        case asarNotFound(String)
        case commandFailed(String)
        case unsupportedCodexVersion(String)
        case invalidAsarHeader
        case invalidInfoPlist(String)

        var errorDescription: String? {
            switch self {
            case .macOSOnly:
                return "Codex Desktop patching is only supported on macOS."
            case .codexAppNotFound:
                return "Codex.app was not found in /Applications or ~/Applications."
            case .npxNotFound:
                return "npx is required to patch Codex Desktop."
            case .infoPlistNotFound(let path):
                return "Codex Info.plist was not found at \(path)."
            case .asarNotFound(let path):
                return "Codex app.asar was not found at \(path)."
            case .commandFailed(let message):
                return message
            case .unsupportedCodexVersion(let label):
                return "This Codex Desktop version does not match the expected \(label) bundle."
            case .invalidAsarHeader:
                return "Could not read the app.asar header."
            case .invalidInfoPlist(let path):
                return "Could not update ElectronAsarIntegrity in \(path)."
            }
        }
    }

    private static let systemCodexApp = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
    private static let userCodexApp = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true)
        .appendingPathComponent("Codex.app", isDirectory: true)

    private static let appAsarBackupName = "app.asar.before-quotio-codex-desktop-patch"
    private static let infoPlistBackupName = "Info.plist.before-quotio-codex-desktop-patch"

    private static let modelPickerNeedle = "let u=c.useHiddenModels&&o!==`amazonBedrock`,d;"
    private static let modelPickerReplacement = "let u=!1,d;"
    private static let modelReasoningNeedle = "s=i&&e!==`amazonBedrock`;"
    private static let modelReasoningReplacement = "s=!1;"
    private static let sidebarNeedle = "listRecentThreads({cursor:e,limit:t}){return this.params.requestClient.sendRequest(`thread/list`,{limit:t,cursor:e,sortKey:this.recentConversationSortKey,modelProviders:null,archived:!1,sourceKinds:ke})}"
    private static let sidebarReplacement = "listRecentThreads({cursor:e,limit:t}){return this.params.requestClient.sendRequest(`thread/list`,{limit:t,cursor:e,sortKey:this.recentConversationSortKey,modelProviders:[],archived:!1,sourceKinds:ke})}"

    private let fileManager: FileManager
    private let runtimeDirectory: URL

    init(
        fileManager: FileManager = .default,
        runtimeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.runtimeDirectory = runtimeDirectory ?? AppRuntimeIdentity
            .applicationSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("CodexDesktopPatch", isDirectory: true)
    }

    func status() -> CodexDesktopPatchStatus {
        if let patchedApp = patchedCodexAppBundle() {
            return CodexDesktopPatchStatus(
                state: .patched,
                appPath: patchedApp.path,
                message: "Codex Desktop picker is patched."
            )
        }

        guard let app = existingCodexAppBundle() else {
            return CodexDesktopPatchStatus(
                state: .notFound,
                appPath: nil,
                message: "Codex Desktop not found."
            )
        }

        let appAsar = appAsarURL(for: app)
        guard fileManager.fileExists(atPath: appAsar.path) else {
            return CodexDesktopPatchStatus(
                state: .notFound,
                appPath: app.path,
                message: "app.asar not found."
            )
        }

        return CodexDesktopPatchStatus(
            state: .unpatched,
            appPath: app.path,
            message: "Codex Desktop picker is not patched."
        )
    }

    func patch() async throws -> CodexDesktopPatchStatus {
        #if os(macOS)
        guard await CLIExecutor.shared.findBinary(named: "npx") != nil else {
            throw PatchError.npxNotFound
        }

        let codexApp = try await codexAppBundleForPatch()
        let appAsar = appAsarURL(for: codexApp)
        let infoPlist = infoPlistURL(for: codexApp)

        guard fileManager.fileExists(atPath: appAsar.path) else {
            throw PatchError.asarNotFound(appAsar.path)
        }
        guard fileManager.fileExists(atPath: infoPlist.path) else {
            throw PatchError.infoPlistNotFound(infoPlist.path)
        }

        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try backupIfNeeded(source: appAsar, backupName: Self.appAsarBackupName)
        try backupVersionedAsar(appAsar)
        try backupIfNeeded(source: infoPlist, backupName: Self.infoPlistBackupName)

        await quitCodexDesktop()

        let workdir = runtimeDirectory.appendingPathComponent("app-asar-work", isDirectory: true)
        if fileManager.fileExists(atPath: workdir.path) {
            try fileManager.removeItem(at: workdir)
        }
        try fileManager.createDirectory(at: workdir, withIntermediateDirectories: true)

        try await runCLI(
            name: "npx",
            arguments: ["--yes", "asar", "extract", appAsar.path, workdir.path],
            timeout: 120
        )

        let changed = try patchExtractedBundles(at: workdir)
        if changed {
            try await runCLI(
                name: "npx",
                arguments: ["--yes", "asar", "pack", workdir.path, appAsar.path],
                timeout: 120
            )
            try updateAppAsarIntegrity(appAsar: appAsar, infoPlist: infoPlist)
            try await resignCodexApp(codexApp)
        }

        return CodexDesktopPatchStatus(
            state: .patched,
            appPath: codexApp.path,
            message: changed ? "Codex Desktop picker patched." : "Codex Desktop picker was already patched."
        )
        #else
        throw PatchError.macOSOnly
        #endif
    }

    func restore() async throws -> CodexDesktopPatchStatus {
        #if os(macOS)
        let codexApp = patchedCodexAppBundle() ?? existingCodexAppBundle() ?? Self.userCodexApp
        let appAsar = appAsarURL(for: codexApp)
        let infoPlist = infoPlistURL(for: codexApp)
        let asarBackup = runtimeDirectory.appendingPathComponent(Self.appAsarBackupName)
        let infoBackup = runtimeDirectory.appendingPathComponent(Self.infoPlistBackupName)

        guard fileManager.fileExists(atPath: asarBackup.path) else {
            return CodexDesktopPatchStatus(
                state: status().state,
                appPath: codexApp.path,
                message: "No Codex Desktop backup found."
            )
        }

        await quitCodexDesktop()
        if fileManager.fileExists(atPath: appAsar.path) {
            try fileManager.removeItem(at: appAsar)
        }
        try fileManager.copyItem(at: asarBackup, to: appAsar)

        if fileManager.fileExists(atPath: infoBackup.path) {
            if fileManager.fileExists(atPath: infoPlist.path) {
                try fileManager.removeItem(at: infoPlist)
            }
            try fileManager.copyItem(at: infoBackup, to: infoPlist)
        } else if fileManager.fileExists(atPath: infoPlist.path) {
            try updateAppAsarIntegrity(appAsar: appAsar, infoPlist: infoPlist)
        }

        try await resignCodexApp(codexApp)
        return CodexDesktopPatchStatus(
            state: .unpatched,
            appPath: codexApp.path,
            message: "Codex Desktop patch restored."
        )
        #else
        throw PatchError.macOSOnly
        #endif
    }

    func restartCodexDesktop() async {
        await quitCodexDesktop()

        let target = patchedCodexAppBundle() ?? existingCodexAppBundle()
        if let target {
            _ = await CLIExecutor.shared.execute(
                command: "/usr/bin/open",
                arguments: [target.path],
                timeout: 10
            )
        } else {
            _ = await CLIExecutor.shared.execute(
                command: "/usr/bin/open",
                arguments: ["-a", "Codex"],
                timeout: 10
            )
        }
    }

    // MARK: - App Bundle

    private func existingCodexAppBundle() -> URL? {
        for app in [Self.userCodexApp, Self.systemCodexApp] {
            if fileManager.fileExists(atPath: appAsarURL(for: app).path) {
                return app
            }
        }
        return nil
    }

    private func patchedCodexAppBundle() -> URL? {
        for app in [Self.userCodexApp, Self.systemCodexApp] {
            let appAsar = appAsarURL(for: app)
            if fileManager.fileExists(atPath: appAsar.path), appAsarIsPatched(appAsar) {
                return app
            }
        }
        return nil
    }

    private func codexAppBundleForPatch() async throws -> URL {
        let systemAsar = appAsarURL(for: Self.systemCodexApp)
        if fileManager.fileExists(atPath: systemAsar.path), pathIsWritable(systemAsar) {
            return Self.systemCodexApp
        }

        let userAsar = appAsarURL(for: Self.userCodexApp)
        if fileManager.fileExists(atPath: userAsar.path) {
            return Self.userCodexApp
        }

        guard fileManager.fileExists(atPath: systemAsar.path) else {
            throw PatchError.codexAppNotFound
        }

        try fileManager.createDirectory(at: Self.userCodexApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await run(
            command: "/usr/bin/ditto",
            arguments: [Self.systemCodexApp.path, Self.userCodexApp.path],
            timeout: 120
        )
        return Self.userCodexApp
    }

    private func appAsarURL(for codexApp: URL) -> URL {
        codexApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("app.asar")
    }

    private func infoPlistURL(for codexApp: URL) -> URL {
        codexApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
    }

    private func pathIsWritable(_ url: URL) -> Bool {
        guard let handle = FileHandle(forUpdatingAtPath: url.path) else { return false }
        try? handle.close()
        return true
    }

    private func appAsarIsPatched(_ appAsar: URL) -> Bool {
        guard let data = try? Data(contentsOf: appAsar, options: .mappedIfSafe) else { return false }
        let modelPickerData = Data(Self.modelPickerReplacement.utf8)
        let modelReasoningData = Data(Self.modelReasoningReplacement.utf8)
        let sidebarData = Data(Self.sidebarReplacement.utf8)
        let modelPatchFound = data.range(of: modelPickerData) != nil || data.range(of: modelReasoningData) != nil
        return modelPatchFound && data.range(of: sidebarData) != nil
    }

    // MARK: - Patch Operations

    private func patchExtractedBundles(at workdir: URL) throws -> Bool {
        let assetsDirectory = workdir
            .appendingPathComponent("webview", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
        guard fileManager.fileExists(atPath: assetsDirectory.path) else {
            throw PatchError.unsupportedCodexVersion("assets")
        }

        var changed = false
        changed = try patchBundle(
            in: assetsDirectory,
            preferredFilenameFragment: "model-queries",
            label: "model picker",
            patterns: [
                TextPatch(needle: Self.modelPickerNeedle, replacement: Self.modelPickerReplacement),
                TextPatch(needle: Self.modelReasoningNeedle, replacement: Self.modelReasoningReplacement)
            ]
        ) || changed

        changed = try patchBundle(
            in: assetsDirectory,
            preferredFilenameFragment: "app-server-manager-signals",
            label: "sidebar recent threads",
            patterns: [TextPatch(needle: Self.sidebarNeedle, replacement: Self.sidebarReplacement)]
        ) || changed

        return changed
    }

    private func patchBundle(
        in assetsDirectory: URL,
        preferredFilenameFragment: String,
        label: String,
        patterns: [TextPatch]
    ) throws -> Bool {
        let candidates = try jsCandidates(in: assetsDirectory, preferredFilenameFragment: preferredFilenameFragment)

        for candidate in candidates {
            let data = try Data(contentsOf: candidate)
            let text = String(decoding: data, as: UTF8.self)

            if patterns.contains(where: { text.contains($0.replacement) }) {
                return false
            }

            guard let pattern = patterns.first(where: { text.contains($0.needle) }) else { continue }

            let count = text.components(separatedBy: pattern.needle).count - 1
            guard count == 1 else {
                throw PatchError.unsupportedCodexVersion(label)
            }

            let updated = text.replacingOccurrences(of: pattern.needle, with: pattern.replacement)
            try updated.write(to: candidate, atomically: true, encoding: .utf8)
            return true
        }

        throw PatchError.unsupportedCodexVersion(label)
    }

    private func jsCandidates(in assetsDirectory: URL, preferredFilenameFragment: String) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: assetsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "js" {
            urls.append(url)
        }

        return urls.sorted { lhs, rhs in
            let lhsPreferred = lhs.lastPathComponent.contains(preferredFilenameFragment)
            let rhsPreferred = rhs.lastPathComponent.contains(preferredFilenameFragment)
            if lhsPreferred != rhsPreferred {
                return lhsPreferred
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func backupIfNeeded(source: URL, backupName: String) throws {
        let backupURL = runtimeDirectory.appendingPathComponent(backupName)
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        try fileManager.copyItem(at: source, to: backupURL)
    }

    private func backupVersionedAsar(_ appAsar: URL) throws {
        let hash = try sha256Hex(of: appAsar)
        let suffix = String(hash.prefix(12))
        let backupURL = runtimeDirectory.appendingPathComponent("app.asar.before-quotio-codex-desktop-patch.\(suffix)")
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        try fileManager.copyItem(at: appAsar, to: backupURL)
    }

    private func updateAppAsarIntegrity(appAsar: URL, infoPlist: URL) throws {
        let headerHash = try asarHeaderHash(appAsar)
        let data = try Data(contentsOf: infoPlist)
        guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              var integrity = plist["ElectronAsarIntegrity"] as? [String: Any],
              var resource = integrity["Resources/app.asar"] as? [String: Any] else {
            throw PatchError.invalidInfoPlist(infoPlist.path)
        }

        resource["hash"] = headerHash
        integrity["Resources/app.asar"] = resource
        plist["ElectronAsarIntegrity"] = integrity

        let updated = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try updated.write(to: infoPlist, options: .atomic)
    }

    private func asarHeaderHash(_ appAsar: URL) throws -> String {
        let data = try Data(contentsOf: appAsar, options: .mappedIfSafe)
        guard data.count >= 16 else { throw PatchError.invalidAsarHeader }

        let jsonSize = Int(data.withUnsafeBytes { pointer in
            pointer.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
        })
        guard data.count >= 16 + jsonSize else { throw PatchError.invalidAsarHeader }

        let headerData = data.subdata(in: 16..<(16 + jsonSize))
        return sha256Hex(headerData)
    }

    private func sha256Hex(of url: URL) throws -> String {
        try sha256Hex(Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Commands

    private func quitCodexDesktop() async {
        let script = "tell application \"Codex\" to if it is running then quit"
        _ = await CLIExecutor.shared.execute(
            command: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 10
        )
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private func resignCodexApp(_ codexApp: URL) async throws {
        try await run(
            command: "/usr/bin/codesign",
            arguments: ["--force", "--deep", "--sign", "-", codexApp.path],
            timeout: 120
        )
    }

    private func runCLI(name: String, arguments: [String], timeout: TimeInterval) async throws {
        guard let binary = await CLIExecutor.shared.findBinary(named: name) else {
            throw PatchError.commandFailed("\(name) not found.")
        }
        try await run(command: binary, arguments: arguments, timeout: timeout)
    }

    private func run(command: String, arguments: [String], timeout: TimeInterval) async throws {
        let result = await CLIExecutor.shared.execute(
            command: command,
            arguments: arguments,
            timeout: timeout
        )
        guard result.success else {
            throw PatchError.commandFailed(result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
