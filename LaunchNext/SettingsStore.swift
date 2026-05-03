import SwiftUI

// Facade that exposes AppStore settings properties under a dedicated namespace.
// Views migrate from `appStore.<property>` to `appStore.settingsStore.<property>`
// to decouple from AppStore's operational state.
//
// Currently a forwarding wrapper — the @Published properties remain on AppStore
// and will be moved here once all view files have been migrated.

@MainActor
final class SettingsStore: ObservableObject {
    private unowned let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Label Settings

    var showLabels: Bool {
        get { store.showLabels }
        set { store.showLabels = newValue }
    }

    var iconLabelFontSize: Double {
        get { store.iconLabelFontSize }
        set { store.iconLabelFontSize = newValue }
    }

    var iconLabelFontWeightValue: Font.Weight {
        store.iconLabelFontWeightValue
    }

    // MARK: - Hover & Press Animation Settings

    var enableHoverMagnification: Bool {
        get { store.enableHoverMagnification }
        set { store.enableHoverMagnification = newValue }
    }

    var hoverMagnificationScale: Double {
        get { store.hoverMagnificationScale }
        set { store.hoverMagnificationScale = newValue }
    }

    var enableActivePressEffect: Bool {
        get { store.enableActivePressEffect }
        set { store.enableActivePressEffect = newValue }
    }

    var activePressScale: Double {
        get { store.activePressScale }
        set { store.activePressScale = newValue }
    }

    // MARK: - Input Settings

    var voiceFeedbackEnabled: Bool {
        get { store.voiceFeedbackEnabled }
        set { store.voiceFeedbackEnabled = newValue }
    }

    var gameControllerEnabled: Bool {
        get { store.gameControllerEnabled }
        set { store.gameControllerEnabled = newValue }
    }

    // MARK: - Layout Settings

    var isLayoutLocked: Bool {
        get { store.isLayoutLocked }
        set { store.isLayoutLocked = newValue }
    }
}
