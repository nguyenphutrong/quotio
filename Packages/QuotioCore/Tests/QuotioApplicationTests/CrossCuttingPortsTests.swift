import Foundation
import XCTest
@testable import QuotioApplication

final class CrossCuttingPortsTests: XCTestCase {
    func testFeatureCanReceiveCrossCuttingPortsWithoutConcretePlatformDependencies() async throws {
        let logger = RecordingLogger()
        let sleeper = ImmediateSleeper()
        let cancellation = CancellationRecorder()

        await logger.write(.info, message: "started")
        await sleeper.sleep(for: .seconds(1))
        await cancellation.cancelForTermination()

        let messages = await logger.messages
        let durations = await sleeper.durations
        let didCancel = await cancellation.didCancel
        XCTAssertEqual(messages, ["started"])
        XCTAssertEqual(durations, [.seconds(1)])
        XCTAssertTrue(didCancel)
    }
}

private actor RecordingLogger: ApplicationLogging {
    private(set) var messages: [String] = []

    func write(_ level: ApplicationLogLevel, message: String) {
        messages.append(message)
    }
}

private actor ImmediateSleeper: Sleeping {
    private(set) var durations: [Duration] = []

    func sleep(for duration: Duration) {
        durations.append(duration)
    }
}

private actor CancellationRecorder: LifecycleCancelling {
    private(set) var didCancel = false

    func cancelForTermination() {
        didCancel = true
    }
}
