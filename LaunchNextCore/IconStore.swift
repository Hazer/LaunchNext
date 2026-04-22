import Foundation
import AppKit

public final class IconStore {
    public static let shared = IconStore()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
    }

    public func icon(for app: AppInfo) -> NSImage {
        if PerformanceMode.current == .full {
            return app.icon
        }
        return icon(forPath: app.url.path)
    }

    public func icon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: key)
        return icon
    }

    public func clear() {
        cache.removeAllObjects()
    }
}

public final class FolderPreviewCache {
    public static let shared = FolderPreviewCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 120
    }

    public func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    public func store(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    public func clear() {
        cache.removeAllObjects()
    }
}
