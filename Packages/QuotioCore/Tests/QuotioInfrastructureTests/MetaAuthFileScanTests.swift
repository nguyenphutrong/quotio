import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

/// The proxy's Meta login has to be visible to Quotio in both ways it reads that
/// directory: by the `type` field inside the file, and by the filename alone when the
/// contents cannot be parsed.
final class MetaAuthFileScanTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testAMetaAuthFileIsReadAsMuseFromItsTypeField() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("""
      {"type":"meta","auth_kind":"oauth","access_token":"account-token",
      "api_key":"LLM|0|model-key","email":"developer@example.test"}
      """.utf8)
      .write(to: directory.appendingPathComponent("meta-developer-abcd.json"))

    let files = await FileAuthFileRepository(authDirectory: directory).scanAllAuthFiles()

    XCTAssertEqual(files.map(\.providerID.rawValue), [QuotaProvider.muse.rawValue])
    XCTAssertEqual(files.first?.email, "developer@example.test")
  }

  func testAMetaAuthFileIsStillRecognisedFromItsNameWhenTheContentsAreUnreadable() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("not json".utf8)
      .write(to: directory.appendingPathComponent("meta-developer@example.test.json"))

    let files = await FileAuthFileRepository(authDirectory: directory).scanAllAuthFiles()

    XCTAssertEqual(files.map(\.providerID.rawValue), [QuotaProvider.muse.rawValue])
  }

}
