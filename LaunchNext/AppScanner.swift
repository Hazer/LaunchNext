import LaunchNextStrategies
import LaunchNextUtilities
import LaunchNextCore
import Foundation
import AppKit
import Combine
import SwiftData
import CoreServices

@MainActor
final class AppScanner {
    weak var delegate: (any AppStoreServiceDelegate)?

    // Snapshot of search paths captured at start of scan to avoid
    // accessing @MainActor-isolated computed property from background queues.
    private var cachedSearchPaths: [String] = []

    // MARK: - Auto rescan (FSEvents)

    private var fsEventStream: FSEventStreamRef?
    private var fsEventContextPointer: UnsafeMutableRawPointer?

    /// Wrapper for FSEventStream context that holds a weak reference to AppScanner,
    /// avoiding the retain cycle that passRetained(self) would create.
    private final class FSEventContextBox {
        weak var scanner: AppScanner?
        init(scanner: AppScanner) { self.scanner = scanner }
    }

    private var pendingChangedAppPaths: Set<String> = []
    private var pendingForceFullScan: Bool = false
    private let fullRescanThreshold: Int = 50
    private var fallbackScanTimer: DispatchSourceTimer?

    // State flags
    var hasPerformedInitialScan: Bool = false
    private var rescanWorkItem: DispatchWorkItem?

    // Background refresh queue and throttle
    let refreshQueue = DispatchQueue(label: "app.store.refresh", qos: .userInitiated)
    private let fsEventsQueue = DispatchQueue(label: "app.store.fsevents")

    // MARK: - Fallback periodic scan

    private static let fallbackScanInterval: TimeInterval = 5 * 60 // 5 minutes

    init(delegate: any AppStoreServiceDelegate) {
        self.delegate = delegate
    }

    // MARK: - Scanning

    func scanApplications(loadPersistedOrder: Bool = true) {
        guard let delegate else { return }
        let paths = cachedSearchPaths
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AppInfo] = []
            var seenPaths = Set<String>()

            for path in paths {
                let url = URL(fileURLWithPath: path)

                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let item as URL in enumerator {
                        let resolved = item.resolvingSymlinksInPath()
                        guard resolved.pathExtension == "app",
                              self.isValidApp(at: resolved),
                              !self.isInsideAnotherApp(resolved) else { continue }
                        if !seenPaths.contains(resolved.path) {
                            seenPaths.insert(resolved.path)
                            found.append(delegate.appInfo(from: resolved, loadIcon: false))
                        }
                    }
                }
            }

            let sorted = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                delegate.applyScanResults(sorted, missing: delegate.currentMissingPlaceholders, hidden: delegate.currentHiddenAppPaths)
                delegate.pruneHiddenAppsFromAppList()
                if loadPersistedOrder {
                    delegate.persistenceRebuildItems()
                    delegate.persistenceLoadAllOrder()
                } else {
                    let newItems = delegate.filteredItemsRemovingHidden(from: sorted.map { .app($0) })
                    delegate.applyOrderedItems(newItems, folders: delegate.currentFolders)
                    delegate.persistenceSaveAllOrder()
                }
                delegate.refreshMissingPlaceholders()

                delegate.refreshCacheAfterScan()
            }
        }
    }

    /// Smart scan: maintain existing order, append new apps at the end, missing apps removed, auto-fill within pages
    func scanApplicationsWithOrderPreservation() {
        guard let delegate else { return }
        let paths = cachedSearchPaths
        let currentApps = delegate.currentApps
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AppInfo] = []
            var seenPaths = Set<String>()

            // Use concurrent queue to accelerate scanning
            let scanQueue = DispatchQueue(label: "app.scan", attributes: .concurrent)
            let group = DispatchGroup()
            let lock = NSLock()

            // Scan all apps
            for path in paths {
                group.enter()
                scanQueue.async {
                    let url = URL(fileURLWithPath: path)

                    if let enumerator = FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) {
                        var localFound: [AppInfo] = []
                        var localSeenPaths = Set<String>()

                        for case let item as URL in enumerator {
                            let resolved = item.resolvingSymlinksInPath()
                            guard resolved.pathExtension == "app",
                                  self.isValidApp(at: resolved),
                                  !self.isInsideAnotherApp(resolved) else { continue }
                            if !localSeenPaths.contains(resolved.path) {
                                localSeenPaths.insert(resolved.path)
                                localFound.append(delegate.appInfo(from: resolved, loadIcon: false))
                            }
                        }

                        // Thread-safe merge of results
                        lock.lock()
                        found.append(contentsOf: localFound)
                        seenPaths.formUnion(localSeenPaths)
                        lock.unlock()
                    }
                    group.leave()
                }
            }

            group.wait()

            // Deduplicate and sort - using safer method
            var uniqueApps: [AppInfo] = []
            var uniqueSeenPaths = Set<String>()

            for app in found {
                if !uniqueSeenPaths.contains(app.url.path) {
                    uniqueSeenPaths.insert(app.url.path)
                    uniqueApps.append(app)
                }
            }

            // Preserve existing app order, sort only new apps by name
            var newApps: [AppInfo] = []
            var existingAppPaths = Set<String>()
            let refreshedMap = Dictionary(uniqueKeysWithValues: uniqueApps.map { ($0.url.path, $0) })

            for app in currentApps {
                guard let refreshed = refreshedMap[app.url.path] else { continue }
                newApps.append(refreshed)
                existingAppPaths.insert(app.url.path)
            }

            let newAppPaths = uniqueApps.filter { !existingAppPaths.contains($0.url.path) }
            let sortedNewApps = newAppPaths.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            newApps.append(contentsOf: sortedNewApps)

            DispatchQueue.main.async {
                self.processScannedApplications(newApps)

                delegate.refreshCacheAfterScan()
            }
        }
    }

    /// Manually trigger full rescan (for manual refresh in settings)
    func forceFullRescan() {
        guard let delegate else { return }
        // Clear cache
        AppCacheManager.shared.clearAllCaches()

        hasPerformedInitialScan = false
        scanApplicationsWithOrderPreservation()
    }

    /// Process scanned apps, smart-match with existing order
    private func processScannedApplications(_ newApps: [AppInfo]) {
        guard let delegate else { return }
        // Save current items order and structure
        let currentItems = delegate.currentItems
        let currentApps = delegate.currentApps
        let currentFolders = delegate.currentFolders

        // Create new app list, but preserve existing order
        var updatedApps: [AppInfo] = []
        var newAppsToAdd: [AppInfo] = []
        var freshMap: [String: AppInfo] = [:]
        for app in newApps {
            freshMap[app.url.path] = app
        }

        // Step 1: Preserve existing order, refresh app info with latest scan results
        for app in currentApps {
            updatedApps.append(freshMap[app.url.path] ?? app)
        }

        // Sync update folder app objects, ensure name/icon timely refresh
        var updatedFolders = currentFolders
        for folderIndex in updatedFolders.indices {
            let refreshedApps = updatedFolders[folderIndex].apps.map { freshMap[$0.url.path] ?? $0 }
            updatedFolders[folderIndex].apps = refreshedApps
        }

        // Step 2: Find newly added apps (preserve order matching scan results)
        let existingPaths = Set(updatedApps.map { $0.url.path })
        for newApp in newApps where !existingPaths.contains(newApp.url.path) {
            newAppsToAdd.append(newApp)
        }

        // Step 3: Append new apps to the end, keep existing app order unchanged
        updatedApps.append(contentsOf: newAppsToAdd)

        // Update app list
        delegate.applyScanResults(updatedApps, missing: delegate.currentMissingPlaceholders, hidden: delegate.currentHiddenAppPaths)
        delegate.pruneHiddenAppsFromAppList()

        // Step 4: Smart-rebuild items list, preserve user order
        delegate.smartRebuildItemsWithOrderPreservation(currentItems: currentItems, newApps: newAppsToAdd)

        // Step 5: Auto-fill within pages
        delegate.compactItemsWithinPages()

        // Step 5.5: Sync missing placeholders based on latest disk state
        delegate.refreshMissingPlaceholders()

        // Step 6: Save new order
        delegate.persistenceSaveAllOrder()

        // Trigger UI update
        delegate.triggerFolderUpdate()
        delegate.triggerGridRefresh()
    }

    // MARK: - FSEvents wiring

    func startAutoRescan() {
        guard fsEventStream == nil else { return }

        guard let delegate else { return }
        let pathsToWatch = delegate.currentApplicationSearchPaths
        cachedSearchPaths = pathsToWatch
        guard !pathsToWatch.isEmpty else { return }

        let box = FSEventContextBox(scanner: self)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        fsEventContextPointer = UnsafeMutableRawPointer(ptr)
        var context = FSEventStreamContext(
            version: 0,
            info: fsEventContextPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, clientInfo, numEvents, eventPaths, eventFlags, _) in
            guard let info = clientInfo else { return }
            let box = Unmanaged<FSEventContextBox>.fromOpaque(info).takeUnretainedValue()
            guard let scanner = box.scanner else { return }

            guard numEvents > 0 else {
                scanner.handleFSEvents(paths: [], flagsPointer: eventFlags, count: 0)
                return
            }

            // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray of CFString
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let nsArray = cfArray as NSArray
            guard let pathsArray = nsArray as? [String] else { return }

            scanner.handleFSEvents(paths: pathsArray, flagsPointer: eventFlags, count: numEvents)
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let latency: CFTimeInterval = 0.0

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            // Balance the passRetained if stream creation fails
            Unmanaged<FSEventContextBox>.fromOpaque(ptr).release()
            fsEventContextPointer = nil
            return
        }

        fsEventStream = stream
        FSEventStreamSetDispatchQueue(stream, fsEventsQueue)
        FSEventStreamStart(stream)
    }

    func stopAutoRescan() {
        // Balance the passRetained from startAutoRescan
        if let ptr = fsEventContextPointer {
            Unmanaged<FSEventContextBox>.fromOpaque(ptr).release()
            fsEventContextPointer = nil
        }
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
        stopFallbackScanTimer()
    }

    func restartAutoRescan() {
        stopAutoRescan()
        startAutoRescan()
    }

    func startFallbackScanTimer() {
        stopFallbackScanTimer()
        let timer = DispatchSource.makeTimerSource(queue: refreshQueue)
        timer.schedule(deadline: .now() + Self.fallbackScanInterval,
                       repeating: Self.fallbackScanInterval)
        timer.setEventHandler { [weak self] in
            self?.performFallbackScanIfNeeded()
        }
        timer.activate()
        fallbackScanTimer = timer
    }

    // MARK: - Volume observers

    func setupVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let mountObserver = center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self.handleVolumeEvent(at: url, isMount: true)
        }

        let unmountObserver = center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self.handleVolumeEvent(at: url, isMount: false)
        }

        // Store observers on the delegate's volumeObservers via the AppStore
        // Note: volumeObservers is kept on AppStore since it's used in deinit
    }

    // MARK: - Private helpers

    private func stopFallbackScanTimer() {
        fallbackScanTimer?.cancel()
        fallbackScanTimer = nil
    }

    private func performFallbackScanIfNeeded() {
        guard let delegate else { return }
        let currentApps = delegate.currentApps
        guard !currentApps.isEmpty else { return }
        let currentPaths = Set(currentApps.map { $0.url.path })

        refreshQueue.async { [weak self] in
            guard let self else { return }
            var diskPaths = Set<String>()
            for path in self.cachedSearchPaths {
                let url = URL(fileURLWithPath: path)
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let item as URL in enumerator {
                        let resolved = item.resolvingSymlinksInPath()
                        guard resolved.pathExtension == "app",
                              self.isValidApp(at: resolved),
                              !self.isInsideAnotherApp(resolved) else { continue }
                        diskPaths.insert(resolved.path)
                    }
                }
            }
            if diskPaths != currentPaths {
                DispatchQueue.main.async { [weak self] in
                    self?.scanApplicationsWithOrderPreservation()
                }
            }
        }
    }

    private func handleVolumeEvent(at url: URL, isMount: Bool) {
        guard let delegate else { return }
        let volumePath = url.standardizedFileURL.path
        guard !volumePath.isEmpty else { return }

        let customSources = delegate.currentCustomAppSourcePaths
        let relevant = customSources.contains { source in
            guard let normalized = normalizeApplicationPath(source) else { return false }
            return normalized.hasPrefix(volumePath)
        }

        guard relevant else { return }

        let delay: TimeInterval = isMount ? 1.0 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restartAutoRescan()
            self.scanApplicationsWithOrderPreservation()
        }
    }

    private func handleFSEvents(paths: [String], flagsPointer: UnsafePointer<FSEventStreamEventFlags>?, count: Int) {
        let maxCount = min(paths.count, count)
        var localForceFull = false

        for i in 0..<maxCount {
            let rawPath = paths[i]
            let flags = flagsPointer?[i] ?? 0

            let created = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)) != 0
            let removed = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)) != 0
            let renamed = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0
            let modified = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) != 0
            let isDir = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) != 0

            if isDir && (created || removed || renamed), cachedSearchPaths.contains(where: { rawPath.hasPrefix($0) }) {
                localForceFull = true
                break
            }

            guard let appBundlePath = canonicalAppBundlePath(for: rawPath) else { continue }
            if created || removed || renamed || modified {
                pendingChangedAppPaths.insert(appBundlePath)
            }
        }

        if localForceFull { pendingForceFullScan = true }
        scheduleRescan()
    }

    private func scheduleRescan() {
        // Debounce to coalesce rapid FSEvents (e.g. app installs write many files).
        // 0.6 second lets the dust settle before rescanning.
        rescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performImmediateRefresh() }
        rescanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func performImmediateRefresh() {
        if pendingForceFullScan || pendingChangedAppPaths.count > fullRescanThreshold {
            pendingForceFullScan = false
            pendingChangedAppPaths.removeAll()
            scanApplications()
            return
        }

        let changed = pendingChangedAppPaths
        pendingChangedAppPaths.removeAll()

        if !changed.isEmpty {
            applyIncrementalChanges(for: changed)
        }
    }

    private func applyIncrementalChanges(for changedPaths: Set<String>) {
        guard let delegate else { return }
        guard !changedPaths.isEmpty else { return }

        // Move disk I/O and icon parsing to background; main thread only applies results to reduce jank
        let snapshotApps = delegate.currentApps
        refreshQueue.async { [weak self] in
            guard self != nil else { return }

            enum PendingChange {
                case insert(AppInfo)
                case update(AppInfo)
                case remove(String) // path
            }
            var changes: [PendingChange] = []
            var pathToIndex: [String: Int] = [:]
            for (idx, app) in snapshotApps.enumerated() { pathToIndex[app.url.path] = idx }

            for path in changedPaths {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let exists = FileManager.default.fileExists(atPath: url.path)
                let valid = exists && self!.isValidApp(at: url) && !self!.isInsideAnotherApp(url)
                if valid {
                    let info = delegate.appInfo(from: url)
                    if pathToIndex[url.path] != nil {
                        changes.append(.update(info))
                    } else {
                        changes.append(.insert(info))
                    }
                } else {
                    changes.append(.remove(url.path))
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard self != nil else { return }

                // App delete event: preserve existing icon, etc. pending volume remount

                // App updates
                let updates: [AppInfo] = changes.compactMap { if case .update(let info) = $0 { return info } else { return nil } }
                if !updates.isEmpty {
                    var currentApps = delegate.currentApps
                    var currentFolders = delegate.currentFolders
                    var currentItems = delegate.currentItems

                    var map: [String: Int] = [:]
                    for (idx, app) in currentApps.enumerated() { map[app.url.path] = idx }
                    for info in updates {
                        let standardizedInfoPath = delegate.standardizedFilePath(info.url.path)
                        if let idx = map[info.url.path], currentApps.indices.contains(idx) { currentApps[idx] = info }
                        for fIdx in currentFolders.indices {
                            for aIdx in currentFolders[fIdx].apps.indices where currentFolders[fIdx].apps[aIdx].url.path == info.url.path {
                                currentFolders[fIdx].apps[aIdx] = info
                            }
                        }
                        for iIdx in currentItems.indices {
                            switch currentItems[iIdx] {
                            case .app(let a):
                                if delegate.standardizedFilePath(a.url.path) == standardizedInfoPath {
                                    currentItems[iIdx] = .app(info)
                                    delegate.clearMissingPlaceholder(for: standardizedInfoPath)
                                }
                            case .missingApp(let placeholder):
                                if delegate.standardizedFilePath(placeholder.bundlePath) == standardizedInfoPath {
                                    currentItems[iIdx] = .app(info)
                                    delegate.clearMissingPlaceholder(for: standardizedInfoPath)
                                }
                            default:
                                break
                            }
                        }
                    }
                    delegate.applyScanResults(currentApps, missing: delegate.currentMissingPlaceholders, hidden: delegate.currentHiddenAppPaths)
                    delegate.applyOrderedItems(currentItems, folders: currentFolders)
                    delegate.persistenceRebuildItems()
                }

                // Add new apps
                let inserts: [AppInfo] = changes.compactMap { if case .insert(let info) = $0 { return info } else { return nil } }
                if !inserts.isEmpty {
                    var currentApps = delegate.currentApps
                    currentApps.append(contentsOf: inserts)
                    currentApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    delegate.applyScanResults(currentApps, missing: delegate.currentMissingPlaceholders, hidden: delegate.currentHiddenAppPaths)
                    delegate.persistenceRebuildItems()
                }

                // Refresh and persist
                delegate.triggerFolderUpdate()
                delegate.triggerGridRefresh()
                delegate.refreshMissingPlaceholders()
                delegate.persistenceSaveAllOrder()
                delegate.updateCacheAfterChanges()
            }
        }
    }

    // MARK: - Path helpers

    private func canonicalAppBundlePath(for rawPath: String) -> String? {
        guard let range = rawPath.range(of: ".app") else { return nil }
        let end = rawPath.index(range.lowerBound, offsetBy: 4)
        let bundlePath = String(rawPath[..<end])
        return bundlePath
    }

    private func isInsideAnotherApp(_ url: URL) -> Bool {
        let appCount = url.pathComponents.filter { $0.hasSuffix(".app") }.count
        return appCount > 1
    }

    private func isValidApp(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) &&
        NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    private func normalizeApplicationPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded).standardized.path
    }
}
