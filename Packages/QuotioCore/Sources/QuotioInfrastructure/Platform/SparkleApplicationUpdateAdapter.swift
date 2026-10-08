import Foundation
import QuotioApplication
import QuotioDomain
import Sparkle

@MainActor
public final class SparkleApplicationUpdateAdapter: NSObject, ApplicationUpdateChecking {
    public let policy: ApplicationUpdatePolicy
    private var updaterController: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { updaterController?.updater }
    private var didChangeHandler: (@MainActor () -> Void)?
    private let channelLock = NSLock()
    private nonisolated(unsafe) var allowsPrereleaseUpdates = false

    public private(set) var isInitialized = false
    public private(set) var isChecking = false

    public init(policy: ApplicationUpdatePolicy = .sparkle) {
        self.policy = policy
        super.init()
    }

    public var canCheck: Bool {
        isInitialized && (updater?.canCheckForUpdates ?? false)
    }

    public var lastCheckDate: Date? {
        updater?.lastUpdateCheckDate
    }

    public var automaticallyChecksForUpdates: Bool {
        get { policy == .sparkle && (updater?.automaticallyChecksForUpdates ?? true) }
        set { if policy == .sparkle { updater?.automaticallyChecksForUpdates = newValue } }
    }

    public func setAllowsPrereleaseUpdates(_ allowed: Bool) {
        guard policy == .sparkle else { return }
        channelLock.withLock {
            allowsPrereleaseUpdates = allowed
        }
    }

    public func initializeIfNeeded() {
        guard policy == .sparkle, !isInitialized else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        isInitialized = true
        didChangeHandler?()
    }

    public func checkForUpdates() {
        initializeIfNeeded()
        guard canCheck else { return }
        isChecking = true
        didChangeHandler?()
        updater?.checkForUpdates()
    }

    public func checkForUpdatesInBackground() {
        initializeIfNeeded()
        updater?.checkForUpdatesInBackground()
        didChangeHandler?()
    }

    public func resetUpdateCycle() {
        updater?.resetUpdateCycle()
        didChangeHandler?()
    }

    public func setDidChangeHandler(_ handler: (@MainActor () -> Void)?) {
        didChangeHandler = handler
    }
}

extension SparkleApplicationUpdateAdapter: SPUUpdaterDelegate {
    nonisolated public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channelLock.withLock {
            allowsPrereleaseUpdates ? Set(["beta"]) : Set()
        }
    }

    nonisolated public func updaterDidFinishUpdateCycleForUpdateCheck(_ updater: SPUUpdater) throws {
        Task { @MainActor [weak self] in
            self?.isChecking = false
            self?.didChangeHandler?()
        }
    }

    nonisolated public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.isChecking = false
            self?.didChangeHandler?()
        }
    }
}
