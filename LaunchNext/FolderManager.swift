import LaunchNextCore
import Foundation

@MainActor
final class FolderManager {
    weak var delegate: AppStoreServiceDelegate?

    init(delegate: AppStoreServiceDelegate) {
        self.delegate = delegate
    }

    // MARK: - Folder CRUD

    func createFolder(with apps: [AppInfo], name: String = "Untitled", insertAt insertIndex: Int? = nil) -> FolderInfo {
        guard let delegate else { return FolderInfo(name: name, apps: apps) }

        let folder = FolderInfo(name: name, apps: apps)
        var currentFolders = delegate.currentFolders
        var currentItems = delegate.currentItems
        var currentApps = delegate.currentApps

        currentFolders.append(folder)

        // Remove apps already added to folder from app list
        for app in apps {
            if let index = currentApps.firstIndex(of: app) {
                currentApps.remove(at: index)
            }
        }

        // In current items: replace these top-layer apps with empty slots, place folder at target position
        var placeholders: [(Int, AppInfo)] = []
        var remainingApps = apps
        for (idx, item) in currentItems.enumerated() {
            guard !remainingApps.isEmpty else { break }
            if case let .app(a) = item, let matchIndex = remainingApps.firstIndex(of: a) {
                let match = remainingApps.remove(at: matchIndex)
                placeholders.append((idx, match))
            }
        }
        for (idx, _) in placeholders {
            currentItems[idx] = .empty(UUID().uuidString)
        }

        let baseIndex = placeholders.map { $0.0 }.min() ?? min(currentItems.count - 1, max(0, insertIndex ?? (currentItems.count - 1)))
        let desiredIndex = insertIndex ?? baseIndex
        let safeIndex = min(max(0, desiredIndex), max(0, currentItems.count - 1))
        if currentItems.isEmpty {
            currentItems = [.folder(folder)]
        } else {
            currentItems[safeIndex] = .folder(folder)
        }

        let filteredItems = delegate.filteredItemsRemovingHidden(from: currentItems)
        delegate.applyFolderChanges(currentFolders, items: filteredItems)
        delegate.compactItemsWithinPages()
        delegate.persistenceSaveAllOrder()

        return folder
    }

    func addAppToFolder(_ app: AppInfo, folder: FolderInfo) {
        guard let delegate else { return }
        var currentFolders = delegate.currentFolders
        var currentItems = delegate.currentItems
        var currentApps = delegate.currentApps

        guard let folderIndex = currentFolders.firstIndex(of: folder) else { return }

        var updatedFolder = currentFolders[folderIndex]
        updatedFolder.apps.append(app)
        currentFolders[folderIndex] = updatedFolder

        if let appIndex = currentApps.firstIndex(of: app) {
            currentApps.remove(at: appIndex)
        }

        if let pos = currentItems.firstIndex(of: .app(app)) {
            currentItems[pos] = .empty(UUID().uuidString)
        }

        for idx in currentItems.indices {
            if case .folder(let f) = currentItems[idx], f.id == updatedFolder.id {
                currentItems[idx] = .folder(updatedFolder)
            }
        }

        delegate.applyFolderChanges(currentFolders, items: currentItems)
        delegate.compactItemsWithinPages()
        delegate.persistenceSaveAllOrder()
    }

    func removeAppFromFolder(_ app: AppInfo, folder: FolderInfo) {
        guard let delegate else { return }
        var currentFolders = delegate.currentFolders
        var currentItems = delegate.currentItems
        var currentApps = delegate.currentApps

        guard let folderIndex = currentFolders.firstIndex(of: folder) else { return }

        var updatedFolder = currentFolders[folderIndex]
        updatedFolder.apps.removeAll { $0 == app }

        if updatedFolder.apps.isEmpty {
            currentFolders.remove(at: folderIndex)
        } else {
            currentFolders[folderIndex] = updatedFolder
        }

        var emptiedSlots: [Int] = []
        for idx in currentItems.indices {
            if case .folder(let f) = currentItems[idx], f.id == folder.id {
                if updatedFolder.apps.isEmpty {
                    currentItems[idx] = .empty(UUID().uuidString)
                    emptiedSlots.append(idx)
                } else {
                    currentItems[idx] = .folder(updatedFolder)
                }
            }
        }

        if let existingIndex = currentApps.firstIndex(where: { $0.url == app.url }) {
            currentApps[existingIndex] = app
        } else {
            currentApps.append(app)
        }
        currentApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var targetSlot: Int? = nil
        if let firstEmptied = emptiedSlots.first, firstEmptied < currentItems.count {
            targetSlot = firstEmptied
        } else {
            targetSlot = currentItems.firstIndex {
                if case .empty = $0 { return true }
                return false
            }
        }
        if let slot = targetSlot {
            currentItems[slot] = .app(app)
        } else {
            currentItems.append(.app(app))
        }

        delegate.applyFolderChanges(currentFolders, items: currentItems)
        delegate.compactItemsWithinPages()
        delegate.persistenceSaveAllOrder()
    }

    func renameFolder(_ folder: FolderInfo, newName: String) {
        guard let delegate else { return }
        var currentFolders = delegate.currentFolders
        var currentItems = delegate.currentItems

        guard let index = currentFolders.firstIndex(of: folder) else { return }

        var updatedFolder = currentFolders[index]
        updatedFolder.name = newName
        currentFolders[index] = updatedFolder

        for idx in currentItems.indices {
            if case .folder(let f) = currentItems[idx], f.id == updatedFolder.id {
                currentItems[idx] = .folder(updatedFolder)
            }
        }

        delegate.applyFolderChanges(currentFolders, items: currentItems)
        delegate.persistenceRebuildItems()
        delegate.persistenceSaveAllOrder()
    }

    func dissolveFolder(_ folder: FolderInfo) -> Bool {
        guard let delegate else { return false }
        var currentFolders = delegate.currentFolders
        var currentItems = delegate.currentItems
        var currentApps = delegate.currentApps

        let folderID = folder.id

        let resolvedFolder: FolderInfo
        if let index = currentFolders.firstIndex(where: { $0.id == folderID }) {
            resolvedFolder = currentFolders[index]
            currentFolders.remove(at: index)
        } else if let itemIndex = currentItems.firstIndex(where: {
            if case .folder(let f) = $0 { return f.id == folderID }
            return false
        }), case .folder(let fallbackFolder) = currentItems[itemIndex] {
            resolvedFolder = fallbackFolder
        } else {
            return false
        }

        let folderApps = resolvedFolder.apps
        let folderAppPaths = Set(folderApps.map { delegate.standardizedFilePath($0.url.path) })

        if !folderAppPaths.isEmpty {
            for idx in currentItems.indices {
                if case .app(let app) = currentItems[idx],
                   folderAppPaths.contains(delegate.standardizedFilePath(app.url.path)) {
                    currentItems[idx] = .empty(UUID().uuidString)
                }
            }
        }

        if let folderItemIndex = currentItems.firstIndex(where: {
            if case .folder(let f) = $0 { return f.id == folderID }
            return false
        }) {
            currentItems[folderItemIndex] = .empty(UUID().uuidString)
            var insertIndex = folderItemIndex
            for app in folderApps {
                currentItems = Self.cascadeInsert(into: currentItems, item: .app(app), at: insertIndex, itemsPerPage: delegate.currentItemsPerPage)
                insertIndex += 1
            }
        } else if !folderApps.isEmpty {
            currentItems.append(contentsOf: folderApps.map { .app($0) })
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

        let filteredItems = delegate.filteredItemsRemovingHidden(from: currentItems)
        delegate.applyFolderChanges(currentFolders, items: filteredItems)
        delegate.compactItemsWithinPages()
        delegate.persistenceSaveAllOrder()

        return true
    }

    // MARK: - Cascade Insert

    private static func cascadeInsert(into array: [LaunchpadItem], item: LaunchpadItem, at targetIndex: Int, itemsPerPage: Int) -> [LaunchpadItem] {
        var result = array
        let safeTarget = min(max(0, targetIndex), result.count)

        if safeTarget >= result.count {
            result.append(item)
            return result
        }

        result.insert(item, at: safeTarget)

        // Cascade: push overflow items to next page
        let pageStart = (safeTarget / itemsPerPage) * itemsPerPage
        let pageEnd = min(pageStart + itemsPerPage, result.count)

        if pageEnd - pageStart > itemsPerPage {
            // Remove the overflow item at pageEnd - 1 and cascade it forward
            let overflowItem = result.remove(at: pageEnd - 1)
            result = cascadeInsert(into: result, item: overflowItem, at: pageEnd, itemsPerPage: itemsPerPage)
        }

        return result
    }
}
