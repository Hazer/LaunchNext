import Foundation
import LaunchNextCore
import UniformTypeIdentifiers
import AppKit

@MainActor
final class FolderManager {
    weak var delegate: (any AppStoreServiceDelegate)?

    // MARK: - Private State

    /// Tracks a pending new page created for drag operations, so it can be cleaned up if unused.
    private var pendingNewPage: (pageIndex: Int, itemCount: Int)?

    init(delegate: any AppStoreServiceDelegate) {
        self.delegate = delegate
    }

    // MARK: - Folder CRUD

    func createFolder(with apps: [AppInfo], name: String = "Untitled") -> FolderInfo {
        return createFolder(with: apps, name: name, insertAt: nil)
    }

    func createFolder(with apps: [AppInfo], name: String = "Untitled", insertAt insertIndex: Int?) -> FolderInfo {
        guard let delegate else { return FolderInfo(name: name, apps: apps) }

        let folder = FolderInfo(name: name, apps: apps)
        var currentFolders = delegate.currentFolders
        var currentApps = delegate.currentApps
        currentFolders.append(folder)

        // Remove apps from top-layer list now that they're in a folder
        for app in apps {
            if let index = currentApps.firstIndex(of: app) {
                currentApps.remove(at: index)
            }
        }

        // Replace top-layer app slots with empty, then place folder at target position
        var newItems = delegate.currentItems
        var placeholders: [(Int, AppInfo)] = []
        var remainingApps = apps
        for (idx, item) in newItems.enumerated() {
            guard !remainingApps.isEmpty else { break }
            if case let .app(a) = item, let matchIndex = remainingApps.firstIndex(of: a) {
                let _ = remainingApps.remove(at: matchIndex)
                placeholders.append((idx, a))
            }
        }
        for (idx, _) in placeholders {
            newItems[idx] = .empty(UUID().uuidString)
        }
        let baseIndex = placeholders.map { $0.0 }.min() ?? min(newItems.count - 1, max(0, insertIndex ?? (newItems.count - 1)))
        let desiredIndex = insertIndex ?? baseIndex
        let safeIndex = min(max(0, desiredIndex), max(0, newItems.count - 1))
        if newItems.isEmpty {
            newItems = [.folder(folder)]
        } else {
            newItems[safeIndex] = .folder(folder)
        }

        // Write back
        delegate.applyAppListChanges(currentApps)
        delegate.applyFolderChanges(currentFolders, items: delegate.filteredItemsRemovingHidden(from: newItems))

        compactItemsWithinPages()
        removeEmptyPages()

        DispatchQueue.main.async { [weak delegate] in
            delegate?.triggerFolderUpdate()
        }
        delegate.triggerGridRefresh()
        delegate.refreshCacheAfterFolderOperation()
        delegate.persistenceSaveAllOrder()

        return folder
    }

    func addAppToFolder(_ app: AppInfo, folder: FolderInfo) {
        guard let delegate else { return }
        var currentFolders = delegate.currentFolders
        var currentApps = delegate.currentApps
        guard let folderIndex = currentFolders.firstIndex(of: folder) else { return }

        var updatedFolder = currentFolders[folderIndex]
        updatedFolder.apps.append(app)
        currentFolders[folderIndex] = updatedFolder

        if let appIndex = currentApps.firstIndex(of: app) {
            currentApps.remove(at: appIndex)
        }

        delegate.applyAppListChanges(currentApps)

        var newItems = delegate.currentItems
        if let pos = newItems.firstIndex(of: .app(app)) {
            newItems[pos] = .empty(UUID().uuidString)
            delegate.applyFolderChanges(currentFolders, items: delegate.filteredItemsRemovingHidden(from: newItems))
            compactItemsWithinPages()
            removeEmptyPages()
        } else {
            delegate.applyFolderChanges(currentFolders, items: delegate.currentItems)
            delegate.persistenceRebuildItems()
        }

        // Sync folder references in items
        var items = delegate.currentItems
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == updatedFolder.id {
                items[idx] = .folder(updatedFolder)
            }
        }
        delegate.applyFolderChanges(delegate.currentFolders, items: items)

        delegate.triggerFolderUpdate()
        delegate.triggerGridRefresh()
        delegate.refreshCacheAfterFolderOperation()
        delegate.persistenceSaveAllOrder()
    }

    func removeAppFromFolder(_ app: AppInfo, folder: FolderInfo) {
        guard let delegate else { return }
        var currentFolders = delegate.currentFolders
        var currentApps = delegate.currentApps
        guard let folderIndex = currentFolders.firstIndex(of: folder) else { return }

        var updatedFolder = currentFolders[folderIndex]
        updatedFolder.apps.removeAll { $0 == app }

        // Empty folder -> remove it
        if updatedFolder.apps.isEmpty {
            currentFolders.remove(at: folderIndex)
        } else {
            currentFolders[folderIndex] = updatedFolder
        }

        // Sync folder item in items list
        var newItems = delegate.currentItems
        var emptiedSlots: [Int] = []
        for idx in newItems.indices {
            if case .folder(let f) = newItems[idx], f.id == folder.id {
                if updatedFolder.apps.isEmpty {
                    newItems[idx] = .empty(UUID().uuidString)
                    emptiedSlots.append(idx)
                } else {
                    newItems[idx] = .folder(updatedFolder)
                }
            }
        }

        // Re-add app to list (update or append)
        if let existingIndex = currentApps.firstIndex(where: { $0.url == app.url }) {
            currentApps[existingIndex] = app
        } else {
            currentApps.append(app)
        }
        currentApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        delegate.applyAppListChanges(currentApps)

        // Place app into a recorded empty slot, or find any empty slot, or append
        var targetSlot: Int? = nil
        if let firstEmptied = emptiedSlots.first, firstEmptied < newItems.count {
            targetSlot = firstEmptied
        } else {
            targetSlot = newItems.firstIndex {
                if case .empty = $0 { return true }
                return false
            }
        }
        if let slot = targetSlot {
            newItems[slot] = .app(app)
        } else {
            newItems.append(.app(app))
        }

        delegate.applyFolderChanges(currentFolders, items: delegate.filteredItemsRemovingHidden(from: newItems))

        delegate.triggerFolderUpdate()
        compactItemsWithinPages()
        removeEmptyPages()
        delegate.triggerGridRefresh()
        delegate.refreshCacheAfterFolderOperation()
        delegate.persistenceSaveAllOrder()
    }

    func renameFolder(_ folder: FolderInfo, newName: String) {
        guard let delegate else { return }
        var currentFolders = delegate.currentFolders
        guard let index = currentFolders.firstIndex(of: folder) else { return }

        // Create new FolderInfo instance to ensure SwiftUI can detect changes
        var updatedFolder = currentFolders[index]
        updatedFolder.name = newName
        currentFolders[index] = updatedFolder

        // Sync folder reference in items
        var newItems = delegate.currentItems
        for idx in newItems.indices {
            if case .folder(let f) = newItems[idx], f.id == updatedFolder.id {
                newItems[idx] = .folder(updatedFolder)
            }
        }

        delegate.applyFolderChanges(currentFolders, items: newItems)

        delegate.triggerFolderUpdate()
        delegate.triggerGridRefresh()
        delegate.refreshCacheAfterFolderOperation()
        delegate.persistenceRebuildItems()
        delegate.persistenceSaveAllOrder()
    }

    @discardableResult
    func dissolveFolder(_ folder: FolderInfo) -> Bool {
        guard let delegate else { return false }
        let folderID = folder.id
        var currentFolders = delegate.currentFolders
        var currentApps = delegate.currentApps

        let resolvedFolder: FolderInfo
        if let index = currentFolders.firstIndex(where: { $0.id == folderID }) {
            resolvedFolder = currentFolders[index]
            currentFolders.remove(at: index)
        } else if let itemIndex = delegate.currentItems.firstIndex(where: {
            if case .folder(let f) = $0 { return f.id == folderID }
            return false
        }), case .folder(let fallbackFolder) = delegate.currentItems[itemIndex] {
            resolvedFolder = fallbackFolder
        } else {
            return false
        }

        let folderApps = resolvedFolder.apps
        let folderAppPaths = Set(folderApps.map { delegate.standardizedFilePath($0.url.path) })
        var newItems = delegate.currentItems

        // Remove stale duplicates; the folder slot reuses for the first restored app
        if !folderAppPaths.isEmpty {
            for idx in newItems.indices {
                if case .app(let app) = newItems[idx],
                   folderAppPaths.contains(delegate.standardizedFilePath(app.url.path)) {
                    newItems[idx] = .empty(UUID().uuidString)
                }
            }
        }

        if let folderItemIndex = newItems.firstIndex(where: {
            if case .folder(let f) = $0 { return f.id == folderID }
            return false
        }) {
            newItems[folderItemIndex] = .empty(UUID().uuidString)
            var insertIndex = folderItemIndex
            for app in folderApps {
                newItems = cascadeInsert(into: newItems, item: .app(app), at: insertIndex)
                insertIndex += 1
            }
        } else if !folderApps.isEmpty {
            newItems.append(contentsOf: folderApps.map { .app($0) })
        }

        var existingTopLevelPaths = Set(currentApps.map { delegate.standardizedFilePath($0.url.path) })
        for app in folderApps {
            let normalized = delegate.standardizedFilePath(app.url.path)
            if !existingTopLevelPaths.contains(normalized) {
                currentApps.append(app)
                existingTopLevelPaths.insert(normalized)
            }
        }
        currentApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        delegate.applyAppListChanges(currentApps)
        delegate.pruneHiddenAppsFromAppList()
        delegate.applyFolderChanges(currentFolders, items: delegate.filteredItemsRemovingHidden(from: newItems))

        delegate.applyOpenFolder(nil)

        compactItemsWithinPages()
        removeEmptyPages()
        delegate.triggerFolderUpdate()
        delegate.triggerGridRefresh()
        delegate.refreshCacheAfterFolderOperation()
        delegate.persistenceSaveAllOrder()
        return true
    }

    // MARK: - Cross-page Drag / Cascade

    func moveSelectedAppsAcrossPagesWithCascade(appPathsOrdered: [String], to targetIndex: Int) {
        guard let delegate, !appPathsOrdered.isEmpty else { return }

        var seenPaths = Set<String>()
        let normalizedOrderedPaths: [String] = appPathsOrdered.compactMap { raw in
            let normalized = delegate.standardizedFilePath(raw)
            guard seenPaths.insert(normalized).inserted else { return nil }
            return normalized
        }
        guard !normalizedOrderedPaths.isEmpty else { return }
        let movingPathSet = Set(normalizedOrderedPaths)

        var movingItemsByPath: [String: LaunchpadItem] = [:]
        for item in delegate.currentItems {
            guard case .app(let app) = item else { continue }
            let path = delegate.standardizedFilePath(app.url.path)
            if movingPathSet.contains(path), movingItemsByPath[path] == nil {
                movingItemsByPath[path] = .app(app)
            }
        }

        let orderedMovingItems = normalizedOrderedPaths.compactMap { movingItemsByPath[$0] }
        guard !orderedMovingItems.isEmpty else { return }

        var result = delegate.currentItems
        let sourceIndexes = result.indices.filter { index in
            guard case .app(let app) = result[index] else { return false }
            return movingPathSet.contains(delegate.standardizedFilePath(app.url.path))
        }
        guard !sourceIndexes.isEmpty else { return }

        for index in sourceIndexes {
            result[index] = .empty(UUID().uuidString)
        }

        result = compactedItemsWithinPages(result)
        var insertionIndex = max(0, min(targetIndex, result.count))

        for movingItem in orderedMovingItems {
            result = cascadeInsert(into: result, item: movingItem, at: insertionIndex)
            insertionIndex += 1
        }

        delegate.applyOrderedItems(delegate.filteredItemsRemovingHidden(from: result), folders: delegate.currentFolders)
        compactItemsWithinPages()
        removeEmptyPages()
        delegate.triggerGridRefresh()
        delegate.persistenceSaveAllOrder()
    }

    func moveItemAcrossPagesWithCascade(item: LaunchpadItem, to targetIndex: Int) {
        guard let delegate else { return }
        var currentItems = delegate.currentItems
        guard currentItems.indices.contains(targetIndex) || targetIndex == currentItems.count else {
            return
        }
        guard let source = currentItems.firstIndex(of: item) else { return }
        var result = currentItems
        result[source] = .empty(UUID().uuidString)
        result = cascadeInsert(into: result, item: item, at: targetIndex)
        delegate.applyOrderedItems(delegate.filteredItemsRemovingHidden(from: result), folders: delegate.currentFolders)

        let itemsPerPage = delegate.currentItemsPerPage
        let updatedItems = delegate.currentItems
        let targetPage = targetIndex / itemsPerPage
        let currentPages = (updatedItems.count + itemsPerPage - 1) / itemsPerPage

        if targetPage == currentPages - 1 {
            // New page: delay compact to let positions stabilize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.compactItemsWithinPages()
                self.removeEmptyPages()
                self.delegate?.triggerGridRefresh()
            }
        } else {
            compactItemsWithinPages()
            removeEmptyPages()
        }

        delegate.triggerGridRefresh()
        delegate.persistenceSaveAllOrder()
    }

    private func cascadeInsert(into array: [LaunchpadItem], item: LaunchpadItem, at targetIndex: Int) -> [LaunchpadItem] {
        guard let delegate else { return array }
        var result = array
        let p = delegate.currentItemsPerPage

        // Pad to whole pages for processing
        if result.count % p != 0 {
            let remain = p - (result.count % p)
            for _ in 0..<remain { result.append(.empty(UUID().uuidString)) }
        }

        var currentPage = max(0, targetIndex / p)
        var localIndex = max(0, min(targetIndex - currentPage * p, p - 1))
        var carry: LaunchpadItem? = item

        while let moving = carry {
            let pageStart = currentPage * p
            let pageEnd = pageStart + p
            if result.count < pageEnd {
                let need = pageEnd - result.count
                for _ in 0..<need { result.append(.empty(UUID().uuidString)) }
            }
            var slice = Array(result[pageStart..<pageEnd])

            let safeLocalIndex = max(0, min(localIndex, slice.count))
            slice.insert(moving, at: safeLocalIndex)

            var spilled: LaunchpadItem? = nil
            if slice.count > p {
                spilled = slice.removeLast()
            }
            result.replaceSubrange(pageStart..<pageEnd, with: slice)
            if let s = spilled, case .empty = s {
                carry = nil
            } else if let s = spilled {
                carry = s
                currentPage += 1
                localIndex = 0
                let nextEnd = (currentPage + 1) * p
                if result.count < nextEnd {
                    let need = nextEnd - result.count
                    for _ in 0..<need { result.append(.empty(UUID().uuidString)) }
                }
            } else {
                carry = nil
            }
        }
        return result
    }

    // MARK: - Page Management

    /// Auto-fill within single page: each page's empty slots move to page end, maintain non-empty item mutual order
    func compactItemsWithinPages() {
        guard let delegate else { return }
        let currentItems = delegate.currentItems
        guard !currentItems.isEmpty else { return }
        let compacted = compactedItemsWithinPages(currentItems)
        delegate.applyOrderedItems(delegate.filteredItemsRemovingHidden(from: compacted), folders: delegate.currentFolders)
    }

    private func compactedItemsWithinPages(_ source: [LaunchpadItem]) -> [LaunchpadItem] {
        guard let delegate, !source.isEmpty else { return source }
        let itemsPerPage = delegate.currentItemsPerPage
        var result: [LaunchpadItem] = []
        result.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let end = min(index + itemsPerPage, source.count)
            let pageSlice = Array(source[index..<end])
            var nonEmpty: [LaunchpadItem] = []
            var emptyTokens: [String] = []
            nonEmpty.reserveCapacity(pageSlice.count)
            emptyTokens.reserveCapacity(pageSlice.count)

            for item in pageSlice {
                switch item {
                case .empty(let token):
                    emptyTokens.append(token)
                default:
                    nonEmpty.append(item)
                }
            }

            result.append(contentsOf: nonEmpty)

            if !emptyTokens.isEmpty {
                result.append(contentsOf: emptyTokens.map { .empty($0) })
            }

            index = end
        }
        return result
    }

    /// Auto-delete empty pages
    func removeEmptyPages() {
        guard let delegate else { return }
        var items = delegate.currentItems
        guard !items.isEmpty else { return }
        let itemsPerPage = delegate.currentItemsPerPage

        var newItems: [LaunchpadItem] = []
        var index = 0

        while index < items.count {
            let end = min(index + itemsPerPage, items.count)
            let pageSlice = Array(items[index..<end])

            let isEmptyPage = pageSlice.allSatisfy { item in
                if case .empty = item { return true } else { return false }
            }

            if !isEmptyPage {
                newItems.append(contentsOf: pageSlice)
            }

            index = end
        }

        if newItems.count != items.count {
            delegate.applyOrderedItems(delegate.filteredItemsRemovingHidden(from: newItems), folders: delegate.currentFolders)
            delegate.triggerGridRefresh()
        }
    }

    func createNewPageForDrag() -> Bool {
        guard let delegate else { return false }
        let itemsPerPage = delegate.currentItemsPerPage
        var items = delegate.currentItems
        let currentPages = (items.count + itemsPerPage - 1) / itemsPerPage
        let newPageIndex = currentPages

        for _ in 0..<itemsPerPage {
            items.append(.empty(UUID().uuidString))
        }

        delegate.applyOrderedItems(items, folders: delegate.currentFolders)

        pendingNewPage = (pageIndex: newPageIndex, itemCount: itemsPerPage)

        delegate.triggerGridRefresh()

        return true
    }

    func cleanupUnusedNewPage() {
        guard let delegate, let pending = pendingNewPage else { return }

        var items = delegate.currentItems

        let pageStart = pending.pageIndex * pending.itemCount
        let pageEnd = min(pageStart + pending.itemCount, items.count)

        if pageStart < items.count {
            let pageSlice = Array(items[pageStart..<pageEnd])
            let hasNonEmptyItems = pageSlice.contains { item in
                if case .empty = item { return false } else { return true }
            }

            if !hasNonEmptyItems {
                items.removeSubrange(pageStart..<pageEnd)
                delegate.applyOrderedItems(items, folders: delegate.currentFolders)
                delegate.triggerGridRefresh()
            }
        }

        pendingNewPage = nil
    }

    // MARK: - Notify / Refresh

    func notifyFolderContentChanged(_ folder: FolderInfo) {
        guard let delegate else { return }
        var items = delegate.currentItems
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == folder.id {
                items[idx] = .folder(folder)
            }
        }
        delegate.applyOrderedItems(items, folders: delegate.currentFolders)
        delegate.triggerFolderUpdate()
        delegate.triggerGridRefresh()
        delegate.persistenceSaveAllOrder()
    }

    func refreshCacheAfterFolderOperation() {
        guard let delegate else { return }
        delegate.refreshCacheAfterFolderOperation()
    }

    // MARK: - Reset Layout

    func resetLayout() {
        guard let delegate else { return }

        delegate.applyOpenFolder(nil)
        delegate.applyClearFolders()
        delegate.persistenceClearAllPersistedData()
        delegate.clearAllCaches()
        delegate.applyHasPerformedInitialScan(false)
        delegate.applyOrderedItems([], folders: [])
        delegate.triggerFullRescan(loadPersistedOrder: false)
        delegate.applyCurrentPage(0)
        delegate.triggerFolderUpdate()
        delegate.triggerGridRefresh()

        // Delay cache refresh until scan completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak delegate] in
            delegate?.refreshCacheAfterFolderOperation()
        }
    }

    // MARK: - Export

    /// Export app order as JSON format
    func exportAppOrderAsJSON() -> String? {
        let exportData = buildExportData()

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func buildExportData() -> [String: Any] {
        guard let delegate else { return [:] }
        let items = delegate.currentItems
        let itemsPerPage = delegate.currentItemsPerPage

        var pages: [[String: Any]] = []

        for (index, item) in items.enumerated() {
            let pageIndex = index / itemsPerPage
            let position = index % itemsPerPage

            var itemData: [String: Any] = [
                "pageIndex": pageIndex,
                "position": position,
                "kind": itemKind(for: item),
                "name": item.name,
                "path": itemPath(for: item),
                "folderApps": []
            ]

            if case let .folder(folder) = item {
                itemData["folderApps"] = folder.apps.map { $0.name }
                itemData["folderAppPaths"] = folder.apps.map { $0.url.path }
            }

            pages.append(itemData)
        }

        return [
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "totalPages": (items.count + itemsPerPage - 1) / itemsPerPage,
            "totalItems": items.count,
            "fullscreenMode": delegate.currentIsFullscreenMode,
            "pages": pages
        ]
    }

    private func itemKind(for item: LaunchpadItem) -> String {
        switch item {
        case .app:
            return "app"
        case .folder:
            return "folder"
        case .empty:
            return "empty slot"
        case .missingApp:
            return "missingapp"
        }
    }

    private func itemPath(for item: LaunchpadItem) -> String {
        switch item {
        case let .app(app):
            return app.url.path
        case let .folder(folder):
            return "folder: \(folder.name)"
        case .empty:
            return "empty slot"
        case let .missingApp(placeholder):
            return "missingapp: \(placeholder.bundlePath)"
        }
    }

    func saveExportFileWithDialog(content: String, filename: String, fileExtension: String, fileType: String) -> Bool {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Export File"
        savePanel.nameFieldStringValue = filename
        savePanel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false

        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            savePanel.directoryURL = desktopURL
        }

        let response = savePanel.runModal()
        if response == .OK, let url = savePanel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    // MARK: - Grid Configuration

    /// Handles changes to grid configuration (columns/rows) by compacting and refreshing.
    func handleGridConfigurationChange() {
        guard let delegate else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            self.compactItemsWithinPages()
            self.removeEmptyPages()
            self.cleanupUnusedNewPage()

            delegate.triggerGridRefresh()
            delegate.refreshCacheAfterScan()
            delegate.persistenceSaveAllOrder()
        }
    }
}
