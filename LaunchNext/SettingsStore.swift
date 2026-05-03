import SwiftUI
import Combine
import ServiceManagement
import LaunchNextCore
import LaunchNextStrategies
import LaunchNextInput

// MARK: - SettingsSideEffects

@MainActor
protocol SettingsSideEffects: AnyObject {
    func handleGridRefresh()
    func handleFolderUpdate()
    func handleGridConfigurationChange()
    func handleRestartAutoRescan()
    func handleScanWithOrderPreservation()
    func handleRemoveEmptyPages()
    func handleClearIconCachesForLayoutChange()
    func handleUpdateWindowMode(isFullscreen: Bool)
    func handleRegisterStartOnLogin(_ enabled: Bool)
    func handleSetupSearchPipeline()
    func handleRefresh()
    func handleUpdateActivationPolicy()
    func handleSyncGlobalHotKeyRegistration()
    func handleSyncActiveAppearance()
    func handlePersistLegacyAppearanceProxies()
    func handleScheduleSystemAppearanceRefresh()
    func handleCompactItemsWithinPages()
    func handleTriggerFolderUpdate()
    func handleTriggerGridRefresh()
}

// MARK: - Type Aliases for AppStore Nested Types

typealias RGBAColor = AppStore.RGBAColor
typealias DualModeAppearanceSettings = AppStore.DualModeAppearanceSettings
typealias PageIndicatorOverride = AppStore.PageIndicatorOverride
typealias HotKeyConfiguration = AppStore.HotKeyConfiguration
typealias AppearanceLayoutMode = AppStore.AppearanceLayoutMode
typealias ModeScopedAppearanceSettings = AppStore.ModeScopedAppearanceSettings
typealias GestureTapAction = AppStore.GestureTapAction
typealias DevelopmentBackgroundOverride = AppStore.DevelopmentBackgroundOverride
typealias SidebarIconPreset = AppStore.SidebarIconPreset
typealias IconLabelFontWeightOption = AppStore.IconLabelFontWeightOption
typealias DockDragSide = AppStore.DockDragSide
typealias HotCornerPosition = AppStore.HotCornerPosition
typealias BackgroundStyle = AppStore.BackgroundStyle

// MARK: - SettingsStore

@MainActor
final class SettingsStore: ObservableObject {

    weak var sideEffects: SettingsSideEffects?

    // MARK: - Constants

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
    static let useCAGridRendererKey = "useCAGridRenderer"
    static let windowOpenAnimationKey = "windowOpenAnimationEnabled"
    static let developmentEnableCLICodeKey = "developmentEnableCLICode"
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
    static let gameControllerEnabledKey = "gameControllerEnabled"
    static let gameControllerMenuToggleKey = "gameControllerMenuToggleLaunchpad"
    static let soundEffectsEnabledKey = "soundEffectsEnabled"
    static let soundLaunchpadOpenKey = "soundLaunchpadOpenSound"
    static let soundLaunchpadCloseKey = "soundLaunchpadCloseSound"
    static let soundNavigationKey = "soundNavigationSound"
    static let voiceFeedbackEnabledKey = "voiceFeedbackEnabled"
    static let folderDropZoneScaleKey = "folderDropZoneScale"
    static let pageIndicatorTopPaddingKey = "pageIndicatorTopPadding"
    static let searchStrategyTypeKey = "searchStrategyType"
    static let searchDebounceMsKey = "searchDebounceMs"
    static let searchThrottleMsKey = "searchThrottleMs"
    static let searchThrottleLatestKey = "searchThrottleLatest"
    static let layoutModeKey = "layoutMode"
    static let showInDockKey = "showInDock"
    static let showInMenuBarKey = "showInMenuBar"
    static let hideMenuBarKey = "hideMenuBar"
    static let customAppSourcesKey = "customApplicationSourcePaths"

    // Ranges & defaults
    static let minColumnsPerPage = 4
    static let maxColumnsPerPage = 10
    static let minRowsPerPage = 3
    static let maxRowsPerPage = 8
    static let minColumnSpacing: Double = 8
    static let maxColumnSpacing: Double = 50
    static let minRowSpacing: Double = 6
    static let maxRowSpacing: Double = 40
    static let defaultScrollSensitivity: Double = 0.2
    static var gridColumnRange: ClosedRange<Int> { minColumnsPerPage...maxColumnsPerPage }
    static var gridRowRange: ClosedRange<Int> { minRowsPerPage...maxRowsPerPage }
    static var columnSpacingRange: ClosedRange<Double> { minColumnSpacing...maxColumnSpacing }
    static var rowSpacingRange: ClosedRange<Double> { minRowSpacing...maxRowSpacing }
    static let hoverMagnificationRange: ClosedRange<Double> = 1.0...1.4
    static let defaultHoverMagnificationScale: Double = 1.1
    static let activePressScaleRange: ClosedRange<Double> = 0.85...1.0
    static let defaultActivePressScale: Double = 0.92
    static let folderPopoverWidthRange: ClosedRange<Double> = 0.6...0.95
    static let defaultFolderPopoverWidth: Double = 0.85
    static let folderPopoverHeightRange: ClosedRange<Double> = 0.5...0.85
    static let defaultFolderPopoverHeight: Double = 0.68
    static let folderDropZoneScaleRange: ClosedRange<Double> = 0.3...1.0
    static let defaultFolderDropZoneScale: Double = 0.65
    static let pageIndicatorTopPaddingRange: ClosedRange<Double> = 0...30
    static let defaultPageIndicatorTopPadding: Double = 8
    static let dockDragTriggerDistanceRange: ClosedRange<Double> = 8...72
    static let defaultDockDragTriggerDistance: Double = 50
    static let hotCornerTriggerDelayRange: ClosedRange<Double> = 0...1.2
    static let hotCornerHitboxSizeRange: ClosedRange<Double> = 20...120
    static let defaultHotCornerTriggerDelay: Double = 0.25
    static let defaultHotCornerHitboxSize: Double = 50
    static let searchDebounceMsRange: ClosedRange<Int> = 100...1000
    static let searchThrottleMsRange: ClosedRange<Int> = 16...500
    static let defaultLaunchpadOpenSound = "launchpad_open"
    static let defaultLaunchpadCloseSound = "launchpad_close"
    static let defaultNavigationSound = "navigation"

    private static let defaultBackgroundMaskOpacity: Double = 0.1
    static let defaultBackgroundMaskColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: defaultBackgroundMaskOpacity)

    // MARK: - Internal state

    private(set) var isApplyingScopedAppearanceState = false
    private var iconScaleWorkItem: DispatchWorkItem?
    private var loginItemUpdateInProgress = false

    // MARK: - Background / Appearance

    @Published var launchpadBackgroundStyle: BackgroundStyle = {
        if let raw = UserDefaults.standard.string(forKey: backgroundStyleKey),
           let style = BackgroundStyle(rawValue: raw) {
            return style
        }
        return .glass
    }()

    @Published var developmentBackgroundOverride: DevelopmentBackgroundOverride = .none

    @Published var developmentEnableCLICode: Bool = {
        UserDefaults.standard.object(forKey: developmentEnableCLICodeKey) as? Bool ?? false
    }() {
        didSet { UserDefaults.standard.set(developmentEnableCLICode, forKey: Self.developmentEnableCLICodeKey) }
    }

    @Published var backgroundMaskEnabled: Bool = {
        if UserDefaults.standard.object(forKey: backgroundMaskEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: backgroundMaskEnabledKey)
    }() {
        didSet { UserDefaults.standard.set(backgroundMaskEnabled, forKey: Self.backgroundMaskEnabledKey) }
    }

    @Published var backgroundMaskLightColor: RGBAColor = SettingsStore.loadBackgroundMaskColor(forKey: backgroundMaskLightKey) {
        didSet { SettingsStore.persistBackgroundMaskColor(backgroundMaskLightColor, forKey: Self.backgroundMaskLightKey) }
    }

    @Published var backgroundMaskDarkColor: RGBAColor = SettingsStore.loadBackgroundMaskColor(forKey: backgroundMaskDarkKey) {
        didSet { SettingsStore.persistBackgroundMaskColor(backgroundMaskDarkColor, forKey: Self.backgroundMaskDarkKey) }
    }

    @Published var sidebarIconPreset: SidebarIconPreset = {
        if let raw = UserDefaults.standard.string(forKey: sidebarIconPresetKey),
           let preset = SidebarIconPreset(rawValue: raw) {
            return preset
        }
        return .large
    }() {
        didSet {
            guard sidebarIconPreset != oldValue else { return }
            UserDefaults.standard.set(sidebarIconPreset.rawValue, forKey: Self.sidebarIconPresetKey)
        }
    }

    // MARK: - Search Strategy

    @Published var searchStrategyType: SearchStrategyType = {
        if let raw = UserDefaults.standard.string(forKey: searchStrategyTypeKey),
           let type = SearchStrategyType(rawValue: raw) {
            return type
        }
        return .debounce
    }() {
        didSet {
            guard searchStrategyType != oldValue else { return }
            UserDefaults.standard.set(searchStrategyType.rawValue, forKey: Self.searchStrategyTypeKey)
            sideEffects?.handleSetupSearchPipeline()
        }
    }

    @Published var searchDebounceMs: Int = {
        let stored = UserDefaults.standard.integer(forKey: searchDebounceMsKey)
        return stored > 0 ? stored : 500
    }() {
        didSet {
            guard searchDebounceMs != oldValue else { return }
            UserDefaults.standard.set(searchDebounceMs, forKey: Self.searchDebounceMsKey)
            if searchStrategyType == .debounce { sideEffects?.handleSetupSearchPipeline() }
        }
    }

    @Published var searchThrottleMs: Int = {
        let stored = UserDefaults.standard.integer(forKey: searchThrottleMsKey)
        return stored > 0 ? stored : 50
    }() {
        didSet {
            guard searchThrottleMs != oldValue else { return }
            UserDefaults.standard.set(searchThrottleMs, forKey: Self.searchThrottleMsKey)
            if searchStrategyType == .throttle { sideEffects?.handleSetupSearchPipeline() }
        }
    }

    @Published var searchThrottleLatest: Bool = {
        if UserDefaults.standard.object(forKey: searchThrottleLatestKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: searchThrottleLatestKey)
    }() {
        didSet {
            guard searchThrottleLatest != oldValue else { return }
            UserDefaults.standard.set(searchThrottleLatest, forKey: Self.searchThrottleLatestKey)
            if searchStrategyType == .throttle { sideEffects?.handleSetupSearchPipeline() }
        }
    }

    var currentSearchStrategy: SearchStrategy {
        switch searchStrategyType {
        case .debounce: return DebounceStrategy(milliseconds: searchDebounceMs)
        case .throttle: return ThrottleStrategy(milliseconds: searchThrottleMs, emitLatest: searchThrottleLatest)
        case .instant: return InstantStrategy()
        }
    }

    // MARK: - Start on Login

    @Published var isStartOnLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }() {
        didSet {
            guard !loginItemUpdateInProgress else { return }
            guard isStartOnLogin != oldValue else { return }
            guard #available(macOS 13.0, *) else {
                loginItemUpdateInProgress = true
                isStartOnLogin = false
                loginItemUpdateInProgress = false
                return
            }
            loginItemUpdateInProgress = true
            defer { loginItemUpdateInProgress = false }
            do {
                if isStartOnLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("LaunchNext: Failed to update login item setting - %@", error.localizedDescription)
                isStartOnLogin = oldValue
            }
        }
    }

    var canConfigureStartOnLogin: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    // MARK: - Fullscreen Mode

    @Published var isFullscreenMode: Bool = false {
        didSet {
            UserDefaults.standard.set(isFullscreenMode, forKey: "isFullscreenMode")
            sideEffects?.handleSyncActiveAppearance()
            sideEffects?.handlePersistLegacyAppearanceProxies()
            DispatchQueue.main.async { [weak self] in
                self?.sideEffects?.handleUpdateWindowMode(isFullscreen: self?.isFullscreenMode ?? false)
            }
            DispatchQueue.main.async { [weak self] in
                self?.sideEffects?.handleClearIconCachesForLayoutChange()
                self?.sideEffects?.handleTriggerGridRefresh()
            }
        }
    }

    // MARK: - Dual Mode Appearance

    @Published private(set) var dualModeAppearanceSettings: DualModeAppearanceSettings = DualModeAppearanceSettings(
        fullscreen: ModeScopedAppearanceSettings(iconScale: 0.95,
                                                 iconLabelFontSize: 11.0,
                                                 folderDropZoneScale: SettingsStore.defaultFolderDropZoneScale,
                                                 pageIndicatorOffset: 27.0,
                                                 pageIndicatorTopPadding: SettingsStore.defaultPageIndicatorTopPadding,
                                                 pageIndicatorPerDisplayEnabled: false,
                                                 pageIndicatorOverrides: [:]),
        compact: ModeScopedAppearanceSettings(iconScale: 0.95,
                                              iconLabelFontSize: 11.0,
                                              folderDropZoneScale: SettingsStore.defaultFolderDropZoneScale,
                                              pageIndicatorOffset: 27.0,
                                              pageIndicatorTopPadding: SettingsStore.defaultPageIndicatorTopPadding,
                                              pageIndicatorPerDisplayEnabled: false,
                                              pageIndicatorOverrides: [:])
    )

    var currentAppearanceLayoutMode: AppearanceLayoutMode {
        isFullscreenMode ? .fullscreen : .compact
    }

    // MARK: - Layout / Grid

    @Published var showLabels: Bool = {
        if UserDefaults.standard.object(forKey: "showLabels") == nil { return true }
        return UserDefaults.standard.bool(forKey: "showLabels")
    }() {
        didSet { UserDefaults.standard.set(showLabels, forKey: "showLabels") }
    }

    @Published var enableHighResFolderPreviews: Bool = {
        if UserDefaults.standard.object(forKey: folderPreviewHighResKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: folderPreviewHighResKey)
    }() {
        didSet {
            guard enableHighResFolderPreviews != oldValue else { return }
            UserDefaults.standard.set(enableHighResFolderPreviews, forKey: Self.folderPreviewHighResKey)
            sideEffects?.handleClearIconCachesForLayoutChange()
            sideEffects?.handleTriggerFolderUpdate()
            sideEffects?.handleTriggerGridRefresh()
        }
    }

    @Published var hideDock: Bool = {
        if UserDefaults.standard.object(forKey: "hideDock") == nil { return false }
        return UserDefaults.standard.bool(forKey: "hideDock")
    }() {
        didSet {
            guard hideDock != oldValue else { return }
            UserDefaults.standard.set(hideDock, forKey: "hideDock")
        }
    }

    @Published var hideMenuBar: Bool = {
        if UserDefaults.standard.object(forKey: hideMenuBarKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: hideMenuBarKey)
    }() {
        didSet {
            guard hideMenuBar != oldValue else { return }
            UserDefaults.standard.set(hideMenuBar, forKey: Self.hideMenuBarKey)
        }
    }

    @Published var scrollSensitivity: Double {
        didSet { UserDefaults.standard.set(scrollSensitivity, forKey: "scrollSensitivity") }
    }

    @Published var gridColumnsPerPage: Int {
        didSet {
            let clamped = Self.clampColumns(gridColumnsPerPage)
            if gridColumnsPerPage != clamped { gridColumnsPerPage = clamped; return }
            guard gridColumnsPerPage != oldValue else { return }
            UserDefaults.standard.set(gridColumnsPerPage, forKey: Self.gridColumnsKey)
            sideEffects?.handleGridConfigurationChange()
        }
    }

    @Published var gridRowsPerPage: Int {
        didSet {
            let clamped = Self.clampRows(gridRowsPerPage)
            if gridRowsPerPage != clamped { gridRowsPerPage = clamped; return }
            guard gridRowsPerPage != oldValue else { return }
            UserDefaults.standard.set(gridRowsPerPage, forKey: Self.gridRowsKey)
            sideEffects?.handleGridConfigurationChange()
        }
    }

    @Published var iconColumnSpacing: Double {
        didSet {
            let clamped = Self.clampColumnSpacing(iconColumnSpacing)
            if iconColumnSpacing != clamped { iconColumnSpacing = clamped; return }
            guard iconColumnSpacing != oldValue else { return }
            UserDefaults.standard.set(iconColumnSpacing, forKey: Self.columnSpacingKey)
            sideEffects?.handleTriggerGridRefresh()
        }
    }

    @Published var iconRowSpacing: Double {
        didSet {
            let clamped = Self.clampRowSpacing(iconRowSpacing)
            if iconRowSpacing != clamped { iconRowSpacing = clamped; return }
            guard iconRowSpacing != oldValue else { return }
            UserDefaults.standard.set(iconRowSpacing, forKey: Self.rowSpacingKey)
            sideEffects?.handleTriggerGridRefresh()
        }
    }

    @Published var enableDropPrediction: Bool = {
        if UserDefaults.standard.object(forKey: "enableDropPrediction") == nil { return true }
        return UserDefaults.standard.bool(forKey: "enableDropPrediction")
    }() {
        didSet { UserDefaults.standard.set(enableDropPrediction, forKey: "enableDropPrediction") }
    }

    @Published var folderDropZoneScale: Double = SettingsStore.defaultFolderDropZoneScale {
        didSet {
            let clamped = Self.clampFolderDropZoneScale(folderDropZoneScale)
            if folderDropZoneScale != clamped { folderDropZoneScale = clamped; return }
            UserDefaults.standard.set(folderDropZoneScale, forKey: Self.folderDropZoneScaleKey)
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.folderDropZoneScale = folderDropZoneScale }
        }
    }

    @Published var pageIndicatorTopPadding: Double = SettingsStore.defaultPageIndicatorTopPadding {
        didSet {
            let clamped = Self.clampPageIndicatorTopPadding(pageIndicatorTopPadding)
            if pageIndicatorTopPadding != clamped { pageIndicatorTopPadding = clamped; return }
            UserDefaults.standard.set(pageIndicatorTopPadding, forKey: Self.pageIndicatorTopPaddingKey)
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.pageIndicatorTopPadding = pageIndicatorTopPadding }
        }
    }

    @Published var enableAnimations: Bool = {
        if UserDefaults.standard.object(forKey: "enableAnimations") == nil { return true }
        return UserDefaults.standard.bool(forKey: "enableAnimations")
    }() {
        didSet { UserDefaults.standard.set(enableAnimations, forKey: "enableAnimations") }
    }

    @Published var enableHoverMagnification: Bool = {
        if UserDefaults.standard.object(forKey: hoverMagnificationKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: hoverMagnificationKey)
    }() {
        didSet { UserDefaults.standard.set(enableHoverMagnification, forKey: Self.hoverMagnificationKey) }
    }

    @Published var hoverMagnificationScale: Double = {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: hoverMagnificationScaleKey) as? Double
        let initial = stored ?? defaultHoverMagnificationScale
        let clamped = min(max(initial, hoverMagnificationRange.lowerBound), hoverMagnificationRange.upperBound)
        if stored == nil || stored != clamped {
            defaults.set(clamped, forKey: hoverMagnificationScaleKey)
        }
        return clamped
    }() {
        didSet {
            let clamped = min(max(hoverMagnificationScale, Self.hoverMagnificationRange.lowerBound), Self.hoverMagnificationRange.upperBound)
            if hoverMagnificationScale != clamped { hoverMagnificationScale = clamped; return }
            UserDefaults.standard.set(hoverMagnificationScale, forKey: Self.hoverMagnificationScaleKey)
        }
    }

    @Published var enableActivePressEffect: Bool = {
        if UserDefaults.standard.object(forKey: activePressEffectKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: activePressEffectKey)
    }() {
        didSet { UserDefaults.standard.set(enableActivePressEffect, forKey: Self.activePressEffectKey) }
    }

    @Published var followScrollPagingEnabled: Bool = {
        if UserDefaults.standard.object(forKey: followScrollPagingKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: followScrollPagingKey)
    }() {
        didSet { UserDefaults.standard.set(followScrollPagingEnabled, forKey: Self.followScrollPagingKey) }
    }

    @Published var reverseWheelPagingDirection: Bool = {
        if UserDefaults.standard.object(forKey: reverseWheelPagingKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: reverseWheelPagingKey)
    }() {
        didSet { UserDefaults.standard.set(reverseWheelPagingDirection, forKey: Self.reverseWheelPagingKey) }
    }

    @Published var useCAGridRenderer: Bool = {
        if UserDefaults.standard.object(forKey: useCAGridRendererKey) == nil { return true }
        let enabled = UserDefaults.standard.bool(forKey: useCAGridRendererKey)
        if PerformanceMode.current == .full { return false }
        return enabled
    }() {
        didSet {
            if useCAGridRenderer, performanceMode == .full {
                performanceMode = .lean
            }
            UserDefaults.standard.set(useCAGridRenderer, forKey: Self.useCAGridRendererKey)
        }
    }

    // MARK: - Layout Mode

    @Published var layoutMode: LayoutMode = {
        if let raw = UserDefaults.standard.string(forKey: layoutModeKey),
           let mode = LayoutMode(rawValue: raw) {
            return mode
        }
        return .paged
    }() {
        didSet {
            guard layoutMode != oldValue else { return }
            UserDefaults.standard.set(layoutMode.rawValue, forKey: Self.layoutModeKey)
        }
    }

    // MARK: - Dock & Menu Bar

    @Published var showInDock: Bool = {
        UserDefaults.standard.bool(forKey: showInDockKey)
    }() {
        didSet {
            guard showInDock != oldValue else { return }
            UserDefaults.standard.set(showInDock, forKey: Self.showInDockKey)
            sideEffects?.handleUpdateActivationPolicy()
        }
    }

    @Published var showInMenuBar: Bool = {
        UserDefaults.standard.bool(forKey: showInMenuBarKey)
    }() {
        didSet {
            guard showInMenuBar != oldValue else { return }
            UserDefaults.standard.set(showInMenuBar, forKey: Self.showInMenuBarKey)
        }
    }

    @Published var activePressScale: Double = {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: activePressScaleKey) as? Double
        let initial = stored ?? defaultActivePressScale
        let clamped = min(max(initial, activePressScaleRange.lowerBound), activePressScaleRange.upperBound)
        if stored == nil || stored != clamped {
            defaults.set(clamped, forKey: activePressScaleKey)
        }
        return clamped
    }() {
        didSet {
            let clamped = min(max(activePressScale, Self.activePressScaleRange.lowerBound), Self.activePressScaleRange.upperBound)
            if activePressScale != clamped { activePressScale = clamped; return }
            UserDefaults.standard.set(activePressScale, forKey: Self.activePressScaleKey)
        }
    }

    // MARK: - Icon Appearance

    @Published var iconLabelFontSize: Double = {
        let stored = UserDefaults.standard.double(forKey: "iconLabelFontSize")
        return stored == 0 ? 11.0 : stored
    }() {
        didSet {
            UserDefaults.standard.set(iconLabelFontSize, forKey: "iconLabelFontSize")
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.iconLabelFontSize = iconLabelFontSize }
            sideEffects?.handleTriggerGridRefresh()
        }
    }

    @Published var iconLabelFontWeight: IconLabelFontWeightOption = {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: iconLabelFontWeightKey),
           let value = IconLabelFontWeightOption(rawValue: raw) {
            return value
        }
        return .medium
    }() {
        didSet {
            guard iconLabelFontWeight != oldValue else { return }
            UserDefaults.standard.set(iconLabelFontWeight.rawValue, forKey: Self.iconLabelFontWeightKey)
            sideEffects?.handleTriggerGridRefresh()
        }
    }

    var iconLabelFontWeightValue: Font.Weight {
        iconLabelFontWeight.fontWeight
    }

    @Published var showQuickRefreshButton: Bool = {
        if UserDefaults.standard.object(forKey: showQuickRefreshButtonKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: showQuickRefreshButtonKey)
    }() {
        didSet {
            guard showQuickRefreshButton != oldValue else { return }
            UserDefaults.standard.set(showQuickRefreshButton, forKey: Self.showQuickRefreshButtonKey)
        }
    }

    @Published var uninstallToolAppPath: String = {
        UserDefaults.standard.string(forKey: uninstallToolAppPathKey) ?? ""
    }() {
        didSet {
            guard uninstallToolAppPath != oldValue else { return }
            let trimmed = uninstallToolAppPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.uninstallToolAppPathKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: Self.uninstallToolAppPathKey)
            }
        }
    }

    @Published var isLayoutLocked: Bool = {
        if UserDefaults.standard.object(forKey: lockLayoutKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: lockLayoutKey)
    }() {
        didSet {
            guard isLayoutLocked != oldValue else { return }
            UserDefaults.standard.set(isLayoutLocked, forKey: Self.lockLayoutKey)
            sideEffects?.handleTriggerGridRefresh()
        }
    }

    // MARK: - Updates

    @Published var autoCheckForUpdates: Bool = {
        if UserDefaults.standard.object(forKey: "autoCheckForUpdates") == nil { return true }
        return UserDefaults.standard.bool(forKey: "autoCheckForUpdates")
    }() {
        didSet { UserDefaults.standard.set(autoCheckForUpdates, forKey: "autoCheckForUpdates") }
    }

    // MARK: - Animation

    @Published var animationDuration: Double = {
        let stored = UserDefaults.standard.double(forKey: "animationDuration")
        return stored == 0 ? 0.3 : stored
    }() {
        didSet { UserDefaults.standard.set(animationDuration, forKey: "animationDuration") }
    }

    @Published var enableWindowOpenAnimation: Bool = {
        if UserDefaults.standard.object(forKey: windowOpenAnimationKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: windowOpenAnimationKey)
    }() {
        didSet { UserDefaults.standard.set(enableWindowOpenAnimation, forKey: Self.windowOpenAnimationKey) }
    }

    // MARK: - Misc Settings

    @Published var useLocalizedThirdPartyTitles: Bool = {
        if UserDefaults.standard.object(forKey: "useLocalizedThirdPartyTitles") == nil { return true }
        return UserDefaults.standard.bool(forKey: "useLocalizedThirdPartyTitles")
    }() {
        didSet {
            guard oldValue != useLocalizedThirdPartyTitles else { return }
            UserDefaults.standard.set(useLocalizedThirdPartyTitles, forKey: "useLocalizedThirdPartyTitles")
            sideEffects?.handleRefresh()
        }
    }

    @Published var showFPSOverlay: Bool = {
        if UserDefaults.standard.object(forKey: "showFPSOverlay") == nil { return false }
        return UserDefaults.standard.bool(forKey: "showFPSOverlay")
    }() {
        didSet { UserDefaults.standard.set(showFPSOverlay, forKey: "showFPSOverlay") }
    }

    @Published var performanceMode: PerformanceMode = PerformanceMode.current {
        didSet {
            guard oldValue != performanceMode else { return }
            PerformanceMode.persist(performanceMode)
            if performanceMode == .full, useCAGridRenderer {
                useCAGridRenderer = false
            }
        }
    }

    // MARK: - Game Controller

    @Published var gameControllerEnabled: Bool = {
        if UserDefaults.standard.object(forKey: gameControllerEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: gameControllerEnabledKey)
    }() {
        didSet {
            guard oldValue != gameControllerEnabled else { return }
            UserDefaults.standard.set(gameControllerEnabled, forKey: Self.gameControllerEnabledKey)
        }
    }

    @Published var gameControllerMenuTogglesLaunchpad: Bool = {
        if UserDefaults.standard.object(forKey: gameControllerMenuToggleKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: gameControllerMenuToggleKey)
    }() {
        didSet {
            guard oldValue != gameControllerMenuTogglesLaunchpad else { return }
            UserDefaults.standard.set(gameControllerMenuTogglesLaunchpad, forKey: Self.gameControllerMenuToggleKey)
        }
    }

    // MARK: - Sound

    @Published var soundEffectsEnabled: Bool = {
        if UserDefaults.standard.object(forKey: soundEffectsEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: soundEffectsEnabledKey)
    }() {
        didSet {
            guard oldValue != soundEffectsEnabled else { return }
            UserDefaults.standard.set(soundEffectsEnabled, forKey: Self.soundEffectsEnabledKey)
        }
    }

    @Published var soundLaunchpadOpenSound: String = {
        let stored = UserDefaults.standard.string(forKey: soundLaunchpadOpenKey)
        return SettingsStore.normalizedSoundName(stored, defaultValue: SettingsStore.defaultLaunchpadOpenSound)
    }() {
        didSet { UserDefaults.standard.set(soundLaunchpadOpenSound, forKey: Self.soundLaunchpadOpenKey) }
    }

    @Published var soundLaunchpadCloseSound: String = {
        let stored = UserDefaults.standard.string(forKey: soundLaunchpadCloseKey)
        return SettingsStore.normalizedSoundName(stored, defaultValue: SettingsStore.defaultLaunchpadCloseSound)
    }() {
        didSet { UserDefaults.standard.set(soundLaunchpadCloseSound, forKey: Self.soundLaunchpadCloseKey) }
    }

    @Published var soundNavigationSound: String = {
        let stored = UserDefaults.standard.string(forKey: soundNavigationKey)
        return SettingsStore.normalizedSoundName(stored, defaultValue: SettingsStore.defaultNavigationSound)
    }() {
        didSet { UserDefaults.standard.set(soundNavigationSound, forKey: Self.soundNavigationKey) }
    }

    @Published var voiceFeedbackEnabled: Bool = {
        if UserDefaults.standard.object(forKey: voiceFeedbackEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: voiceFeedbackEnabledKey)
    }() {
        didSet {
            guard oldValue != voiceFeedbackEnabled else { return }
            UserDefaults.standard.set(voiceFeedbackEnabled, forKey: Self.voiceFeedbackEnabledKey)
            if !voiceFeedbackEnabled { VoiceManager.shared.stop() }
        }
    }

    // MARK: - Page Indicator

    @Published var pageIndicatorOffset: Double = {
        if UserDefaults.standard.object(forKey: "pageIndicatorOffset") == nil { return 27.0 }
        return UserDefaults.standard.double(forKey: "pageIndicatorOffset")
    }() {
        didSet {
            UserDefaults.standard.set(pageIndicatorOffset, forKey: "pageIndicatorOffset")
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.pageIndicatorOffset = pageIndicatorOffset }
        }
    }

    @Published var pageIndicatorPerDisplayEnabled: Bool = {
        if UserDefaults.standard.object(forKey: pageIndicatorPerDisplayEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: pageIndicatorPerDisplayEnabledKey)
    }() {
        didSet {
            UserDefaults.standard.set(pageIndicatorPerDisplayEnabled, forKey: Self.pageIndicatorPerDisplayEnabledKey)
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.pageIndicatorPerDisplayEnabled = pageIndicatorPerDisplayEnabled }
        }
    }

    @Published private(set) var pageIndicatorOverrides: [String: PageIndicatorOverride] = SettingsStore.loadPageIndicatorOverrides() {
        didSet {
            persistPageIndicatorOverrides(pageIndicatorOverrides)
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.pageIndicatorOverrides = pageIndicatorOverrides }
        }
    }

    // MARK: - Remember / Folder Popover

    @Published var rememberLastPage: Bool = {
        if UserDefaults.standard.object(forKey: rememberPageKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: rememberPageKey)
    }() {
        didSet {
            UserDefaults.standard.set(rememberLastPage, forKey: Self.rememberPageKey)
        }
    }

    @Published var folderPopoverWidthFactor: Double = {
        let stored = UserDefaults.standard.double(forKey: "folderPopoverWidthFactor")
        if stored == 0 { return defaultFolderPopoverWidth }
        return clampFolderWidth(stored)
    }() {
        didSet {
            let clamped = Self.clampFolderWidth(folderPopoverWidthFactor)
            if folderPopoverWidthFactor != clamped { folderPopoverWidthFactor = clamped; return }
            UserDefaults.standard.set(folderPopoverWidthFactor, forKey: "folderPopoverWidthFactor")
        }
    }

    @Published var folderPopoverHeightFactor: Double = {
        let stored = UserDefaults.standard.double(forKey: "folderPopoverHeightFactor")
        if stored == 0 { return defaultFolderPopoverHeight }
        return clampFolderHeight(stored)
    }() {
        didSet {
            let clamped = Self.clampFolderHeight(folderPopoverHeightFactor)
            if folderPopoverHeightFactor != clamped { folderPopoverHeightFactor = clamped; return }
            UserDefaults.standard.set(folderPopoverHeightFactor, forKey: "folderPopoverHeightFactor")
        }
    }

    // MARK: - Appearance

    @Published var appearancePreference: AppearancePreference = {
        if let raw = UserDefaults.standard.string(forKey: "appearancePreference"),
           let pref = AppearancePreference(rawValue: raw) {
            return pref
        }
        return .system
    }() {
        didSet {
            guard oldValue != appearancePreference else { return }
            UserDefaults.standard.set(appearancePreference.rawValue, forKey: "appearancePreference")
        }
    }

    // MARK: - Hot Key

    @Published var globalHotKey: HotKeyConfiguration? = SettingsStore.loadHotKeyConfiguration() {
        didSet {
            persistHotKeyConfiguration()
            sideEffects?.handleSyncGlobalHotKeyRegistration()
        }
    }

    // MARK: - Dock Drag

    @Published var dockDragEnabled: Bool = {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: dockDragEnabledKey) as? Bool {
            return stored
        }
        let legacySideRaw = defaults.string(forKey: dockDragSideKey)
        let enabled = legacySideRaw != DockDragSide.disabled.rawValue
        defaults.set(enabled, forKey: dockDragEnabledKey)
        return enabled
    }() {
        didSet {
            guard dockDragEnabled != oldValue else { return }
            UserDefaults.standard.set(dockDragEnabled, forKey: Self.dockDragEnabledKey)
        }
    }

    @Published var dockDragSide: DockDragSide = {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: dockDragSideKey),
           let side = DockDragSide(rawValue: raw),
           side != .disabled {
            return side
        }
        return .bottom
    }() {
        didSet {
            guard dockDragSide != oldValue else { return }
            UserDefaults.standard.set(dockDragSide.rawValue, forKey: Self.dockDragSideKey)
        }
    }

    @Published var dockDragTriggerDistance: Double = {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: dockDragTriggerDistanceKey) as? Double
        let initial = stored ?? defaultDockDragTriggerDistance
        let clamped = clampDockDragTriggerDistance(initial)
        if stored == nil || stored != clamped {
            defaults.set(clamped, forKey: dockDragTriggerDistanceKey)
        }
        return clamped
    }() {
        didSet {
            let clamped = Self.clampDockDragTriggerDistance(dockDragTriggerDistance)
            if dockDragTriggerDistance != clamped { dockDragTriggerDistance = clamped; return }
            UserDefaults.standard.set(dockDragTriggerDistance, forKey: Self.dockDragTriggerDistanceKey)
        }
    }

    // MARK: - Hot Corner

    @Published var hotCornerEnabled: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: hotCornerEnabledKey) == nil {
            defaults.set(false, forKey: hotCornerEnabledKey)
        }
        return defaults.bool(forKey: hotCornerEnabledKey)
    }() {
        didSet {
            guard hotCornerEnabled != oldValue else { return }
            UserDefaults.standard.set(hotCornerEnabled, forKey: Self.hotCornerEnabledKey)
        }
    }

    @Published var hotCornerPosition: HotCornerPosition = {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: hotCornerPositionKey),
           let position = HotCornerPosition(rawValue: raw) {
            return position
        }
        return .topLeft
    }() {
        didSet {
            guard hotCornerPosition != oldValue else { return }
            UserDefaults.standard.set(hotCornerPosition.rawValue, forKey: Self.hotCornerPositionKey)
        }
    }

    @Published var hotCornerTriggerDelay: Double = {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: hotCornerTriggerDelayKey) as? Double
        let initial = stored ?? defaultHotCornerTriggerDelay
        let clamped = clampHotCornerTriggerDelay(initial)
        if stored == nil || stored != clamped {
            defaults.set(clamped, forKey: hotCornerTriggerDelayKey)
        }
        return clamped
    }() {
        didSet {
            let clamped = Self.clampHotCornerTriggerDelay(hotCornerTriggerDelay)
            if hotCornerTriggerDelay != clamped { hotCornerTriggerDelay = clamped; return }
            UserDefaults.standard.set(hotCornerTriggerDelay, forKey: Self.hotCornerTriggerDelayKey)
        }
    }

    @Published var hotCornerHitboxSize: Double = {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: hotCornerHitboxSizeKey) as? Double
        let initial = stored ?? defaultHotCornerHitboxSize
        let clamped = clampHotCornerHitboxSize(initial)
        if stored == nil || stored != clamped {
            defaults.set(clamped, forKey: hotCornerHitboxSizeKey)
        }
        return clamped
    }() {
        didSet {
            let clamped = Self.clampHotCornerHitboxSize(hotCornerHitboxSize)
            if hotCornerHitboxSize != clamped { hotCornerHitboxSize = clamped; return }
            UserDefaults.standard.set(hotCornerHitboxSize, forKey: Self.hotCornerHitboxSizeKey)
        }
    }

    @Published var hotCornerToggleWhenOpen: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: hotCornerToggleWhenOpenKey) == nil {
            defaults.set(false, forKey: hotCornerToggleWhenOpenKey)
        }
        return defaults.bool(forKey: hotCornerToggleWhenOpenKey)
    }() {
        didSet {
            guard hotCornerToggleWhenOpen != oldValue else { return }
            UserDefaults.standard.set(hotCornerToggleWhenOpen, forKey: Self.hotCornerToggleWhenOpenKey)
        }
    }

    // MARK: - Gesture

    @Published var gestureEnabled: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: gestureEnabledKey) == nil {
            defaults.set(false, forKey: gestureEnabledKey)
        }
        return defaults.bool(forKey: gestureEnabledKey)
    }() {
        didSet {
            guard gestureEnabled != oldValue else { return }
            UserDefaults.standard.set(gestureEnabled, forKey: Self.gestureEnabledKey)
        }
    }

    @Published var gestureCloseOnPinchOut: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: gestureCloseOnPinchOutKey) == nil {
            defaults.set(false, forKey: gestureCloseOnPinchOutKey)
        }
        return defaults.bool(forKey: gestureCloseOnPinchOutKey)
    }() {
        didSet {
            guard gestureCloseOnPinchOut != oldValue else { return }
            UserDefaults.standard.set(gestureCloseOnPinchOut, forKey: Self.gestureCloseOnPinchOutKey)
        }
    }

    @Published var gestureTapAction: GestureTapAction = {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: gestureTapActionKey),
           let action = GestureTapAction(rawValue: rawValue) {
            return action
        }
        let legacyEnabled = defaults.object(forKey: "gestureTapEnabled") as? Bool ?? false
        let legacyToggle = defaults.object(forKey: "gestureTapToggleWhenOpen") as? Bool ?? false
        let migratedAction: GestureTapAction = legacyEnabled ? (legacyToggle ? .toggle : .open) : .off
        defaults.set(migratedAction.rawValue, forKey: gestureTapActionKey)
        return migratedAction
    }() {
        didSet {
            guard gestureTapAction != oldValue else { return }
            UserDefaults.standard.set(gestureTapAction.rawValue, forKey: Self.gestureTapActionKey)
        }
    }

    // MARK: - Gesture (Extended)

    @Published var gestureFingerCount: Int = UserDefaults.standard.integer(forKey: "gestureFingerCount") {
        didSet { UserDefaults.standard.set(gestureFingerCount, forKey: "gestureFingerCount") }
    }

    @Published var gestureDeviceSelectionMode: Int = UserDefaults.standard.integer(forKey: "gestureDeviceSelectionMode") {
        didSet { UserDefaults.standard.set(gestureDeviceSelectionMode, forKey: "gestureDeviceSelectionMode") }
    }

    @Published var gestureSelectedDeviceIDs: [String] = UserDefaults.standard.stringArray(forKey: "gestureSelectedDeviceIDs") ?? [] {
        didSet { UserDefaults.standard.set(gestureSelectedDeviceIDs, forKey: "gestureSelectedDeviceIDs") }
    }

    // MARK: - Language

    @Published var preferredLanguage: AppLanguage = {
        if let raw = UserDefaults.standard.string(forKey: "preferredLanguage"),
           let lang = AppLanguage(rawValue: raw) {
            return lang
        }
        return .system
    }() {
        didSet { UserDefaults.standard.set(preferredLanguage.rawValue, forKey: "preferredLanguage") }
    }

    // MARK: - Custom App Sources

    @Published var customAppSourcePaths: [String] = {
        UserDefaults.standard.array(forKey: customAppSourcesKey) as? [String] ?? []
    }() {
        didSet {
            guard customAppSourcePaths != oldValue else { return }
            UserDefaults.standard.set(customAppSourcePaths, forKey: Self.customAppSourcesKey)
            sideEffects?.handleRestartAutoRescan()
            sideEffects?.handleScanWithOrderPreservation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.sideEffects?.handleRemoveEmptyPages()
            }
        }
    }

    // MARK: - Icon Scale

    @Published var iconScale: Double = 0.95 {
        didSet {
            UserDefaults.standard.set(iconScale, forKey: "iconScale")
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.iconScale = iconScale }
            iconScaleWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.sideEffects?.handleTriggerGridRefresh() }
            iconScaleWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        scrollSensitivity = defaults.object(forKey: "scrollSensitivity") as? Double ?? Self.defaultScrollSensitivity
        gridColumnsPerPage = Self.clampColumns(min(max(defaults.integer(forKey: Self.gridColumnsKey), Self.gridColumnRange.lowerBound), Self.gridColumnRange.upperBound))
        gridRowsPerPage = Self.clampRows(min(max(defaults.integer(forKey: Self.gridRowsKey), Self.gridRowRange.lowerBound), Self.gridRowRange.upperBound))
        iconColumnSpacing = Self.clampColumnSpacing(defaults.object(forKey: Self.columnSpacingKey) as? Double ?? 18)
        iconRowSpacing = Self.clampRowSpacing(defaults.object(forKey: Self.rowSpacingKey) as? Double ?? 14)

        isFullscreenMode = defaults.bool(forKey: "isFullscreenMode")

        if let storedDualMode = Self.loadDualModeAppearanceSettings(from: defaults) {
            dualModeAppearanceSettings = storedDualMode
        } else {
            let legacy = Self.legacyAppearanceSettings(from: defaults)
            dualModeAppearanceSettings = DualModeAppearanceSettings(fullscreen: legacy, compact: legacy)
            persistDualModeAppearanceSettings()
        }

        iconScale = defaults.object(forKey: "iconScale") as? Double ?? dualModeAppearanceSettings[currentAppearanceLayoutMode].iconScale
    }

    // MARK: - Helper Methods

    private static func clampColumns(_ value: Int) -> Int {
        min(max(value, minColumnsPerPage), maxColumnsPerPage)
    }

    private static func clampRows(_ value: Int) -> Int {
        min(max(value, minRowsPerPage), maxRowsPerPage)
    }

    private static func clampColumnSpacing(_ value: Double) -> Double {
        min(max(value, minColumnSpacing), maxColumnSpacing)
    }

    private static func clampRowSpacing(_ value: Double) -> Double {
        min(max(value, minRowSpacing), maxRowSpacing)
    }

    private static func clampFolderWidth(_ value: Double) -> Double {
        min(max(value, folderPopoverWidthRange.lowerBound), folderPopoverWidthRange.upperBound)
    }

    private static func clampFolderHeight(_ value: Double) -> Double {
        min(max(value, folderPopoverHeightRange.lowerBound), folderPopoverHeightRange.upperBound)
    }

    private static func clampFolderDropZoneScale(_ value: Double) -> Double {
        min(max(value, folderDropZoneScaleRange.lowerBound), folderDropZoneScaleRange.upperBound)
    }

    private static func clampPageIndicatorTopPadding(_ value: Double) -> Double {
        min(max(value, pageIndicatorTopPaddingRange.lowerBound), pageIndicatorTopPaddingRange.upperBound)
    }

    private static func clampDockDragTriggerDistance(_ value: Double) -> Double {
        min(max(value, dockDragTriggerDistanceRange.lowerBound), dockDragTriggerDistanceRange.upperBound)
    }

    private static func clampHotCornerTriggerDelay(_ value: Double) -> Double {
        min(max(value, hotCornerTriggerDelayRange.lowerBound), hotCornerTriggerDelayRange.upperBound)
    }

    private static func clampHotCornerHitboxSize(_ value: Double) -> Double {
        min(max(value, hotCornerHitboxSizeRange.lowerBound), hotCornerHitboxSizeRange.upperBound)
    }

    static func loadBackgroundMaskColor(forKey key: String) -> RGBAColor {
        guard let data = UserDefaults.standard.data(forKey: key) else { return defaultBackgroundMaskColor }
        if let decoded = try? JSONDecoder().decode(RGBAColor.self, from: data) { return decoded }
        UserDefaults.standard.removeObject(forKey: key)
        return defaultBackgroundMaskColor
    }

    static func persistBackgroundMaskColor(_ color: RGBAColor, forKey key: String) {
        if let data = try? JSONEncoder().encode(color) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func loadPageIndicatorOverrides() -> [String: PageIndicatorOverride] {
        guard let data = UserDefaults.standard.data(forKey: pageIndicatorPerDisplayOverridesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: PageIndicatorOverride].self, from: data)) ?? [:]
    }

    private func persistPageIndicatorOverrides(_ overrides: [String: PageIndicatorOverride]) {
        if overrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pageIndicatorPerDisplayOverridesKey)
            return
        }
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.pageIndicatorPerDisplayOverridesKey)
        }
    }

    private static func loadHotKeyConfiguration() -> HotKeyConfiguration? {
        guard let dict = UserDefaults.standard.dictionary(forKey: globalHotKeyKey),
              let keyCode = dict["keyCode"] as? Int,
              let modifiersRawValue = dict["modifiersRawValue"] as? Int else {
            return nil
        }
        return HotKeyConfiguration(keyCode: UInt16(keyCode), modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifiersRawValue)))
    }

    private func persistHotKeyConfiguration() {
        if let config = globalHotKey {
            let dict: [String: Any] = [
                "keyCode": Int(config.keyCode),
                "modifiersRawValue": Int(config.modifiersRawValue)
            ]
            UserDefaults.standard.set(dict, forKey: Self.globalHotKeyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.globalHotKeyKey)
        }
    }

    static func normalizedSoundName(_ name: String?, defaultValue: String) -> String {
        guard let name, !name.isEmpty else { return defaultValue }
        return name
    }

    // MARK: - Scoped Appearance Helpers

    func updateScopedAppearanceSettings(for mode: AppearanceLayoutMode,
                                        _ update: (inout ModeScopedAppearanceSettings) -> Void) {
        var settings = dualModeAppearanceSettings
        var scoped = settings[mode]
        update(&scoped)
        settings[mode] = Self.normalizedAppearanceSettings(scoped)
        dualModeAppearanceSettings = settings
        persistDualModeAppearanceSettings()
    }

    func syncActiveAppearanceProxies(from mode: AppearanceLayoutMode) {
        let settings = dualModeAppearanceSettings[mode]
        isApplyingScopedAppearanceState = true
        defer { isApplyingScopedAppearanceState = false }
        iconScale = settings.iconScale
        iconLabelFontSize = settings.iconLabelFontSize
        folderDropZoneScale = settings.folderDropZoneScale
        pageIndicatorOffset = settings.pageIndicatorOffset
        pageIndicatorTopPadding = settings.pageIndicatorTopPadding
        pageIndicatorPerDisplayEnabled = settings.pageIndicatorPerDisplayEnabled
        pageIndicatorOverrides = settings.pageIndicatorOverrides
    }

    func persistLegacyAppearanceProxyValues() {
        let defaults = UserDefaults.standard
        defaults.set(iconScale, forKey: "iconScale")
        defaults.set(iconLabelFontSize, forKey: "iconLabelFontSize")
        defaults.set(folderDropZoneScale, forKey: Self.folderDropZoneScaleKey)
        defaults.set(pageIndicatorOffset, forKey: "pageIndicatorOffset")
        defaults.set(pageIndicatorTopPadding, forKey: Self.pageIndicatorTopPaddingKey)
        defaults.set(pageIndicatorPerDisplayEnabled, forKey: Self.pageIndicatorPerDisplayEnabledKey)
        persistPageIndicatorOverrides(pageIndicatorOverrides)
    }

    // Scoped accessors
    func scopedIconScale(for mode: AppearanceLayoutMode) -> Double {
        dualModeAppearanceSettings[mode].iconScale
    }
    func setScopedIconScale(_ value: Double, for mode: AppearanceLayoutMode) {
        if mode == currentAppearanceLayoutMode { iconScale = value }
        else { updateScopedAppearanceSettings(for: mode) { $0.iconScale = value } }
    }

    func scopedIconLabelFontSize(for mode: AppearanceLayoutMode) -> Double {
        dualModeAppearanceSettings[mode].iconLabelFontSize
    }
    func setScopedIconLabelFontSize(_ value: Double, for mode: AppearanceLayoutMode) {
        if mode == currentAppearanceLayoutMode { iconLabelFontSize = value }
        else { updateScopedAppearanceSettings(for: mode) { $0.iconLabelFontSize = value } }
    }

    func scopedFolderDropZoneScale(for mode: AppearanceLayoutMode) -> Double {
        dualModeAppearanceSettings[mode].folderDropZoneScale
    }
    func setScopedFolderDropZoneScale(_ value: Double, for mode: AppearanceLayoutMode) {
        let clamped = Self.clampFolderDropZoneScale(value)
        if mode == currentAppearanceLayoutMode { folderDropZoneScale = clamped }
        else { updateScopedAppearanceSettings(for: mode) { $0.folderDropZoneScale = clamped } }
    }

    func scopedPageIndicatorOffset(for mode: AppearanceLayoutMode) -> Double {
        dualModeAppearanceSettings[mode].pageIndicatorOffset
    }
    func setScopedPageIndicatorOffset(_ value: Double, for mode: AppearanceLayoutMode) {
        if mode == currentAppearanceLayoutMode { pageIndicatorOffset = value }
        else { updateScopedAppearanceSettings(for: mode) { $0.pageIndicatorOffset = value } }
    }

    func scopedPageIndicatorTopPadding(for mode: AppearanceLayoutMode) -> Double {
        dualModeAppearanceSettings[mode].pageIndicatorTopPadding
    }
    func setScopedPageIndicatorTopPadding(_ value: Double, for mode: AppearanceLayoutMode) {
        let clamped = Self.clampPageIndicatorTopPadding(value)
        if mode == currentAppearanceLayoutMode { pageIndicatorTopPadding = clamped }
        else { updateScopedAppearanceSettings(for: mode) { $0.pageIndicatorTopPadding = clamped } }
    }

    func scopedPageIndicatorPerDisplayEnabled(for mode: AppearanceLayoutMode) -> Bool {
        dualModeAppearanceSettings[mode].pageIndicatorPerDisplayEnabled
    }
    func setScopedPageIndicatorPerDisplayEnabled(_ enabled: Bool, for mode: AppearanceLayoutMode) {
        if mode == currentAppearanceLayoutMode { pageIndicatorPerDisplayEnabled = enabled }
        else { updateScopedAppearanceSettings(for: mode) { $0.pageIndicatorPerDisplayEnabled = enabled } }
    }

    func scopedPageIndicatorOverrides(for mode: AppearanceLayoutMode) -> [String: PageIndicatorOverride] {
        dualModeAppearanceSettings[mode].pageIndicatorOverrides
    }

    func setPageIndicatorOverride(_ override: PageIndicatorOverride?, for screenID: String) {
        if let override {
            pageIndicatorOverrides[screenID] = override
        } else {
            pageIndicatorOverrides.removeValue(forKey: screenID)
        }
    }

    // MARK: - Private Persistence Helpers

    private static func legacyAppearanceSettings(from defaults: UserDefaults) -> ModeScopedAppearanceSettings {
        let iconScale = defaults.object(forKey: "iconScale") as? Double ?? 0.95
        let iconLabelFontSize = defaults.object(forKey: "iconLabelFontSize") as? Double ?? 11.0
        let dropZoneScale = clampFolderDropZoneScale(defaults.object(forKey: folderDropZoneScaleKey) as? Double ?? defaultFolderDropZoneScale)
        let indicatorOffset = defaults.object(forKey: "pageIndicatorOffset") as? Double ?? 27.0
        let indicatorTopPadding = clampPageIndicatorTopPadding(defaults.object(forKey: pageIndicatorTopPaddingKey) as? Double ?? defaultPageIndicatorTopPadding)
        let perDisplayEnabled = defaults.object(forKey: pageIndicatorPerDisplayEnabledKey) as? Bool ?? false
        let overrides = (try? JSONDecoder().decode([String: PageIndicatorOverride].self,
                                                   from: defaults.data(forKey: pageIndicatorPerDisplayOverridesKey) ?? Data())) ?? [:]
        return ModeScopedAppearanceSettings(iconScale: iconScale,
                                            iconLabelFontSize: iconLabelFontSize,
                                            folderDropZoneScale: dropZoneScale,
                                            pageIndicatorOffset: indicatorOffset,
                                            pageIndicatorTopPadding: indicatorTopPadding,
                                            pageIndicatorPerDisplayEnabled: perDisplayEnabled,
                                            pageIndicatorOverrides: overrides)
    }

    private static func normalizedAppearanceSettings(_ settings: ModeScopedAppearanceSettings) -> ModeScopedAppearanceSettings {
        ModeScopedAppearanceSettings(iconScale: settings.iconScale,
                                     iconLabelFontSize: settings.iconLabelFontSize,
                                     folderDropZoneScale: clampFolderDropZoneScale(settings.folderDropZoneScale),
                                     pageIndicatorOffset: settings.pageIndicatorOffset,
                                     pageIndicatorTopPadding: clampPageIndicatorTopPadding(settings.pageIndicatorTopPadding),
                                     pageIndicatorPerDisplayEnabled: settings.pageIndicatorPerDisplayEnabled,
                                     pageIndicatorOverrides: settings.pageIndicatorOverrides)
    }

    private static func normalizedDualModeAppearanceSettings(_ settings: DualModeAppearanceSettings) -> DualModeAppearanceSettings {
        DualModeAppearanceSettings(fullscreen: normalizedAppearanceSettings(settings.fullscreen),
                                   compact: normalizedAppearanceSettings(settings.compact))
    }

    private static func loadDualModeAppearanceSettings(from defaults: UserDefaults) -> DualModeAppearanceSettings? {
        guard let data = defaults.data(forKey: dualModeAppearanceSettingsKey),
              let decoded = try? JSONDecoder().decode(DualModeAppearanceSettings.self, from: data) else {
            return nil
        }
        return normalizedDualModeAppearanceSettings(decoded)
    }

    private func persistDualModeAppearanceSettings() {
        let normalized = Self.normalizedDualModeAppearanceSettings(dualModeAppearanceSettings)
        dualModeAppearanceSettings = normalized
        if let data = try? JSONEncoder().encode(normalized) {
            UserDefaults.standard.set(data, forKey: Self.dualModeAppearanceSettingsKey)
        }
    }

    static func screenIdentifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return screen.localizedName
    }
}
