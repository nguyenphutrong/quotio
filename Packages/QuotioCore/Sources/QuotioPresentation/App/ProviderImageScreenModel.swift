import AppKit
import Observation

@MainActor
@Observable
public final class ProviderImageScreenModel {
    @ObservationIgnored private let loadImage: (String, CGFloat?) -> NSImage?

    public init(loadImage: @escaping (String, CGFloat?) -> NSImage?) {
        self.loadImage = loadImage
    }

    public func image(named name: String, size: CGFloat? = nil) -> NSImage? {
        loadImage(name, size)
    }
}
