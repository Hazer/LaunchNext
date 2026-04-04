import AppKit

struct HideFromLaunchNextAction: ContextMenuAction {
    let identifier = "hideFromLaunchNext"
    let title = "Hide from LaunchNext"
    let icon = "eye.slash"
    var isEnabled: Bool { true }

    func execute(for item: LaunchpadItem, in store: AppStore) {
        guard let app = item.appInfoIfApp else { return }
        _ = store.hideApp(app)
    }
}
