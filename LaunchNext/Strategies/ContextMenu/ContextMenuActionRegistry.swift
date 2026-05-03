import LaunchNextCore
import Foundation

// MARK: - Context Menu Action Registry

class ContextMenuActionRegistry {
    static let shared = ContextMenuActionRegistry()

    private var actions: [String: ContextMenuAction] = [:]
    private var orderedIdentifiers: [String] = []

    init() {
        registerDefaultActions()
    }

    private func registerDefaultActions() {
        // Group 1: Navigation
        register(ShowInFinderAction())
        register(GetInfoAction())
        register(SeparatorAction())

        // Group 2: Management
        register(AddToDockAction())
        register(SeparatorAction())

        // Group 3: LaunchNext
        register(HideFromLaunchNextAction())
        register(SeparatorAction())

        // Group 4: Destructive
        register(UninstallAction())
    }

    func register(_ action: ContextMenuAction) {
        actions[action.identifier] = action
        if !orderedIdentifiers.contains(action.identifier) {
            orderedIdentifiers.append(action.identifier)
        }
    }

    func action(for identifier: String) -> ContextMenuAction? {
        actions[identifier]
    }

    func actions(for item: LaunchpadItem) -> [ContextMenuAction] {
        guard item.appInfoIfApp != nil else { return [] }
        return orderedIdentifiers.compactMap { identifier in
            guard let action = actions[identifier] else { return nil }
            return action.isEnabled ? action : nil
        }
    }
}
