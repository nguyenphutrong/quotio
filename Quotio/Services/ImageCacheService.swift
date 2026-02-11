//
//  ImageCacheService.swift
//  Quotio
//
//  NSCache-based image caching with memory pressure eviction.
//  Reduces memory usage by caching resized images and responding to system memory warnings.
//

import AppKit
import Foundation

/// Thread-safe image cache with automatic memory pressure eviction
final class ImageCacheService: @unchecked Sendable {
    static let shared = ImageCacheService()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "dev.quotio.desktop.imagecache", attributes: .concurrent)

    /// Retained memory pressure source to prevent deallocation
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        cache.countLimit = 50
        cache.totalCostLimit = 10 * 1024 * 1024
        setupMemoryPressureHandler()
    }

    deinit {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    // MARK: - Public API

    /// Get a cached image or load and cache it
    /// - Parameters:
    ///   - name: Asset catalog image name
    ///   - size: Target size for the image (images are cached at this size)
    /// - Returns: The image, or nil if not found
    func image(named name: String, size: CGFloat? = nil) -> NSImage? {
        let cacheKey = makeCacheKey(name: name, size: size)

        // Check cache first
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached
        }

        // Load from asset catalog
        guard let original = NSImage(named: name) else {
            return nil
        }

        // Resize if needed and cache
        let imageToCache: NSImage
        if let targetSize = size, targetSize < min(original.size.width, original.size.height) {
            imageToCache = resized(image: original, to: targetSize)
        } else {
            imageToCache = original
        }

        // Estimate cost (bytes)
        let cost = estimateCost(for: imageToCache)
        cache.setObject(imageToCache, forKey: cacheKey as NSString, cost: cost)

        return imageToCache
    }

    /// Clear all cached images (called on memory pressure)
    func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Private Helpers

    private func makeCacheKey(name: String, size: CGFloat?) -> String {
        if let size = size {
            return "\(name)_\(Int(size))"
        }
        return name
    }

    private func resized(image: NSImage, to targetSize: CGFloat) -> NSImage {
        let newSize = NSSize(width: targetSize, height: targetSize)
        let newImage = NSImage(size: newSize)

        newImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()

        return newImage
    }

    private func estimateCost(for image: NSImage) -> Int {
        // Estimate: width * height * 4 bytes per pixel (RGBA)
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        return width * height * 4
    }

    private func setupMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        // Capture cache directly since NSCache is thread-safe
        let cache = self.cache
        source.setEventHandler {
            cache.removeAllObjects()
        }
        memoryPressureSource = source
        source.resume()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.countLimit = 20
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.countLimit = 50
        }
    }
}
