import SwiftUI
import Combine

/// Groups all user-configurable settings that were previously direct `@Published`
/// properties on `AppStore`.  Views and binders that previously accessed
/// `appStore.hideDock` should now use `appStore.settingsStore.hideDock`.
///
/// Persistence (UserDefaults) is handled inside `didSet` blocks, matching the
/// original pattern.  Side-effects that require `AppStore` internals (e.g.
/// window mode changes, icon cache invalidation) remain on `AppStore` via
/// forwarding computed properties so that existing callers are unaffected.
@MainActor
final class SettingsStore: ObservableObject {

    // MARK: - UserDefaults keys

    private static let gridColumnsKey = "gridColumnsPerPage"
    private static let gridRowsKey = "gridRowsPerPage"
    private static let hideMenuBarKey = "hideMenuBar"
    private static let lockLayoutKey = "lockLayoutEnabled"
    private static let rememberPageKey = "rememberLastPage"
    private static let windowOpenAnimationKey = "windowOpenAnimationEnabled"
    private static let developmentEnableCLICodeKey = "developmentEnableCLICode"
    private static let hotCornerEnabledKey = "hotCornerEnabled"
    private static let hotCornerPositionKey = "hotCornerPosition"
    private static let hotCornerTriggerDelayKey = "hotCornerTriggerDelay"
    private static let hotCornerHitboxSizeKey = "hotCornerHitboxSize"
    private static let hotCornerToggleWhenOpenKey = "hotCornerToggleWhenOpen"
    private static let gestureEnabledKey = "gestureEnabled"
    private static let gestureCloseOnPinchOutKey = "gestureCloseOnPinchOut"
    private static let gestureTapActionKey = "gestureTapAction"
    private static let gestureFingerCountKey = "gestureFingerCount"
    private static let gestureDeviceSelectionModeKey = "gestureDeviceSelectionMode"
    private static let gestureSelectedDeviceIDsKey = "gestureSelectedDeviceIDs"
    private static let gameControllerEnabledKey = "gameControllerEnabled"
    private static let gameControllerMenuToggleKey = "gameControllerMenuToggleLaunchpad"
    private static let showInMenuBarKey = "showInMenuBar"
    private static let rememberedPageIndexKey = "rememberedPageIndex"

    // MARK: - Clamping helpers

    private static let minColumnsPerPage = 3
    private static let maxColumnsPerPage = 15
    private static let minRowsPerPage = 2
    private static let maxRowsPerPage = 12
    private static let hotCornerTriggerDelayRange: ClosedRange<Double> = 0...1.2
    private static let hotCornerHitboxSizeRange: ClosedRange<Double> = 20...120
    private static let defaultHotCornerTriggerDelay: Double = 0.25
    private static let defaultHotCornerHitboxSize: Double = 50
    private static let defaultGridColumnsPerPage = 7
    private static let defaultGridRowsPerPage = 5

    private static func clampColumns(_ value: Int) -> Int {
        min(max(value, minColumnsPerPage), maxColumnsPerPage)
    }

    private static func clampRows(_ value: Int) -> Int {
        min(max(value, minRowsPerPage), maxRowsPerPage)
    }

    private static func clampHotCornerTriggerDelay(_ value: Double) -> Double {
        min(max(value, hotCornerTriggerDelayRange.lowerBound), hotCornerTriggerDelayRange.upperBound)
    }

    private static func clampHotCornerHitboxSize(_ value: Double) -> Double {
        min(max(value, hotCornerHitboxSizeRange.lowerBound), hotCornerHitboxSizeRange.upperBound)
    }

    // MARK: - Development

    @Published var developmentEnableCLICode: Bool = {
        if UserDefaults.standard.object(forKey: developmentEnableCLICodeKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: developmentEnableCLICodeKey)
    }() {
        didSet { UserDefaults.standard.set(developmentEnableCLICode, forKey: Self.developmentEnableCLICodeKey) }
    }

    // MARK: - Login / Fullscreen / Layout Lock

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

    /// Called by AppStore to sync the login item status from the system
    /// without triggering the register/unregister side effect.
    func syncFromSystem() {
        guard #available(macOS 13.0, *) else { return }
        loginItemUpdateInProgress = true
        isStartOnLogin = SMAppService.mainApp.status == .enabled
        loginItemUpdateInProgress = false
    }
    fileprivate var loginItemUpdateInProgress = false

    @Published var isFullscreenMode: Bool = false {
        didSet { UserDefaults.standard.set(isFullscreenMode, forKey: "isFullscreenMode") }
    }

    @Published var isLayoutLocked: Bool = {
        if UserDefaults.standard.object(forKey: lockLayoutKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: lockLayoutKey)
    }() {
        didSet {
            guard isLayoutLocked != oldValue else { return }
            UserDefaults.standard.set(isLayoutLocked, forKey: Self.lockLayoutKey)
        }
    }

    // MARK: - Grid Layout

    @Published var gridColumnsPerPage: Int = {
        Self.clampColumns(
            UserDefaults.standard.object(forKey: Self.gridColumnsKey) as? Int
                ?? Self.defaultGridColumnsPerPage
        )
    }() {
        didSet {
            let clamped = Self.clampColumns(gridColumnsPerPage)
            if gridColumnsPerPage != clamped {
                gridColumnsPerPage = clamped
                return
            }
            guard gridColumnsPerPage != oldValue else { return }
            UserDefaults.standard.set(gridColumnsPerPage, forKey: Self.gridColumnsKey)
        }
    }

    @Published var gridRowsPerPage: Int = {
        Self.clampRows(
            UserDefaults.standard.object(forKey: Self.gridRowsKey) as? Int
                ?? Self.defaultGridRowsPerPage
        )
    }() {
        didSet {
            let clamped = Self.clampRows(gridRowsPerPage)
            if gridRowsPerPage != clamped {
                gridRowsPerPage = clamped
                return
            }
            guard gridRowsPerPage != oldValue else { return }
            UserDefaults.standard.set(gridRowsPerPage, forKey: Self.gridRowsKey)
        }
    }

    // MARK: - Dock / Menu Bar / Window Visibility

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

    @Published var showInMenuBar: Bool = {
        UserDefaults.standard.bool(forKey: showInMenuBarKey)
    }() {
        didSet {
            guard showInMenuBar != oldValue else { return }
            UserDefaults.standard.set(showInMenuBar, forKey: Self.showInMenuBarKey)
        }
    }

    @Published var enableWindowOpenAnimation: Bool = {
        if UserDefaults.standard.object(forKey: windowOpenAnimationKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: windowOpenAnimationKey)
    }() {
        didSet { UserDefaults.standard.set(enableWindowOpenAnimation, forKey: Self.windowOpenAnimationKey) }
    }

    @Published var rememberLastPage: Bool = {
        if UserDefaults.standard.object(forKey: rememberPageKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: rememberPageKey)
    }() {
        didSet {
            UserDefaults.standard.set(rememberLastPage, forKey: Self.rememberPageKey)
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

    @Published var hotCornerPosition: AppStore.HotCornerPosition = {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: hotCornerPositionKey),
           let position = AppStore.HotCornerPosition(rawValue: raw) {
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
            if hotCornerTriggerDelay != clamped {
                hotCornerTriggerDelay = clamped
                return
            }
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
            if hotCornerHitboxSize != clamped {
                hotCornerHitboxSize = clamped
                return
            }
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

    @Published var gestureTapAction: AppStore.GestureTapAction = {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: gestureTapActionKey),
           let action = AppStore.GestureTapAction(rawValue: rawValue) {
            return action
        }
        let legacyEnabled = defaults.object(forKey: "gestureTapEnabled") as? Bool ?? false
        let legacyToggle = defaults.object(forKey: "gestureTapToggleWhenOpen") as? Bool ?? false
        let migratedAction: AppStore.GestureTapAction = legacyEnabled ? (legacyToggle ? .toggle : .open) : .off
        defaults.set(migratedAction.rawValue, forKey: gestureTapActionKey)
        return migratedAction
    }() {
        didSet {
            guard gestureTapAction != oldValue else { return }
            UserDefaults.standard.set(gestureTapAction.rawValue, forKey: Self.gestureTapActionKey)
        }
    }

    @Published var gestureFingerCount: AppStore.GestureFingerCount = {
        let defaults = UserDefaults.standard
        guard let rawValue = defaults.object(forKey: gestureFingerCountKey) as? Int,
              let count = AppStore.GestureFingerCount(rawValue: rawValue) else {
            defaults.set(AppStore.GestureFingerCount.four.rawValue, forKey: gestureFingerCountKey)
            return .four
        }
        return count
    }() {
        didSet {
            guard gestureFingerCount != oldValue else { return }
            UserDefaults.standard.set(gestureFingerCount.rawValue, forKey: Self.gestureFingerCountKey)
        }
    }

    @Published var gestureDeviceSelectionMode: GestureDeviceSelectionMode = {
        let defaults = UserDefaults.standard
        guard let rawValue = defaults.string(forKey: gestureDeviceSelectionModeKey),
              let mode = GestureDeviceSelectionMode(rawValue: rawValue) else {
            defaults.set(GestureDeviceSelectionMode.automatic.rawValue, forKey: gestureDeviceSelectionModeKey)
            return .automatic
        }
        return mode
    }() {
        didSet {
            guard gestureDeviceSelectionMode != oldValue else { return }
            UserDefaults.standard.set(gestureDeviceSelectionMode.rawValue, forKey: Self.gestureDeviceSelectionModeKey)
        }
    }

    @Published var gestureSelectedDeviceIDs: [String] = {
        let defaults = UserDefaults.standard
        let rawIDs = defaults.stringArray(forKey: gestureSelectedDeviceIDsKey) ?? []
        let normalized = Array(Set(rawIDs)).sorted()
        if rawIDs != normalized {
            defaults.set(normalized, forKey: gestureSelectedDeviceIDsKey)
        }
        return normalized
    }() {
        didSet {
            let normalized = Array(Set(gestureSelectedDeviceIDs)).sorted()
            if gestureSelectedDeviceIDs != normalized {
                gestureSelectedDeviceIDs = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: Self.gestureSelectedDeviceIDsKey)
        }
    }
}
