import LaunchNextCore
import AppKit

// MARK: - Context Menu Action Protocol

protocol ContextMenuAction {
    var identifier: String { get }
    var title: String { get }
    var icon: String { get }
    var keyEquivalent: String { get }
    var isSeparator: Bool { get }
    var isEnabled: Bool { get }
    var isDestructive: Bool { get }

    func execute(for item: LaunchpadItem, in store: AppStore)
}

extension ContextMenuAction {
    var isSeparator: Bool { false }
    var isDestructive: Bool { false }
    var keyEquivalent: String { "" }
}

// MARK: - Separator

struct SeparatorAction: ContextMenuAction {
    let identifier = "separator"
    let title = ""
    let icon = ""
    let isSeparator = true
    var isEnabled: Bool { false }
    func execute(for item: LaunchpadItem, in store: AppStore) {}
}
