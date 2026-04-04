import AppKit

struct ShowInFinderAction: ContextMenuAction {
    let identifier = "showInFinder"
    let title = "Show in Finder"
    let icon = "folder"
    let keyEquivalent = "O"
    var isEnabled: Bool { true }

    func execute(for item: LaunchpadItem, in store: AppStore) {
        guard let app = item.appInfoIfApp else { return }
        NSWorkspace.shared.selectFile(app.url.path, inFileViewerRootedAtPath: "")
    }
}
