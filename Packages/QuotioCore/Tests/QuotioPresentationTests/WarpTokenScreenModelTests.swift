import Foundation
import XCTest

@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class WarpTokenScreenModelTests: XCTestCase {
    func testLoadAndMutationsUseRepositoryWithoutDiscardingInMemoryChangesOnFailure() async {
        let original = WarpToken(name: "Work", token: "old")
        let repository = RecordingWarpTokenRepository(tokens: [original])
        let model = WarpTokenScreenModel(repository: repository)

        await model.load()
        XCTAssertEqual(model.tokens, [original])

        await repository.setSaveFailure(true)
        await model.add(name: "Personal", token: "new")
        XCTAssertEqual(model.tokens.map(\.name), ["Work", "Personal"])
        XCTAssertNotNil(model.errorMessage)

        await repository.setSaveFailure(false)
        await model.delete(id: original.id)
        let savedNames = await repository.savedTokens()?.map(\.name)
        XCTAssertEqual(savedNames, ["Personal"])
        XCTAssertNil(model.errorMessage)
    }
}

private actor RecordingWarpTokenRepository: WarpTokenRepository {
    private let initialTokens: [WarpToken]
    private var shouldFailSave = false
    private var lastSavedTokens: [WarpToken]?

    init(tokens: [WarpToken]) {
        initialTokens = tokens
    }

    func load() -> [WarpToken] {
        initialTokens
    }

    func save(_ tokens: [WarpToken]) throws {
        if shouldFailSave {
            throw TestError.writeFailed
        }
        lastSavedTokens = tokens
    }

    func setSaveFailure(_ shouldFail: Bool) {
        shouldFailSave = shouldFail
    }

    func savedTokens() -> [WarpToken]? {
        lastSavedTokens
    }

    private enum TestError: Error {
        case writeFailed
    }
}
