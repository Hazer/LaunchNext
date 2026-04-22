import Foundation
import AppKit
import Combine

/// App cache manager - caches app icons, app info, and grid layout data for performance
final class AppCacheManager: ObservableObject {
    static let shared = AppCacheManager()
    
    // MARK: - Cache storage
    private var iconCache: [String: NSImage] = [:]
    private var appInfoCache: [String: AppInfo] = [:]
    private var gridLayoutCache: [String: Any] = [:]
    private let cacheLock = NSLock()
    
    // MARK: - cacheconfig
    private let maxIconCacheSize = 200
    private let maxAppInfoCacheSize = 300
    private var iconCacheOrder: [String] = [] // Mutable array for proper LRU
    
    // MARK: - Cache state
    @Published var isCacheValid = false
    @Published var lastCacheUpdate = Date.distantPast
    @Published var cacheSize: Int = 0
    // MARK: - Cache key generation
    private let cacheKeyGenerator = CacheKeyGenerator()

    private init() {}

    private var isLeanMode: Bool {
        PerformanceMode.current == .lean
    }
    // MARK: - Public interface
    
    /// Generate app cache - call after app startup or scan
    func generateCache(from apps: [AppInfo],
                       items: [LaunchpadItem],
                       itemsPerPage: Int,
                       columns: Int,
                       rows: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Clear old cache
            self.clearAllCaches()
            
            // Collect all apps needing cache, including apps inside folders
            var allApps: [AppInfo] = []
            allApps.append(contentsOf: apps)
            
            // Extract folder apps from items
            for item in items {
                if case let .folder(folder) = item {
                    allApps.append(contentsOf: folder.apps)
                }
            }
            
            // Deduplicate to avoid caching same apps repeatedly
            var uniqueApps: [AppInfo] = []
            var seenPaths = Set<String>()
            for app in allApps {
                if !seenPaths.contains(app.url.path) {
                    seenPaths.insert(app.url.path)
                    uniqueApps.append(app)
                }
            }
            
            // cache app info
            self.cacheAppInfos(uniqueApps)
            
            // cacheappicon
            if !self.isLeanMode {
                self.cacheAppIcons(uniqueApps)
            }
            
            // cache grid layout data
            self.cacheGridLayout(items,
                                 itemsPerPage: itemsPerPage,
                                 columns: columns,
                                 rows: rows)
            
            DispatchQueue.main.async {
                self.isCacheValid = true
                self.lastCacheUpdate = Date()
                self.calculateCacheSize()
        
            }
        }
    }
    
    /// Get cached app icon
    func getCachedIcon(for appPath: String) -> NSImage? {
        if isLeanMode {
            return nil
        }
        let key = cacheKeyGenerator.generateIconKey(for: appPath)
        
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let icon = iconCache[key] {
            if let index = iconCacheOrder.firstIndex(of: key) {
                iconCacheOrder.remove(at: index)
                iconCacheOrder.append(key)
            }
            return icon
        } else {
            return nil
        }
    }
    
    /// Get cached app info
    func getCachedAppInfo(for appPath: String) -> AppInfo? {
        let key = cacheKeyGenerator.generateAppInfoKey(for: appPath)
        return appInfoCache[key]
    }
    
    /// Get cached grid layout data
    func getCachedGridLayout(for layoutKey: String) -> Any? {
        let key = cacheKeyGenerator.generateGridLayoutKey(for: layoutKey)
        return gridLayoutCache[key]
    }
    
    /// Preload app icons to cache
    func preloadIcons(for appPaths: [String]) {
        if isLeanMode {
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            for path in appPaths {
                if self.getCachedIcon(for: path) == nil {
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    let key = self.cacheKeyGenerator.generateIconKey(for: path)
                    self.cacheLock.lock()
                    self.iconCache[key] = icon
                    self.iconCacheOrder.append(key)
                    if self.iconCache.count > self.maxIconCacheSize {
                        if let oldestKey = self.iconCacheOrder.first {
                            self.iconCache.removeValue(forKey: oldestKey)
                            self.iconCacheOrder.removeFirst()
                        }
                    }
                    self.cacheLock.unlock()
                }
            }
            
            DispatchQueue.main.async {
                self.calculateCacheSize()
            }
        }
    }
    
    /// Smart preload: preload current and adjacent pages' icon
    func smartPreloadIcons(for items: [LaunchpadItem], currentPage: Int, itemsPerPage: Int) {
        if isLeanMode {
            return
        }
        let startIndex = max(0, (currentPage - 1) * itemsPerPage)
        let endIndex = min(items.count, (currentPage + 2) * itemsPerPage)
        
        let relevantItems = Array(items[startIndex..<endIndex])
        let appPaths = relevantItems.compactMap { item -> String? in
            if case let .app(app) = item {
                return app.url.path
            }
            return nil
        }
        
        preloadIcons(for: appPaths)
    }
    
    /// Clear all caches
    func clearAllCaches() {
        cacheLock.lock()
        iconCache.removeAll()
        appInfoCache.removeAll()
        gridLayoutCache.removeAll()
        iconCacheOrder.removeAll()
        cacheLock.unlock()
        
        DispatchQueue.main.async {
            self.isCacheValid = false
            self.cacheSize = 0
        }
    }
    
    /// Clear expired cache
    func clearExpiredCache() {
        let now = Date()
        let cacheAgeThreshold: TimeInterval = 24 * 60 * 60 // 24hours
        
        if now.timeIntervalSince(lastCacheUpdate) > cacheAgeThreshold {
            clearAllCaches()
        }
    }
    
    /// Manual cache refresh
    func refreshCache(from apps: [AppInfo],
                      items: [LaunchpadItem],
                      itemsPerPage: Int,
                      columns: Int,
                      rows: Int) {
        // Collect all apps needing cache, including apps inside folders
        var allApps: [AppInfo] = []
        allApps.append(contentsOf: apps)
        
        // Extract folder apps from items
        for item in items {
            if case let .folder(folder) = item {
                allApps.append(contentsOf: folder.apps)
            }
        }
        
        // Deduplicate to avoid caching same apps repeatedly
        var uniqueApps: [AppInfo] = []
        var seenPaths = Set<String>()
        for app in allApps {
            if !seenPaths.contains(app.url.path) {
                seenPaths.insert(app.url.path)
                uniqueApps.append(app)
            }
        }
        
        generateCache(from: uniqueApps,
                      items: items,
                      itemsPerPage: itemsPerPage,
                      columns: columns,
                      rows: rows)
    }
    
    // MARK: - Private methods
    
    private func cacheAppInfos(_ apps: [AppInfo]) {
        cacheLock.lock()
        for app in apps {
            let key = cacheKeyGenerator.generateAppInfoKey(for: app.url.path)
            appInfoCache[key] = app
        }
        cacheLock.unlock()
    }
    
    private func cacheAppIcons(_ apps: [AppInfo]) {
        if isLeanMode {
            return
        }
        cacheLock.lock()
        for app in apps {
            let key = cacheKeyGenerator.generateIconKey(for: app.url.path)
            if let existingIndex = iconCacheOrder.firstIndex(of: key) {
                iconCacheOrder.remove(at: existingIndex)
            }
            iconCache[key] = app.icon
            iconCacheOrder.append(key)
            if iconCache.count > maxIconCacheSize {
                if let oldestKey = iconCacheOrder.first {
                    iconCache.removeValue(forKey: oldestKey)
                    iconCacheOrder.removeFirst()
                }
            }
        }
        cacheLock.unlock()
    }
    
    private func cacheGridLayout(_ items: [LaunchpadItem],
                                 itemsPerPage: Int,
                                 columns: Int,
                                 rows: Int) {
        // cache grid layout computed data
        let layoutData = GridLayoutCacheData(
            totalItems: items.count,
            itemsPerPage: itemsPerPage,
            columns: columns,
            rows: rows,
            pageCount: (items.count + max(itemsPerPage, 1) - 1) / max(itemsPerPage, 1)
        )
        let pageInfo = calculatePageInfo(for: items, itemsPerPage: itemsPerPage)
        let key = cacheKeyGenerator.generateGridLayoutKey(for: "main")
        let pageKey = cacheKeyGenerator.generateGridLayoutKey(for: "pages")
        cacheLock.lock()
        gridLayoutCache[key] = layoutData
        gridLayoutCache[pageKey] = pageInfo
        cacheLock.unlock()
        
    }
    
    /// Calculate page info
    private func calculatePageInfo(for items: [LaunchpadItem], itemsPerPage: Int) -> [PageInfo] {
        let sanitizedItemsPerPage = max(itemsPerPage, 1)
        let pageCount = (items.count + sanitizedItemsPerPage - 1) / sanitizedItemsPerPage

        var pages: [PageInfo] = []

        for pageIndex in 0..<pageCount {
            let startIndex = pageIndex * sanitizedItemsPerPage
            let endIndex = min(startIndex + sanitizedItemsPerPage, items.count)
            let pageItems = Array(items[startIndex..<endIndex])
            
            let appCount = pageItems.filter { if case .app = $0 { return true } else { return false } }.count
            let folderCount = pageItems.filter { if case .folder = $0 { return true } else { return false } }.count
            let emptyCount = pageItems.filter { if case .empty = $0 { return true } else { return false } }.count
            
            let pageInfo = PageInfo(
                pageIndex: pageIndex,
                startIndex: startIndex,
                endIndex: endIndex,
                appCount: appCount,
                folderCount: folderCount,
                emptyCount: emptyCount
            )
            
            pages.append(pageInfo)
        }
        
        return pages
    }
    
    private func calculateCacheSize() {
        cacheLock.lock()
        let iconSize = iconCache.count
        let appInfoSize = appInfoCache.count
        let gridLayoutSize = gridLayoutCache.count
        cacheLock.unlock()
        cacheSize = iconSize + appInfoSize + gridLayoutSize
    }

    
    /// Get performance stats
    var performanceStats: PerformanceStats {
        return PerformanceStats(cacheSize: cacheSize)
    }
}

// MARK: - Cache key generator

private struct CacheKeyGenerator {
    func generateIconKey(for appPath: String) -> String {
        return "icon_\(appPath.hashValue)"
    }
    
    func generateAppInfoKey(for appPath: String) -> String {
        return "appinfo_\(appPath.hashValue)"
    }
    
    func generateGridLayoutKey(for layoutKey: String) -> String {
        return "grid_\(layoutKey.hashValue)"
    }
}

// MARK: - Grid layout cache data structure

private struct GridLayoutCacheData {
    let totalItems: Int
    let itemsPerPage: Int
    let columns: Int
    let rows: Int
    let pageCount: Int
}

private struct PageInfo {
    let pageIndex: Int
    let startIndex: Int
    let endIndex: Int
    let appCount: Int
    let folderCount: Int
    let emptyCount: Int
}

// MARK: - Cache stats

extension AppCacheManager {
    var cacheStatistics: CacheStatistics {
        return CacheStatistics(
            iconCacheSize: iconCache.count,
            appInfoCacheSize: appInfoCache.count,
            gridLayoutCacheSize: gridLayoutCache.count,
            totalCacheSize: cacheSize,
            isCacheValid: isCacheValid,
            lastUpdate: lastCacheUpdate
        )
    }
}

struct CacheStatistics {
    let iconCacheSize: Int
    let appInfoCacheSize: Int
    let gridLayoutCacheSize: Int
    let totalCacheSize: Int
    let isCacheValid: Bool
    let lastUpdate: Date
}

struct PerformanceStats {
    let cacheSize: Int
}
