import Foundation
import QuotioApplication

public struct LocalQuotaCredentialFileReader: QuotaCredentialFileReading {
  public init() {}

  public func read(path: String) async -> Data? {
    let expanded = NSString(string: path).expandingTildeInPath
    return try? Data(contentsOf: URL(fileURLWithPath: expanded))
  }
}
