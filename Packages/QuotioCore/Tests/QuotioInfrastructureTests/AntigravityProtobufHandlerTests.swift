import XCTest
@testable import QuotioInfrastructure

final class AntigravityProtobufHandlerTests: XCTestCase {
    func testExtractOAuthInfoRejectsOverflowingCandidateLengthWithoutCrashing() throws {
        let data = Data([0x32] + Array(repeating: 0xFF, count: 9) + [0x01, 0x00])

        XCTAssertThrowsError(
            try AntigravityProtobuf.extractLegacyOAuthCredential(
                from: data.base64EncodedString()
            )
        )
    }

    func testFindFieldRejectsLengthBeyondRemainingData() {
        let data = Data([0x0A, 0x05, 0x01])

        XCTAssertThrowsError(try AntigravityProtobuf.findField(1, in: data))
    }

    func testReadVarintRejectsMoreThanTenBytes() {
        let data = Data(repeating: 0x80, count: 11)

        XCTAssertThrowsError(try AntigravityProtobuf.readVarint(data, at: 0))
    }

    func testExtractOAuthInfoHandlesShortInput() throws {
        let data = Data([0x32, 0x01, 0x00])

        XCTAssertThrowsError(
            try AntigravityProtobuf.extractLegacyOAuthCredential(
                from: data.base64EncodedString()
            )
        )
    }

    func testExtractOAuthInfoPreservesValidOldFormatPayload() throws {
        let accessToken = "ya29." + String(repeating: "a", count: 120)
        let refreshToken = "refresh-token"
        let expiry: Int64 = 1_800_000_000
        let data = AntigravityProtobuf.field(
            6,
            AntigravityProtobuf.oauth(accessToken, refreshToken, expiry)
        )

        let result = try AntigravityProtobuf.extractLegacyOAuthCredential(
            from: data.base64EncodedString()
        )

        XCTAssertEqual(result.accessToken, accessToken)
        XCTAssertEqual(result.refreshToken, refreshToken)
        XCTAssertEqual(result.expiry, expiry)
    }
}
