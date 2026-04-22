import LaunchNextCore
import AppKit

struct AddToDockAction: ContextMenuAction {
    let identifier = "addToDock"
    let title = "Add to Dock"
    let icon = "dock.rectangle"
    var isEnabled: Bool { true }

    func execute(for item: LaunchpadItem, in store: AppStore) {
        guard let app = item.appInfoIfApp else { return }
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = [
            "write", "com.apple.dock", "persistent-apps", "-array-add",
            "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>\(app.url.path)</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
        ]
        try? task.run()
        task.waitUntilExit()

        // Restart Dock to apply changes
        let killTask = Process()
        killTask.launchPath = "/usr/bin/killall"
        killTask.arguments = ["Dock"]
        try? killTask.run()
    }
}
