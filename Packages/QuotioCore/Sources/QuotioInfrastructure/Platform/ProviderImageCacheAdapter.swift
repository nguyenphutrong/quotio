import AppKit

@MainActor
public final class ProviderImageCacheAdapter {
    private let cache = NSCache<NSString, NSImage>()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private nonisolated(unsafe) var activityObservers: [NSObjectProtocol] = []

    public init() {
        cache.countLimit = 50
        cache.totalCostLimit = 10 * 1_024 * 1_024
        installMemoryHandlers()
    }

    deinit {
        memoryPressureSource?.cancel()
        for observer in activityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func image(named name: String, size: CGFloat? = nil) -> NSImage? {
        let key = size.map { "\(name)_\(Int($0))" } ?? name
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let original = NSImage(named: name) else { return nil }

        let image: NSImage
        if let size, size < min(original.size.width, original.size.height) {
            let targetSize = NSSize(width: size, height: size)
            image = NSImage(size: targetSize)
            image.lockFocus()
            original.draw(
                in: NSRect(origin: .zero, size: targetSize),
                from: NSRect(origin: .zero, size: original.size),
                operation: .copy,
                fraction: 1
            )
            image.unlockFocus()
        } else {
            image = original
        }

        let cost = Int(image.size.width) * Int(image.size.height) * 4
        cache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    public func clear() {
        cache.removeAllObjects()
    }

    private func installMemoryHandlers() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        let cache = cache
        source.setEventHandler {
            cache.removeAllObjects()
        }
        memoryPressureSource = source
        source.resume()

        activityObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cache.countLimit = 20 }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cache.countLimit = 50 }
            },
        ]
    }
}
