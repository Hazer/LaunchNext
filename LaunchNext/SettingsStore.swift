import LaunchNextCore
import Foundation
import Combine

/// Protocol for side effects triggered by settings changes.
/// AppStore conforms to this to handle UI refresh triggers.
@MainActor
protocol SettingsSideEffects: AnyObject {
    func handleGridRefresh()
    func handleFolderUpdate()
    func handleGridConfigurationChange()
    func handleRestartAutoRescan()
    func handleScanWithOrderPreservation()
    func handleRemoveEmptyPages()
    func handleClearIconCachesForLayoutChange()
    func handleSyncActiveAppearance(from mode: Int)
    func handlePersistLegacyAppearanceProxies()
    func handleUpdateWindowMode(isFullscreen: Bool)
    func handleRegisterStartOnLogin(_ enabled: Bool)
    func handleSetupSearchPipeline()
    func handleRefresh()
    func handleUpdateActivationPolicy()
    func handleSyncGlobalHotKeyRegistration()
}

/// Encapsulates user-facing settings with UserDefaults persistence.
/// Side effects are routed through the `sideEffects` delegate to avoid
/// direct coupling to AppStore internals.
@MainActor
final class SettingsStore: ObservableObject {

    weak var sideEffects: SettingsSideEffects?

    init() {}

    // MARK: - Key Constants (shared with AppStore for migration)

    static let customTitlesKey = "customAppTitles"
    static let hiddenAppsKey = "hiddenAppBundlePaths"
    static let gridColumnsKey = "gridColumnsPerPage"
    static let gridRowsKey = "gridRowsPerPage"
    static let columnSpacingKey = "gridColumnSpacing"
    static let rowSpacingKey = "gridRowSpacing"
    static let iconLabelFontWeightKey = "iconLabelFontWeight"
    static let showQuickRefreshButtonKey = "showQuickRefreshButton"
    static let lockLayoutKey = "lockLayoutEnabled"
    static let rememberPageKey = "rememberLastPage"
    static let rememberedPageIndexKey = "rememberedPageIndex"
    static let globalHotKeyKey = "globalHotKeyConfiguration"
    static let hoverMagnificationKey = "enableHoverMagnification"
    static let hoverMagnificationScaleKey = "hoverMagnificationScale"
    static let activePressEffectKey = "enableActivePressEffect"
    static let activePressScaleKey = "activePressScale"
    static let followScrollPagingKey = "followScrollPagingEnabled"
    static let reverseWheelPagingKey = "reverseWheelPagingDirection"
    static let hideMenuBarKey = "hideMenuBar"
    static let useCAGridRendererKey = "useCAGridRenderer"
    static let folderLayoutModeKey = "folderLayoutMode"
    static let windowOpenAnimationKey = "windowOpenAnimationEnabled"
    static let developmentEnableCLICodeKey = "developmentEnableCLICode"
    static let fuzzySearchEnabledKey = "fuzzySearchEnabled"
    static let searchDebounceMillisecondsKey = "searchDebounceMilliseconds"
    static let dockDragEnabledKey = "dockDragEnabled"
    static let dockDragSideKey = "dockDragSide"
    static let dockDragTriggerDistanceKey = "dockDragTriggerDistance"
    static let hotCornerEnabledKey = "hotCornerEnabled"
    static let hotCornerPositionKey = "hotCornerPosition"
    static let hotCornerTriggerDelayKey = "hotCornerTriggerDelay"
    static let hotCornerHitboxSizeKey = "hotCornerHitboxSize"
    static let hotCornerToggleWhenOpenKey = "hotCornerToggleWhenOpen"
    static let gestureEnabledKey = "gestureEnabled"
    static let gestureCloseOnPinchOutKey = "gestureCloseOnPinchOut"
    static let gestureTapActionKey = "gestureTapAction"
    static let gestureFingerCountKey = "gestureFingerCount"
    static let gestureDeviceSelectionModeKey = "gestureDeviceSelectionMode"
    static let gestureSelectedDeviceIDsKey = "gestureSelectedDeviceIDs"
    static let backgroundStyleKey = "launchpadBackgroundStyle"
    static let backgroundMaskEnabledKey = "launchpadBackgroundMaskEnabled"
    static let backgroundMaskLightKey = "launchpadBackgroundMaskLight"
    static let backgroundMaskDarkKey = "launchpadBackgroundMaskDark"
    static let folderPreviewHighResKey = "folderPreviewHighRes"
    static let sidebarIconPresetKey = "sidebarIconPreset"
    static let uninstallToolAppPathKey = "uninstallToolAppPath"
    static let pageIndicatorPerDisplayEnabledKey = "pageIndicatorPerDisplayEnabled"
    static let pageIndicatorPerDisplayOverridesKey = "pageIndicatorPerDisplayOverrides"
    static let dualModeAppearanceSettingsKey = "dualModeAppearanceSettings"
    static let folderDropZoneScaleKey = "folderDropZoneScale"
    static let pageIndicatorTopPaddingKey = "pageIndicatorTopPadding"
    static let searchStrategyTypeKey = "searchStrategyType"
    static let searchDebounceMsKey = "searchDebounceMs"
    static let searchThrottleMsKey = "searchThrottleMs"
    static let searchThrottleLatestKey = "searchThrottleLatest"
    static let layoutModeKey = "layoutMode"
    static let showInDockKey = "showInDock"
    static let showInMenuBarKey = "showInMenuBar"
    static let onboardingVersionKey = "onboardingVersionShown"

    // NOTE: SettingsStore is currently a placeholder infrastructure.
    // Settings properties remain on AppStore during this migration phase.
    // They will be moved here incrementally in follow-up PRs.
    // The sideEffects protocol and SettingsStore instance are wired now
    // so that future extraction can proceed without touching AppStore init.
}
