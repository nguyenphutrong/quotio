import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class QuotaHistoryServiceModel {
    public private(set) var availability = QuotaHistoryAvailability(hostID: nil, connected: false, canRead: false, canWrite: false)
    public private(set) var recordingEnabled: Bool?
    public private(set) var error: QuotaHistoryError?
    public private(set) var isWorking = false
    public private(set) var changeRevision = 0
    @ObservationIgnored private let useCases: QuotaHistoryUseCases
    @ObservationIgnored private let coordinator: any QuotaCoordinating
    @ObservationIgnored private var generation = UUID()

    public init(useCases: QuotaHistoryUseCases, coordinator: any QuotaCoordinating) {
        self.useCases = useCases; self.coordinator = coordinator
    }
    public func makeScreen(accountID: String, provider: QuotaProvider) -> QuotaHistoryScreenModel {
        .init(accountID: accountID, useCases: useCases, coordinator: coordinator, provider: provider)
    }
    public func loadSettings() async {
        let token = UUID()
        generation = token
        let next = await useCases.reader.historyAvailability()
        guard generation == token, !Task.isCancelled else { return }
        if availability.hostID != next.hostID { recordingEnabled = nil }
        availability = next
        guard availability.connected else { recordingEnabled = nil; error = .offline; return }
        guard availability.canRead else { recordingEnabled = nil; error = availability.readFailure ?? .unsupported; return }
        let host = availability.hostID
        do {
            let enabled = try await useCases.manager.historyRecordingEnabled()
            guard generation == token, !Task.isCancelled, host == (await useCases.reader.historyAvailability()).hostID else { return }
            recordingEnabled = enabled; error = nil
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            recordError(error)
        }
    }
    public func setRecording(_ enabled: Bool) async {
        guard availability.connected, availability.canWrite, !isWorking else { return }
        let token = generation
        let host = availability.hostID
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            let value = try await useCases.setRecording(enabled: enabled)
            guard generation == token, host == (await useCases.reader.historyAvailability()).hostID else { return }
            recordingEnabled = value; changeRevision += 1
        } catch {
            guard generation == token else { return }
            recordError(error)
        }
    }
    public func clearAll() async {
        guard availability.connected, availability.canWrite, !isWorking else { return }
        let token = generation
        let host = availability.hostID
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            try await useCases.clear()
            guard generation == token, host == (await useCases.reader.historyAvailability()).hostID else { return }
            changeRevision += 1
        } catch {
            guard generation == token else { return }
            recordError(error)
        }
    }
    private func recordError(_ value: any Error) {
        error = value as? QuotaHistoryError ?? .requestFailed
        if error == .offline { availability = .init(hostID: availability.hostID, connected: false, canRead: availability.canRead, canWrite: availability.canWrite) }
    }
}
