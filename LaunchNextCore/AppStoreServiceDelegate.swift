import Foundation

@MainActor
protocol AppStoreServiceDelegate: AnyObject {
    // AppScanner writes
    func applyScanResults(_ apps: [AppInfo], missing: Set<String>, hidden: Set<String>)
    func triggerObjectWillChange()

    // OrderPersistence writes
    func applyOrderedItems(_ items: [LaunchpadItem], folders: [FolderInfo])

    // FolderManager writes
    func applyFolderChanges(_ folders: [FolderInfo], items: [LaunchpadItem])

    // UpdateChecker writes
    func applyUpdateState(available: Bool, version: String?, url: URL?)

    // Shared access — managers read current state
    var currentApps: [AppInfo] { get }
    var currentFolders: [FolderInfo] { get }
    var currentItems: [LaunchpadItem] { get }
}
