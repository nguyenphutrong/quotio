import XCTest
@testable import QuotioDomain

final class ProxyModelsTests: XCTestCase {
    func testEndpointUsesIPv4LoopbackForManagementAndLocalhostForClients() throws {
        let endpoint = try ProxyEndpoint(port: 8317)

        XCTAssertEqual(endpoint.baseURL, "http://127.0.0.1:8317")
        XCTAssertEqual(endpoint.managementURL, "http://127.0.0.1:8317/v0/management")
        XCTAssertEqual(endpoint.clientEndpoint, "http://localhost:8317/v1")
    }

    func testEndpointRejectsZeroPort() {
        XCTAssertThrowsError(try ProxyEndpoint(port: 0)) { error in
            XCTAssertEqual(error as? ProxyEndpointError, .invalidPort)
        }
    }

    func testLifecycleStateMachineAcceptsStartAndStopSequence() throws {
        var stateMachine = ProxyLifecycleStateMachine()

        try stateMachine.transition(to: .starting)
        try stateMachine.transition(to: .active)
        try stateMachine.transition(to: .stopping)
        try stateMachine.transition(to: .idle)

        XCTAssertEqual(stateMachine.state, .idle)
    }

    func testLifecycleStateMachineAcceptsUnexpectedActiveProcessExit() throws {
        var stateMachine = ProxyLifecycleStateMachine(state: .active)

        try stateMachine.transition(to: .idle)

        XCTAssertEqual(stateMachine.state, .idle)
    }

    func testLifecycleStateMachineRejectsIllegalTransitionWithoutChangingState() {
        var stateMachine = ProxyLifecycleStateMachine(state: .active)

        XCTAssertThrowsError(try stateMachine.transition(to: .testing)) { error in
            XCTAssertEqual(
                error as? ProxyLifecycleTransitionError,
                .illegal(from: .active, to: .testing)
            )
        }
        XCTAssertEqual(stateMachine.state, .active)
    }
}
