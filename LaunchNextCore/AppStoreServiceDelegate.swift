import Foundation
import SwiftData

@MainActor
public protocol AppStoreServiceDelegate: AnyObject {
    // MARK: - State Writes

    /// AppScanner writes
    func applyScanResults(_ apps: [AppInfo],
                          missing: [String: MissingAppPlaceholder],
                          hidden: Set<String>)
    /// OrderPersistence writes
    func applyOrderedItems(_ items: [LaunchpadItem], folders: [FolderInfo])
    /// FolderManager writes
    func applyFolderChanges(_ folders: [FolderInfo], items: [LaunchpadItem])
    /// UpdateChecker writes
    func applyUpdateState(_ state: UpdateState)

    // MARK: - UI Triggers
    func triggerObjectWillChange()
    func triggerGridRefresh()
    func triggerFolderUpdate()
    func refreshCacheAfterFolderOperation()

    // MARK: - State Reads
    var currentApps: [AppInfo] { get }
    var currentFolders: [FolderInfo] { get }
    var currentItems: [LaunchpadItem] { get }
    var currentHiddenAppPaths: Set<String> { get }
    var currentMissingPlaceholders: [String: MissingAppPlaceholder] { get }
    var currentModelContext: ModelContext? { get }

    // MARK: - Layout Helpers
    func compactItemsWithinPagesReturning() -> [LaunchpadItem]
    func removeEmptyPagesReturning() -> [LaunchpadItem]
    func filteredItemsRemovingHidden(from items: [LaunchpadItem]) -> [LaunchpadItem]
    func sanitizedFolders(_ folders: [FolderInfo]) -> [FolderInfo]

    // MARK: - Cross-Manager Routing
    func persistenceSaveAllOrder()
    func persistenceLoadAllOrder()
    func persistenceRebuildItems()

    // MARK: - Persistence Helpers
    func removableSourcePath(forAppPath path: String) -> String?
    func updateMissingPlaceholder(path: String, displayName: String?, removableSource: String?) -> MissingAppPlaceholder?
    func clearMissingPlaceholder(for path: String)
    func appInfo(from url: URL, preferredName: String?, loadIcon: Bool?) -> AppInfo
    func standardizedFilePath(_ path: String) -> String
}
