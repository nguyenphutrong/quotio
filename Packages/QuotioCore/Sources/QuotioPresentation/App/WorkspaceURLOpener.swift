import AppKit
import QuotioApplication

@MainActor
public struct WorkspaceURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
