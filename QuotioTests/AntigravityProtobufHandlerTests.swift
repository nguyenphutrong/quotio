import XCTest
@testable import Quotio

final class AntigravityProtobufHandlerTests: XCTestCase {
    func testExtractOAuthInfoRejectsOverflowingCandidateLengthWithoutCrashing() throws {
        let data = Data([0x32] + Array(repeating: 0xFF, count: 9) + [0x01, 0x00])

        let result = try AntigravityProtobufHandler.extractOAuthInfo(base64Data: data.base64EncodedString())

        XCTAssertNil(result.accessToken)
        XCTAssertNil(result.refreshToken)
        XCTAssertNil(result.expiry)
    }

    func testFindFieldRejectsLengthBeyondRemainingData() {
        let data = Data([0x0A, 0x05, 0x01])

        XCTAssertThrowsError(try AntigravityProtobufHandler.findField(data, targetField: 1))
    }

    func testReadVarintRejectsMoreThanTenBytes() {
        let data = Data(repeating: 0x80, count: 11)

        XCTAssertThrowsError(try AntigravityProtobufHandler.readVarint(data, offset: 0))
    }

    func testExtractOAuthInfoHandlesShortInput() throws {
        let data = Data([0x32, 0x01, 0x00])

        let result = try AntigravityProtobufHandler.extractOAuthInfo(base64Data: data.base64EncodedString())

        XCTAssertNil(result.accessToken)
        XCTAssertNil(result.refreshToken)
        XCTAssertNil(result.expiry)
    }

    func testExtractOAuthInfoPreservesValidOldFormatPayload() throws {
        let accessToken = "ya29." + String(repeating: "a", count: 120)
        let refreshToken = "refresh-token"
        let expiry: Int64 = 1_800_000_000
        let data = AntigravityProtobufHandler.createOAuthField(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: expiry
        )

        let result = try AntigravityProtobufHandler.extractOAuthInfo(base64Data: data.base64EncodedString())

        XCTAssertEqual(result.accessToken, accessToken)
        XCTAssertEqual(result.refreshToken, refreshToken)
        XCTAssertEqual(result.expiry, expiry)
    }
}
