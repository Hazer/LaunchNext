import AppKit

struct GetInfoAction: ContextMenuAction {
    let identifier = "getInfo"
    let title = "Get Info"
    let icon = "info.circle"
    let keyEquivalent = "I"
    var isEnabled: Bool { true }

    func execute(for item: LaunchpadItem, in store: AppStore) {
        guard let app = item.appInfoIfApp else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }
}
