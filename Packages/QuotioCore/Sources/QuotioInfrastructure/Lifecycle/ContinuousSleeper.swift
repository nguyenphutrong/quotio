import QuotioApplication

public struct ContinuousSleeper: Sleeping {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
