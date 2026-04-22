import LaunchNextCore
import AppKit

struct UninstallAction: ContextMenuAction {
    let identifier = "uninstall"
    let title = "Uninstall"
    let icon = "trash"
    var isDestructive: Bool { true }
    var isEnabled: Bool { true }

    func execute(for item: LaunchpadItem, in store: AppStore) {
        guard let app = item.appInfoIfApp else { return }
        if !store.openConfiguredUninstallTool(for: app) {
            NSSound.beep()
        }
    }
}
