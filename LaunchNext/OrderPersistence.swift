import Foundation
import SwiftData
import LaunchNextCore

@MainActor
final class OrderPersistence {
    weak var delegate: AppStoreServiceDelegate?

    init(delegate: AppStoreServiceDelegate) {
        self.delegate = delegate
    }

    // MARK: - Rebuild Items

    func rebuildItems() {
        guard let delegate else { return }
        let currentItems = delegate.currentItems
        let apps = delegate.currentApps
        let folders = delegate.currentFolders

        let appsInFolders: Set<AppInfo> = Set(folders.flatMap { $0.apps })
        let folderById: [String: FolderInfo] = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })

        var newItems: [LaunchpadItem] = []
        newItems.reserveCapacity(currentItems.count + 10)
        var seenAppPaths = Set<String>()
        var seenFolderIds = Set<String>()
        seenAppPaths.reserveCapacity(apps.count)
        seenFolderIds.reserveCapacity(folders.count)

        for item in currentItems {
            switch item {
            case .folder(let folder):
                if let updated = folderById[folder.id] {
                    newItems.append(.folder(updated))
                    seenFolderIds.insert(updated.id)
                }
            case .app(let app):
                if !appsInFolders.contains(app) {
                    newItems.append(.app(app))
                    seenAppPaths.insert(delegate.standardizedFilePath(app.url.path))
                }
            case .missingApp(let placeholder):
                if let item = currentMissingAppItem(for: placeholder) {
                    newItems.append(item)
                    if case .missingApp(let current) = item {
                        seenAppPaths.insert(delegate.standardizedFilePath(current.bundlePath))
                    }
                } else {
                    newItems.append(.empty(UUID().uuidString))
                }
            case .empty(let token):
                newItems.append(.empty(token))
            }
        }

        let missingFreeApps = apps.filter {
            guard !appsInFolders.contains($0) else { return false }
            return !seenAppPaths.contains(delegate.standardizedFilePath($0.url.path))
        }
        newItems.append(contentsOf: missingFreeApps.map { .app($0) })

        if newItems.count != currentItems.count || !newItems.elementsEqual(currentItems, by: { $0.id == $1.id }) {
            delegate.applyOrderedItems(delegate.filteredItemsRemovingHidden(from: newItems), folders: folders)
        }
    }

    // MARK: - Load All Order

    func loadAllOrder() {
        guard let delegate, let modelContext = delegate.currentModelContext else {
            print("LaunchNext: ModelContext is nil, cannot load persisted order")
            return
        }

        print("LaunchNext: Attempting to load persisted order data...")

        if loadOrderFromPageEntries(using: modelContext) {
            print("LaunchNext: Successfully loaded order from PageEntryData")
            return
        }

        print("LaunchNext: PageEntryData not found, trying legacy TopItemData...")
        loadOrderFromLegacyTopItems(using: modelContext)
        print("LaunchNext: Finished loading order from legacy data")
    }

    // MARK: - Load Order From Page Entries

    private func loadOrderFromPageEntries(using modelContext: ModelContext) -> Bool {
        guard let delegate else { return false }
        do {
            let descriptor = FetchDescriptor<PageEntryData>(
                sortBy: [SortDescriptor(\.pageIndex, order: .forward), SortDescriptor(\.position, order: .forward)]
            )
            let saved = try modelContext.fetch(descriptor)
            guard !saved.isEmpty else { return false }

            var folderMap: [String: FolderInfo] = [:]
            var foldersInOrder: [FolderInfo] = []

            for row in saved where row.kind == "folder" {
                guard let fid = row.folderId else { continue }
                if folderMap[fid] != nil { continue }

                let folderApps: [AppInfo] = row.appPaths.compactMap { path in
                    if let existing = delegate.currentApps.first(where: { $0.url.path == path }) {
                        return existing
                    }
                    let url = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: url.path) {
                        return delegate.appInfo(from: url, preferredName: nil, loadIcon: nil)
                    }
                    return delegate.placeholderAppInfo(forMissingPath: path, preferredName: row.folderName)
                }
                let folder = FolderInfo(id: fid, name: row.folderName ?? "Untitled", apps: folderApps, createdAt: row.createdAt)
                folderMap[fid] = folder
                foldersInOrder.append(folder)
            }

            let folderAppPathSet: Set<String> = Set(foldersInOrder.flatMap { $0.apps.map { $0.url.path } })

            var combined: [LaunchpadItem] = []
            combined.reserveCapacity(saved.count)
            for row in saved {
                switch row.kind {
                case "folder":
                    if let fid = row.folderId, let folder = folderMap[fid] {
                        combined.append(.folder(folder))
                    }
                case "app":
                    if let path = row.appPath, !folderAppPathSet.contains(path) {
                        if let existing = delegate.currentApps.first(where: { $0.url.path == path }) {
                            delegate.clearMissingPlaceholder(for: path)
                            combined.append(.app(existing))
                        } else {
                            let url = URL(fileURLWithPath: path)
                            if FileManager.default.fileExists(atPath: url.path) {
                                let info = delegate.appInfo(from: url, preferredName: nil, loadIcon: nil)
                                delegate.clearMissingPlaceholder(for: path)
                                combined.append(.app(info))
                            } else if let placeholder = delegate.updateMissingPlaceholder(path: path,
                                                                                          displayName: row.appDisplayName,
                                                                                          removableSource: row.removableSource) {
                                combined.append(.missingApp(placeholder))
                            }
                        }
                    }
                case "missing":
                    if let path = row.appPath {
                        if let existing = delegate.currentApps.first(where: { $0.url.path == path }) {
                            delegate.clearMissingPlaceholder(for: path)
                            combined.append(.app(existing))
                        } else {
                            let url = URL(fileURLWithPath: path)
                            if FileManager.default.fileExists(atPath: url.path) {
                                let info = delegate.appInfo(from: url, preferredName: nil, loadIcon: nil)
                                delegate.clearMissingPlaceholder(for: path)
                                combined.append(.app(info))
                            } else if let placeholder = delegate.updateMissingPlaceholder(path: path,
                                                                                          displayName: row.appDisplayName,
                                                                                          removableSource: row.removableSource) {
                                combined.append(.missingApp(placeholder))
                            }
                        }
                    }
                case "empty":
                    combined.append(.empty(row.slotId))
                default:
                    break
                }
            }

            DispatchQueue.main.async { [weak delegate] in
                guard let delegate else { return }
                delegate.applyFolderChanges(delegate.sanitizedFolders(foldersInOrder), items: delegate.currentItems)
                if !combined.isEmpty {
                    delegate.applyOrderedItems(delegate.filteredItemsRemovingHidden(from: combined), folders: delegate.currentFolders)
                    if delegate.currentApps.isEmpty {
                        let freeApps: [AppInfo] = combined.compactMap { if case let .app(a) = $0 { return a } else { return nil } }
                        delegate.applyScanResults(freeApps, missing: delegate.currentMissingPlaceholders, hidden: delegate.currentHiddenAppPaths)
                        delegate.pruneHiddenAppsFromAppList()
                    }
                }
                delegate.refreshMissingPlaceholders()
                delegate.hasAppliedOrderFromStore = true
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Load Order From Legacy Top Items

    private func loadOrderFromLegacyTopItems(using modelContext: ModelContext) {
        guard let delegate else { return }
        do {
            let descriptor = FetchDescriptor<TopItemData>(sortBy: [SortDescriptor(\.orderIndex, order: .forward)])
            let saved = try modelContext.fetch(descriptor)
            guard !saved.isEmpty else { return }

            var folderMap: [String: FolderInfo] = [:]
            var foldersInOrder: [FolderInfo] = []
            let folderAppPathSet: Set<String> = Set(saved.filter { $0.kind == "folder" }.flatMap { $0.appPaths })
            for row in saved where row.kind == "folder" {
                let folderApps: [AppInfo] = row.appPaths.compactMap { path in
                    if let existing = delegate.currentApps.first(where: { $0.url.path == path }) { return existing }
                    let url = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: url.path) {
                        return delegate.appInfo(from: url, preferredName: nil, loadIcon: nil)
                    }
                    return delegate.placeholderAppInfo(forMissingPath: path, preferredName: row.folderName)
                }
                let folder = FolderInfo(id: row.id, name: row.folderName ?? "Untitled", apps: folderApps, createdAt: row.createdAt)
                folderMap[row.id] = folder
                foldersInOrder.append(folder)
            }

            var combined: [LaunchpadItem] = saved.sorted { $0.orderIndex < $1.orderIndex }.compactMap { row in
                if row.kind == "folder" { return folderMap[row.id].map { .folder($0) } }
                if row.kind == "empty" { return .empty(row.id) }
                if row.kind == "app", let path = row.appPath {
                    if folderAppPathSet.contains(path) { return nil }
                    if let existing = delegate.currentApps.first(where: { $0.url.path == path }) {
                        delegate.clearMissingPlaceholder(for: path)
                        return .app(existing)
                    }
                    let url = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: url.path) {
                        delegate.clearMissingPlaceholder(for: path)
                        return .app(delegate.appInfo(from: url, preferredName: nil, loadIcon: nil))
                    }
                    if let placeholder = delegate.updateMissingPlaceholder(path: path, displayName: nil, removableSource: nil) {
                        return .missingApp(placeholder)
                    }
                    return nil
                }
                return nil
            }

            let appsInFolders = Set(foldersInOrder.flatMap { $0.apps })
            let seenPaths = Set(combined.compactMap { item -> String? in
                switch item {
                case .app(let app):
                    return delegate.standardizedFilePath(app.url.path)
                case .missingApp(let placeholder):
                    return delegate.standardizedFilePath(placeholder.bundlePath)
                default:
                    return nil
                }
            })
            let missingFreeApps = delegate.currentApps
                .filter { !appsInFolders.contains($0) && !seenPaths.contains(delegate.standardizedFilePath($0.url.path)) }
                .map { LaunchpadItem.app($0) }
            combined.append(contentsOf: missingFreeApps)

            DispatchQueue.main.async { [weak delegate] in
                guard let delegate else { return }
                delegate.applyFolderChanges(delegate.sanitizedFolders(foldersInOrder), items: delegate.currentItems)
                if !combined.isEmpty {
                    delegate.applyOrderedItems(delegate.filteredItemsRemovingHidden(from: combined), folders: delegate.currentFolders)
                    if delegate.currentApps.isEmpty {
                        let freeAppsAfterLoad: [AppInfo] = combined.compactMap { if case let .app(a) = $0 { return a } else { return nil } }
                        delegate.applyScanResults(freeAppsAfterLoad, missing: delegate.currentMissingPlaceholders, hidden: delegate.currentHiddenAppPaths)
                        delegate.pruneHiddenAppsFromAppList()
                    }
                }
                delegate.refreshMissingPlaceholders()
                delegate.hasAppliedOrderFromStore = true
            }
        } catch {
            // ignore
        }
    }

    // MARK: - Save All Order

    func saveAllOrder() {
        guard let delegate, let modelContext = delegate.currentModelContext else {
            print("LaunchNext: ModelContext is nil, cannot save order")
            return
        }
        let items = delegate.currentItems
        let folders = delegate.currentFolders
        guard !items.isEmpty else {
            print("LaunchNext: Items list is empty, skipping save")
            return
        }

        print("LaunchNext: Saving order data for \(items.count) items...")

        do {
            let existing = try modelContext.fetch(FetchDescriptor<PageEntryData>())
            print("LaunchNext: Found \(existing.count) existing entries, clearing...")
            for row in existing { modelContext.delete(row) }

            let folderById: [String: FolderInfo] = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            let itemsPerPage = delegate.currentItemsPerPage

            for (idx, item) in items.enumerated() {
                let pageIndex = idx / itemsPerPage
                let position = idx % itemsPerPage
                let slotId = "page-\(pageIndex)-pos-\(position)"
                switch item {
                case .folder(let folder):
                    let authoritativeFolder = folderById[folder.id] ?? folder
                    let row = PageEntryData(
                        slotId: slotId,
                        pageIndex: pageIndex,
                        position: position,
                        kind: "folder",
                        folderId: authoritativeFolder.id,
                        folderName: authoritativeFolder.name,
                        appPaths: authoritativeFolder.apps.map { $0.url.path }
                    )
                    modelContext.insert(row)
                case .app(let app):
                    let row = PageEntryData(
                        slotId: slotId,
                        pageIndex: pageIndex,
                        position: position,
                        kind: "app",
                        appPath: app.url.path,
                        appDisplayName: app.name,
                        removableSource: delegate.removableSourcePath(forAppPath: app.url.path)
                    )
                    modelContext.insert(row)
                case .missingApp(let placeholder):
                    let row = PageEntryData(
                        slotId: slotId,
                        pageIndex: pageIndex,
                        position: position,
                        kind: "missing",
                        appPath: placeholder.bundlePath,
                        appDisplayName: placeholder.displayName,
                        removableSource: placeholder.removableSource
                    )
                    modelContext.insert(row)
                case .empty:
                    let row = PageEntryData(
                        slotId: slotId,
                        pageIndex: pageIndex,
                        position: position,
                        kind: "empty"
                    )
                    modelContext.insert(row)
                }
            }
            try modelContext.save()
            print("LaunchNext: Successfully saved order data")

            do {
                let legacy = try modelContext.fetch(FetchDescriptor<TopItemData>())
                for row in legacy { modelContext.delete(row) }
                try? modelContext.save()
            } catch { }
        } catch {
            print("LaunchNext: Error saving order data: \(error)")
        }
    }

    // MARK: - Clear All Persisted Data

    func clearAllPersistedData() {
        guard let delegate, let modelContext = delegate.currentModelContext else { return }

        do {
            let pageEntries = try modelContext.fetch(FetchDescriptor<PageEntryData>())
            for entry in pageEntries {
                modelContext.delete(entry)
            }

            let legacyEntries = try modelContext.fetch(FetchDescriptor<TopItemData>())
            for entry in legacyEntries {
                modelContext.delete(entry)
            }

            try modelContext.save()
        } catch {
            // ignore error, ensure reset flow continues
        }
    }

    // MARK: - Rebuild Items With Strict Order Preservation

    func rebuildItemsWithStrictOrderPreservation(currentItems: [LaunchpadItem]) {
        guard let delegate else { return }
        let apps = delegate.currentApps
        let folders = delegate.currentFolders

        var newItems: [LaunchpadItem] = []
        let appsInFolders = Set(folders.flatMap { $0.apps })

        for (_, item) in currentItems.enumerated() {
            switch item {
            case .folder(let folder):
                if folders.contains(where: { $0.id == folder.id }) {
                    if let updatedFolder = folders.first(where: { $0.id == folder.id }) {
                        newItems.append(.folder(updatedFolder))
                    } else {
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    newItems.append(.empty(UUID().uuidString))
                }

            case .app(let app):
                let standardizedPath = delegate.standardizedFilePath(app.url.path)
                if apps.contains(where: { delegate.standardizedFilePath($0.url.path) == standardizedPath }) {
                    if !appsInFolders.contains(app) {
                        newItems.append(.app(app))
                    } else {
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    if let placeholder = delegate.updateMissingPlaceholder(path: standardizedPath, displayName: app.name, removableSource: nil) {
                        newItems.append(.missingApp(placeholder))
                    } else {
                        newItems.append(.empty(UUID().uuidString))
                    }
                }
            case .missingApp(let placeholder):
                if let item = currentMissingAppItem(for: placeholder) {
                    newItems.append(item)
                } else {
                    newItems.append(.empty(UUID().uuidString))
                }
            case .empty(let token):
                newItems.append(.empty(token))
            }
        }

        let existingAppPaths = Set(newItems.compactMap { item -> String? in
            switch item {
            case .app(let app):
                return delegate.standardizedFilePath(app.url.path)
            case .missingApp(let placeholder):
                return delegate.standardizedFilePath(placeholder.bundlePath)
            default:
                return nil
            }
        })

        let newFreeApps = apps.filter { app in
            !appsInFolders.contains(app) && !existingAppPaths.contains(delegate.standardizedFilePath(app.url.path))
        }

        if !newFreeApps.isEmpty {
            var pendingApps = newFreeApps
            let itemsPerPage = delegate.currentItemsPerPage

            if newItems.count > 0 {
                let lastPageStart = ((newItems.count - 1) / itemsPerPage) * itemsPerPage
                let lastPageIndices = Array(lastPageStart..<newItems.count)
                let emptyIndices = lastPageIndices.filter { index in
                    if case .empty = newItems[index] { return true }
                    return false
                }
                let fillCount = min(pendingApps.count, emptyIndices.count)
                for i in 0..<fillCount {
                    newItems[emptyIndices[i]] = .app(pendingApps.removeFirst())
                }
            }

            if !pendingApps.isEmpty {
                let remainder = newItems.count % itemsPerPage
                if remainder != 0 {
                    let fillCount = min(itemsPerPage - remainder, pendingApps.count)
                    for _ in 0..<fillCount {
                        newItems.append(.app(pendingApps.removeFirst()))
                    }
                }

                while !pendingApps.isEmpty {
                    for _ in 0..<itemsPerPage {
                        if pendingApps.isEmpty {
                            newItems.append(.empty(UUID().uuidString))
                        } else {
                            newItems.append(.app(pendingApps.removeFirst()))
                        }
                    }
                }
            }
        }

        delegate.applyOrderedItems(delegate.filteredItemsRemovingHidden(from: newItems), folders: folders)
    }

    // MARK: - Has Persisted Order Data

    func hasPersistedOrderData() -> Bool {
        guard let delegate, let modelContext = delegate.currentModelContext else { return false }

        do {
            let pageEntries = try modelContext.fetch(FetchDescriptor<PageEntryData>())
            let topItems = try modelContext.fetch(FetchDescriptor<TopItemData>())
            return !pageEntries.isEmpty || !topItems.isEmpty
        } catch {
            return false
        }
    }

    // MARK: - Merge Current Order With Persisted Data

    func mergeCurrentOrderWithPersistedData(currentItems: [LaunchpadItem], newApps: [AppInfo], loadPersistedFolders: Bool = true) {
        guard let delegate else { return }

        let currentOrder = currentItems

        if loadPersistedFolders {
            loadFoldersFromPersistedData()
        }

        let apps = delegate.currentApps
        let folders = delegate.currentFolders
        var newItems: [LaunchpadItem] = []
        let appsInFolders = Set(folders.flatMap { $0.apps })
        let refreshedAppsByPath = Dictionary(uniqueKeysWithValues: apps.map { ($0.url.path, $0) })

        for (_, item) in currentOrder.enumerated() {
            switch item {
            case .folder(let folder):
                if folders.contains(where: { $0.id == folder.id }) {
                    if let updatedFolder = folders.first(where: { $0.id == folder.id }) {
                        newItems.append(.folder(updatedFolder))
                    } else {
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    newItems.append(.empty(UUID().uuidString))
                }

            case .app(let app):
                let standardizedPath = delegate.standardizedFilePath(app.url.path)
                if apps.contains(where: { delegate.standardizedFilePath($0.url.path) == standardizedPath }) {
                    if !appsInFolders.contains(app) {
                        let updatedApp = refreshedAppsByPath[app.url.path] ?? app
                        newItems.append(.app(updatedApp))
                    } else {
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    if let placeholder = delegate.updateMissingPlaceholder(path: standardizedPath, displayName: app.name, removableSource: nil) {
                        newItems.append(.missingApp(placeholder))
                    } else {
                        newItems.append(.empty(UUID().uuidString))
                    }
                }
            case .missingApp(let placeholder):
                if let item = currentMissingAppItem(for: placeholder) {
                    newItems.append(item)
                } else {
                    newItems.append(.empty(UUID().uuidString))
                }
            case .empty(let token):
                newItems.append(.empty(token))
            }
        }

        let existingAppPaths = Set(newItems.compactMap { item -> String? in
            switch item {
            case .app(let app):
                return delegate.standardizedFilePath(app.url.path)
            case .missingApp(let placeholder):
                return delegate.standardizedFilePath(placeholder.bundlePath)
            default:
                return nil
            }
        })

        let newFreeApps = apps.filter { app in
            !appsInFolders.contains(app) && !existingAppPaths.contains(delegate.standardizedFilePath(app.url.path))
        }

        if !newFreeApps.isEmpty {
            var pendingApps = newFreeApps
            let itemsPerPage = delegate.currentItemsPerPage

            if newItems.count > 0 {
                let lastPageStart = ((newItems.count - 1) / itemsPerPage) * itemsPerPage
                let lastPageIndices = Array(lastPageStart..<newItems.count)
                let emptyIndices = lastPageIndices.filter { index in
                    if case .empty = newItems[index] { return true }
                    return false
                }
                let fillCount = min(pendingApps.count, emptyIndices.count)
                for i in 0..<fillCount {
                    newItems[emptyIndices[i]] = .app(pendingApps.removeFirst())
                }
            }

            if !pendingApps.isEmpty {
                let remainder = newItems.count % itemsPerPage
                if remainder != 0 {
                    let fillCount = min(itemsPerPage - remainder, pendingApps.count)
                    for _ in 0..<fillCount {
                        newItems.append(.app(pendingApps.removeFirst()))
                    }
                }

                while !pendingApps.isEmpty {
                    for _ in 0..<itemsPerPage {
                        if pendingApps.isEmpty {
                            newItems.append(.empty(UUID().uuidString))
                        } else {
                            newItems.append(.app(pendingApps.removeFirst()))
                        }
                    }
                }
            }
        }

        delegate.applyOrderedItems(delegate.filteredItemsRemovingHidden(from: newItems), folders: folders)
    }

    // MARK: - Load Folders From Persisted Data

    func loadFoldersFromPersistedData() {
        guard let delegate, let modelContext = delegate.currentModelContext else { return }

        do {
            let saved = try modelContext.fetch(FetchDescriptor<PageEntryData>(
                sortBy: [SortDescriptor(\.pageIndex, order: .forward), SortDescriptor(\.position, order: .forward)]
            ))

            if !saved.isEmpty {
                var folderMap: [String: FolderInfo] = [:]
                var foldersInOrder: [FolderInfo] = []

                for row in saved where row.kind == "folder" {
                    guard let fid = row.folderId else { continue }
                    if folderMap[fid] != nil { continue }

                    let folderApps: [AppInfo] = row.appPaths.compactMap { path in
                        if let existing = delegate.currentApps.first(where: { $0.url.path == path }) {
                            return existing
                        }
                        let url = URL(fileURLWithPath: path)
                        if FileManager.default.fileExists(atPath: url.path) {
                            return delegate.appInfo(from: url, preferredName: nil, loadIcon: nil)
                        }
                        return delegate.placeholderAppInfo(forMissingPath: path, preferredName: nil)
                    }

                    let folder = FolderInfo(id: fid, name: row.folderName ?? "Untitled", apps: folderApps, createdAt: row.createdAt)
                    folderMap[fid] = folder
                    foldersInOrder.append(folder)
                }

                delegate.applyFolderChanges(delegate.sanitizedFolders(foldersInOrder), items: delegate.currentItems)
            }
        } catch {
        }
    }

    // MARK: - Smart Rebuild Items With Order Preservation

    func smartRebuildItemsWithOrderPreservation(currentItems: [LaunchpadItem], newApps: [AppInfo]) {
        let hasPersistedData = self.hasPersistedOrderData()

        if hasPersistedData {
            self.mergeCurrentOrderWithPersistedData(currentItems: currentItems, newApps: newApps, loadPersistedFolders: true)
        } else {
            self.mergeCurrentOrderWithPersistedData(currentItems: currentItems, newApps: newApps, loadPersistedFolders: false)
        }
    }

    // MARK: - Private Helpers

    private func currentMissingAppItem(for placeholder: MissingAppPlaceholder) -> LaunchpadItem? {
        guard let delegate else { return nil }
        let normalizedPath = delegate.standardizedFilePath(placeholder.bundlePath)

        if let existing = delegate.currentApps.first(where: { delegate.standardizedFilePath($0.url.path) == normalizedPath }) {
            delegate.clearMissingPlaceholder(for: normalizedPath)
            return .app(existing)
        }

        let url = URL(fileURLWithPath: normalizedPath)
        if FileManager.default.fileExists(atPath: url.path) {
            let info = delegate.appInfo(from: url, preferredName: nil, loadIcon: nil)
            delegate.clearMissingPlaceholder(for: normalizedPath)
            return .app(info)
        }

        if let updated = delegate.updateMissingPlaceholder(path: normalizedPath, displayName: placeholder.displayName, removableSource: placeholder.removableSource) {
            return .missingApp(updated)
        }

        return nil
    }
}

extension AppStoreServiceDelegate {
    func placeholderAppInfo(forMissingPath path: String, preferredName: String?) -> AppInfo? {
        guard let placeholder = updateMissingPlaceholder(path: path, displayName: preferredName, removableSource: nil) else {
            return nil
        }
        let placeholderURL = URL(fileURLWithPath: placeholder.bundlePath)
        return AppInfo(name: placeholder.displayName, icon: placeholder.icon, url: placeholderURL)
    }
}
