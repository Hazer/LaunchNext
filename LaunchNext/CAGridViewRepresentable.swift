import LaunchNextCore
import LaunchNextStrategies
import AppKit
import SwiftUI

// MARK: - SwiftUI Wrapper

struct CAGridViewRepresentable: NSViewRepresentable {
    @ObservedObject var appStore: AppStore
    var items: [LaunchpadItem]  // Support passing filtered items
    var iconSize: CGFloat
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat
    var contentInsets: NSEdgeInsets
    var pageSpacing: CGFloat
    var onOpenApp: ((AppInfo) -> Void)?
    var onOpenFolder: ((FolderInfo) -> Void)?
    var externalDragSourceIndex: Int?
    var externalDragHoverIndex: Int?
    var selectedIndex: Int?

    // Monitor these triggers to force refresh
    var gridRefreshTrigger: UUID { appStore.gridRefreshTrigger }
    var folderUpdateTrigger: UUID { appStore.folderUpdateTrigger }
    var iconCacheRefreshTrigger: UUID { appStore.iconCacheRefreshTrigger }

    func makeNSView(context: Context) -> CAGridView {
        let view = CAGridView(frame: .zero)

        // Initialize configuration
        view.columns = appStore.gridColumnsPerPage
        view.rows = appStore.gridRowsPerPage
        view.iconSize = iconSize
        view.columnSpacing = columnSpacing
        view.rowSpacing = rowSpacing
        view.contentInsets = contentInsets
        view.pageSpacing = pageSpacing
        view.labelFontSize = CGFloat(appStore.iconLabelFontSize)
        view.labelFontWeight = nsFontWeight(for: appStore.iconLabelFontWeight)
        view.showLabels = appStore.showLabels
        view.isLayoutLocked = appStore.isLayoutLocked
        view.folderDropZoneScale = CGFloat(appStore.folderDropZoneScale)
        let preferredScale = nsViewScale(for: view)
        view.folderPreviewScale = appStore.enableHighResFolderPreviews ? preferredScale : 1
        view.enableIconPreload = false
        view.scrollSensitivity = appStore.scrollSensitivity
        view.reverseWheelPagingDirection = appStore.reverseWheelPagingDirection
        view.hoverMagnificationEnabled = appStore.enableHoverMagnification
        view.hoverMagnificationScale = CGFloat(appStore.hoverMagnificationScale)
        view.activePressEffectEnabled = appStore.enableActivePressEffect
        view.activePressScale = CGFloat(appStore.activePressScale)
        view.animationsEnabled = appStore.enableAnimations
        view.animationDuration = appStore.animationDuration
        view.layoutMode = appStore.layoutMode
        view.dockDragEnabled = appStore.dockDragEnabled
        view.dockDragSide = appStore.dockDragSide
        view.externalAppDragTriggerDistance = CGFloat(appStore.dockDragTriggerDistance)
        view.hideAppMenuTitle = appStore.localized(.hiddenAppsAddButton)
        view.dissolveFolderMenuTitle = appStore.localized(.contextMenuDissolveFolder)
        view.uninstallWithToolMenuTitle = appStore.localized(.contextMenuUninstallWithConfiguredTool)
        view.batchSelectAppsMenuTitle = appStore.localized(.contextMenuBatchSelectApps)
        view.finishBatchSelectionMenuTitle = appStore.localized(.contextMenuFinishBatchSelection)
        view.canUseConfiguredUninstallTool = appStore.uninstallToolAppURL != nil
        view.appStore = appStore
        view.allowsBatchSelectionMode = appStore.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        // Set current page BEFORE items to ensure correct initial position
        view.setInitialPage(appStore.currentPage)
        view.items = items

        view.onItemClicked = { item, index in
            // Single click to open app or folder
            switch item {
            case .app(let app):
                onOpenApp?(app)
                AppDelegate.shared?.hideWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSWorkspace.shared.open(app.url)
                }
            case .folder(let folder):
                onOpenFolder?(folder)
            case .missingApp:
                // Missing app，Skip
                break
            case .empty:
                // empty position，Do nothing (like real Launchpad)
                // Only close window when clicking empty area outside grid
                break
            }
        }

        view.onItemDoubleClicked = { item, index in
            // Also process double-click (compatibility)
        }

        view.onPageChanged = { page in
            DispatchQueue.main.async {
                if appStore.currentPage != page {
                    appStore.currentPage = page
                }
            }
        }

        view.onFPSUpdate = { fps in
            // Can update FPS display here
        }

        view.onEmptyAreaClicked = {
            // Click empty area to close window
            AppDelegate.shared?.hideWindow()
        }

        view.onHideApp = { app in
            DispatchQueue.main.async {
                _ = appStore.hideApp(app)
            }
        }
        view.onDissolveFolder = { folder in
            DispatchQueue.main.async {
                _ = appStore.dissolveFolder(folder)
            }
        }
        view.onUninstallWithTool = { app in
            DispatchQueue.main.async {
                if !appStore.openConfiguredUninstallTool(for: app) {
                    NSSound.beep()
                }
            }
        }

        // dragCreate folder
        view.onCreateFolder = { dragApp, targetApp, insertAt in
            DispatchQueue.main.async {
                _ = appStore.createFolder(with: [dragApp, targetApp], insertAt: insertAt)
            }
        }

        // dragMove into folder
        view.onMoveToFolder = { app, folder in
            DispatchQueue.main.async {
                appStore.addAppToFolder(app, folder: folder)
            }
        }

        // Drag reorder
        view.onReorderItems = { [weak appStore] fromIndex, toIndex in
            guard let appStore else { return }
            DispatchQueue.main.async {
                Self.handleReorder(appStore: appStore, fromIndex: fromIndex, toIndex: toIndex)
            }
        }

        view.onReorderAppBatch = { [weak appStore] appPathsOrdered, toIndex in
            guard let appStore else { return }
            DispatchQueue.main.async {
                appStore.moveSelectedAppsAcrossPagesWithCascade(appPathsOrdered: appPathsOrdered, to: toIndex)
            }
        }

        // Request new page creation (when dragged to right edge)
        view.onRequestNewPage = {
            DispatchQueue.main.async {
                let itemsPerPage = appStore.gridColumnsPerPage * appStore.gridRowsPerPage
                let currentPageCount = (appStore.items.count + itemsPerPage - 1) / itemsPerPage
                let neededItems = (currentPageCount + 1) * itemsPerPage - appStore.items.count
                for _ in 0..<neededItems {
                    appStore.items.append(.empty(UUID().uuidString))
                }
            }
        }

        return view
    }

    func updateNSView(_ nsView: CAGridView, context: Context) {
        // print("🔄 [CAGrid #\(nsView.debugInstanceId)] updateNSView, window=\(nsView.window != nil), isVisible=\(nsView.window?.isVisible ?? false)")
        nsView.ensureScrollMonitorInstalled()

        // updateconfig
        let configChanged = nsView.columns != appStore.gridColumnsPerPage ||
                            nsView.rows != appStore.gridRowsPerPage ||
                            nsView.iconSize != iconSize ||
                            nsView.columnSpacing != columnSpacing ||
                            nsView.rowSpacing != rowSpacing ||
                            nsView.contentInsets.top != contentInsets.top ||
                            nsView.contentInsets.left != contentInsets.left ||
                            nsView.contentInsets.bottom != contentInsets.bottom ||
                            nsView.contentInsets.right != contentInsets.right ||
                            nsView.pageSpacing != pageSpacing ||
                            nsView.labelFontSize != CGFloat(appStore.iconLabelFontSize) ||
                            nsView.labelFontWeight != nsFontWeight(for: appStore.iconLabelFontWeight) ||
                            nsView.showLabels != appStore.showLabels ||
                            nsView.isLayoutLocked != appStore.isLayoutLocked ||
                            nsView.folderDropZoneScale != CGFloat(appStore.folderDropZoneScale) ||
                            nsView.folderPreviewScale != (appStore.enableHighResFolderPreviews ? nsViewScale(for: nsView) : 1)

        if configChanged {
            nsView.columns = appStore.gridColumnsPerPage
            nsView.rows = appStore.gridRowsPerPage
            nsView.iconSize = iconSize
            nsView.columnSpacing = columnSpacing
            nsView.rowSpacing = rowSpacing
            nsView.contentInsets = contentInsets
            nsView.pageSpacing = pageSpacing
            nsView.labelFontSize = CGFloat(appStore.iconLabelFontSize)
            nsView.labelFontWeight = nsFontWeight(for: appStore.iconLabelFontWeight)
            nsView.showLabels = appStore.showLabels
            nsView.isLayoutLocked = appStore.isLayoutLocked
            nsView.folderDropZoneScale = CGFloat(appStore.folderDropZoneScale)
            let preferredScale = nsViewScale(for: nsView)
            nsView.folderPreviewScale = appStore.enableHighResFolderPreviews ? preferredScale : 1
        }
        nsView.scrollSensitivity = appStore.scrollSensitivity
        nsView.enableIconPreload = false
        nsView.scrollSensitivity = appStore.scrollSensitivity
        nsView.reverseWheelPagingDirection = appStore.reverseWheelPagingDirection
        nsView.hoverMagnificationEnabled = appStore.enableHoverMagnification
        nsView.hoverMagnificationScale = CGFloat(appStore.hoverMagnificationScale)
        nsView.activePressEffectEnabled = appStore.enableActivePressEffect
        nsView.activePressScale = CGFloat(appStore.activePressScale)
        nsView.animationsEnabled = appStore.enableAnimations
        nsView.animationDuration = appStore.animationDuration
        nsView.layoutMode = appStore.layoutMode
        nsView.isScrollEnabled = appStore.openFolder == nil && !appStore.isSetting
        nsView.hideAppMenuTitle = appStore.localized(.hiddenAppsAddButton)
        nsView.dissolveFolderMenuTitle = appStore.localized(.contextMenuDissolveFolder)
        nsView.uninstallWithToolMenuTitle = appStore.localized(.contextMenuUninstallWithConfiguredTool)
        nsView.batchSelectAppsMenuTitle = appStore.localized(.contextMenuBatchSelectApps)
        nsView.finishBatchSelectionMenuTitle = appStore.localized(.contextMenuFinishBatchSelection)
        nsView.canUseConfiguredUninstallTool = appStore.uninstallToolAppURL != nil
        nsView.allowsBatchSelectionMode = appStore.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Check if refresh trigger changed (folder creation/modification triggers)
        let triggerChanged = context.coordinator.lastGridRefreshTrigger != gridRefreshTrigger ||
                             context.coordinator.lastFolderUpdateTrigger != folderUpdateTrigger

        if context.coordinator.lastIconCacheRefreshTrigger != iconCacheRefreshTrigger {
            context.coordinator.lastIconCacheRefreshTrigger = iconCacheRefreshTrigger
            nsView.clearIconCache()
            nsView.items = items
        }

        var didUpdateItems = false
        if triggerChanged {
            context.coordinator.lastGridRefreshTrigger = gridRefreshTrigger
            context.coordinator.lastFolderUpdateTrigger = folderUpdateTrigger
            // print("🔄 [CAGrid] Trigger changed, forcing refresh")
            nsView.items = items
            didUpdateItems = true
        } else if itemsChanged(nsView.items, items) {
            // update items - Always check for full changes (including folder name etc.)
            // print("🔄 [CAGrid] Updating items: \(nsView.items.count) -> \(items.count)")
            nsView.items = items
            didUpdateItems = true
        }

        let maxPageIndex = max(nsView.pageCount - 1, 0)
        if appStore.currentPage > maxPageIndex {
            nsView.navigateToPage(maxPageIndex, animated: false)
            DispatchQueue.main.async {
                if appStore.currentPage > maxPageIndex {
                    appStore.currentPage = maxPageIndex
                }
            }
        }

        // Syncpage
        if nsView.currentPage != appStore.currentPage {
            // print("📄 [CAGrid] Page sync: \(nsView.currentPage) -> \(appStore.currentPage)")
            nsView.navigateToPage(appStore.currentPage, animated: appStore.enableAnimations)
        }

        if didUpdateItems {
            nsView.forceSyncPageTransformIfNeeded()
        } else {
            nsView.snapToCurrentPageIfNeeded()
        }

        let safeSelectedIndex: Int? = {
            guard let selectedIndex else { return nil }
            return items.indices.contains(selectedIndex) ? selectedIndex : nil
        }()
        nsView.dockDragEnabled = appStore.dockDragEnabled
        nsView.dockDragSide = appStore.dockDragSide
        nsView.externalAppDragTriggerDistance = CGFloat(appStore.dockDragTriggerDistance)
        nsView.updateSelection(safeSelectedIndex, animated: true)
        nsView.updateExternalDragState(sourceIndex: externalDragSourceIndex,
                                       hoverIndex: externalDragHoverIndex)
        nsView.logIfMismatch("updateNSView", appPage: appStore.currentPage)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func nsFontWeight(for option: AppStore.IconLabelFontWeightOption) -> NSFont.Weight {
        switch option {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    private func nsViewScale(for view: NSView) -> CGFloat {
        if let scale = view.window?.backingScaleFactor {
            return scale
        }
        return NSScreen.main?.backingScaleFactor ?? 1
    }

    class Coordinator {
        var lastGridRefreshTrigger: UUID = UUID()
        var lastFolderUpdateTrigger: UUID = UUID()
        var lastIconCacheRefreshTrigger: UUID = UUID()
    }

    static func handleReorder(appStore: AppStore, fromIndex: Int, toIndex: Int) {
        guard fromIndex < appStore.items.count else { return }
        let itemsPerPage = appStore.gridColumnsPerPage * appStore.gridRowsPerPage
        let sourcePage = fromIndex / itemsPerPage
        let targetPage = toIndex / itemsPerPage

        if sourcePage == targetPage {
            let pageStart = sourcePage * itemsPerPage
            let pageEnd = min(pageStart + itemsPerPage, appStore.items.count)
            var newItems = appStore.items
            var pageSlice = Array(newItems[pageStart..<pageEnd])
            let localFrom = fromIndex - pageStart
            let localTo = min(toIndex - pageStart, pageSlice.count - 1)

            if localFrom != localTo && localFrom < pageSlice.count && localTo < pageSlice.count {
                let moving = pageSlice.remove(at: localFrom)
                pageSlice.insert(moving, at: localTo)
                newItems.replaceSubrange(pageStart..<pageEnd, with: pageSlice)
                appStore.items = newItems
            }
            appStore.triggerGridRefresh()
            appStore.saveAllOrder()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appStore.compactItemsWithinPages()
            }
        } else {
            let item = appStore.items[fromIndex]
            appStore.moveItemAcrossPagesWithCascade(item: item, to: toIndex)
        }
    }

    // Check if items changed (full comparison of all item IDs and names)
    private func itemsChanged(_ old: [LaunchpadItem], _ new: [LaunchpadItem]) -> Bool {
        guard old.count == new.count else { return true }
        guard !old.isEmpty else { return !new.isEmpty }

        // Full comparison of each item
        for i in 0..<old.count {
            let oldItem = old[i]
            let newItem = new[i]

            // Compare id
            if oldItem.id != newItem.id { return true }

            // Compare name (refresh needed after folder rename)
            if oldItem.name != newItem.name { return true }

            // For folders, also compare internal app count
            if case .folder(let oldFolder) = oldItem, case .folder(let newFolder) = newItem {
                if oldFolder.apps.count != newFolder.apps.count { return true }
            }
        }

        return false
    }
}

// MARK: - Preview

#if DEBUG
struct CAGridViewRepresentable_Previews: PreviewProvider {
    static var previews: some View {
        CAGridViewRepresentable(appStore: AppStore(),
                                items: [],
                                iconSize: 72,
                                columnSpacing: 20,
                                rowSpacing: 14,
                                contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                                pageSpacing: 80,
                                externalDragSourceIndex: nil,
                                externalDragHoverIndex: nil)
            .frame(width: 1200, height: 800)
    }
}
#endif
