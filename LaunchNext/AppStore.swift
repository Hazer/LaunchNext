import LaunchNextStrategies
import LaunchNextUtilities
import LaunchNextCore
import Foundation
import AppKit
import Combine
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Carbon
import Carbon.HIToolbox
import ServiceManagement

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    var localizationKey: LocalizationKey {
        switch self {
        case .system: return .appearanceModeFollowSystem
        case .light: return .appearanceModeLight
        case .dark: return .appearanceModeDark
        }
    }
}


/// Batch-reads all UserDefaults keys into memory in one IPC call,
/// eliminating per-key round-trips to cfprefsd during init().
private struct DefaultsCache {
    let store: [String: Any]
    init() { self.store = UserDefaults.standard.dictionaryRepresentation() }
    func containsKey(_ key: String) -> Bool { store[key] != nil }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func double(forKey key: String) -> Double { store[key] as? Double ?? 0.0 }
    func string(forKey key: String) -> String? { store[key] as? String }
    func integer(forKey key: String) -> Int { store[key] as? Int ?? 0 }
    func object<T>(forKey key: String) -> T? { store[key] as? T }
}

@MainActor final class AppStore: ObservableObject {
    struct PageIndicatorOverride: Codable, Equatable {
        var offset: Double
        var topPadding: Double
    }

    enum AppearanceLayoutMode: String, CaseIterable, Codable, Identifiable {
        case fullscreen
        case compact

        var id: String { rawValue }
    }

    enum FolderLayoutMode: String, CaseIterable, Identifiable {
        case paged
        case vertical

        var id: String { rawValue }

        var localizationKey: LocalizationKey {
            switch self {
            case .paged: return .folderLayoutPaged
            case .vertical: return .folderLayoutVertical
            }
        }
    }

    struct ModeScopedAppearanceSettings: Codable, Equatable {
        var iconScale: Double
        var iconLabelFontSize: Double
        var folderDropZoneScale: Double
        var pageIndicatorOffset: Double
        var pageIndicatorTopPadding: Double
        var pageIndicatorPerDisplayEnabled: Bool
        var pageIndicatorOverrides: [String: PageIndicatorOverride]
    }

    struct DualModeAppearanceSettings: Codable, Equatable {
        var fullscreen: ModeScopedAppearanceSettings
        var compact: ModeScopedAppearanceSettings

        subscript(mode: AppearanceLayoutMode) -> ModeScopedAppearanceSettings {
            get {
                switch mode {
                case .fullscreen: return fullscreen
                case .compact: return compact
                }
            }
            set {
                switch mode {
                case .fullscreen: fullscreen = newValue
                case .compact: compact = newValue
                }
            }
        }
    }

    struct RGBAColor: Codable, Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        init(_ color: Color) {
            let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            self.red = Double(min(max(r, 0), 1))
            self.green = Double(min(max(g, 0), 1))
            self.blue = Double(min(max(b, 0), 1))
            self.alpha = Double(min(max(a, 0), 1))
        }

        var color: Color {
            Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
        }
    }

    enum BackgroundStyle: String, CaseIterable, Identifiable {
        case blur
        case glass

        var id: String { rawValue }

        var localizationKey: LocalizationKey {
            switch self {
            case .blur: return .backgroundStyleOptionBlur
            case .glass: return .backgroundStyleOptionGlass
            }
        }
    }

    enum DockDragSide: String, CaseIterable, Codable, Identifiable {
        case disabled
        case bottom
        case left
        case right

        var id: String { rawValue }

        var localizationKey: LocalizationKey {
            switch self {
            case .disabled: return .dockDragDisabled
            case .bottom: return .dockDragSideBottom
            case .left: return .dockDragSideLeft
            case .right: return .dockDragSideRight
            }
        }
    }

    enum HotCornerPosition: String, CaseIterable, Codable, Identifiable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var id: String { rawValue }

        var localizationKey: LocalizationKey {
            switch self {
            case .topLeft: return .hotCornerPositionTopLeft
            case .topRight: return .hotCornerPositionTopRight
            case .bottomLeft: return .hotCornerPositionBottomLeft
            case .bottomRight: return .hotCornerPositionBottomRight
            }
        }
    }

    // Experimental tap behavior used by the low-level gesture monitor.
    // If gesture support is removed later, this enum can be deleted together
    // with the gesture keys and @Published fields below.
    enum GestureTapAction: String, CaseIterable, Codable, Identifiable {
        case off
        case open
        case toggle

        var id: String { rawValue }

        var localizationKey: LocalizationKey {
            switch self {
            case .off: return .gestureTapActionOff
            case .open: return .gestureTapActionOpen
            case .toggle: return .gestureTapActionToggle
            }
        }
    }

    enum GestureFingerCount: Int, CaseIterable, Codable, Identifiable {
        case four = 4
        case five = 5

        var id: Int { rawValue }

        var localizationKey: LocalizationKey {
            switch self {
            case .four: return .gestureFingerCountFour
            case .five: return .gestureFingerCountFive
            }
        }

        var minimumOpenParticipatingFingerCount: Int {
            switch self {
            case .four: return 3
            case .five: return 4
            }
        }
    }

    enum DevelopmentBackgroundOverride: String, CaseIterable, Identifiable {
        case none
        case solidWhite
        case solidBlack

        var id: String { rawValue }

        var color: Color? {
            switch self {
            case .none:
                return nil
            case .solidWhite:
                return .white
            case .solidBlack:
                return .black
            }
        }
    }

    enum SidebarIconPreset: String, CaseIterable, Identifiable {
        case large
        case medium

        var id: String { rawValue }
        
        var localizationKeyTitle: LocalizationKey {
            switch self {
            case .large: return .sidebarIconSizeLarge
            case .medium: return .sidebarIconSizeMedium
            }
        }
    }

    enum IconLabelFontWeightOption: String, CaseIterable, Identifiable {
        case light
        case regular
        case medium
        case semibold
        case bold

        var id: String { rawValue }

        var fontWeight: Font.Weight {
            switch self {
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }

        var displayName: String {
            switch self {
            case .light: return "Light"
            case .regular: return "Regular"
            case .medium: return "Medium"
            case .semibold: return "Semibold"
            case .bold: return "Bold"
            }
        }
    }

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
    // Experimental gesture persistence keys.
    // Safe to remove together with LaunchNext/Gesture/ and gesture UI wiring
    // if the private multitouch feature is dropped later.
    static let gestureEnabledKey = "gestureEnabled"
    static let gestureCloseOnPinchOutKey = "gestureCloseOnPinchOut"
    static let gestureTapActionKey = "gestureTapAction"
    static let gestureFingerCountKey = "gestureFingerCount"
    static let gestureDeviceSelectionModeKey = "gestureDeviceSelectionMode"
    static let gestureSelectedDeviceIDsKey = "gestureSelectedDeviceIDs"
    static let searchDebounceMillisecondsRange: ClosedRange<Double> = 100...600
    private static let cliShimMarker = "# LaunchNext CLI shim"
    private static let cliPathSnippetHeader = "# >>> LaunchNext CLI >>>"
    private static let cliPathSnippetFooter = "# <<< LaunchNext CLI <<<"
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
    private static let gameControllerEnabledKey = "gameControllerEnabled"
    static let gameControllerMenuToggleKey = "gameControllerMenuToggleLaunchpad"
    private static let soundEffectsEnabledKey = "soundEffectsEnabled"
    private static let soundLaunchpadOpenKey = "soundLaunchpadOpenSound"
    private static let soundLaunchpadCloseKey = "soundLaunchpadCloseSound"
    private static let soundNavigationKey = "soundNavigationSound"
    private static let voiceFeedbackEnabledKey = "voiceFeedbackEnabled"
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
    static let onboardingVersionKey = "onboardingVersionShown"
    static let currentOnboardingVersion = 1
    static let dockDragTriggerDistanceRange: ClosedRange<Double> = 8...72
    static let defaultDockDragTriggerDistance: Double = 50
    static let hotCornerTriggerDelayRange: ClosedRange<Double> = 0...1.2
    static let hotCornerHitboxSizeRange: ClosedRange<Double> = 20...120
    static let defaultHotCornerTriggerDelay: Double = 0.25
    static let defaultHotCornerHitboxSize: Double = 50
    // private static let aiFeatureEnabledKey = "aiFeatureEnabled"
    // private static let aiOverlayHotKeyKey = "aiOverlayHotKeyConfiguration"

    private static func loadHiddenApps() -> Set<String> {
        if let array = UserDefaults.standard.array(forKey: hiddenAppsKey) as? [String] {
            return Set(array)
        }
        return []
    }

    private static func loadBackgroundStyle() -> BackgroundStyle {
        if let raw = UserDefaults.standard.string(forKey: backgroundStyleKey),
           let style = BackgroundStyle(rawValue: raw) {
            return style
        }
        return .glass
    }

    private static func loadFolderLayoutMode(from defaults: UserDefaults = .standard,
                                             isExistingInstall: Bool? = nil) -> FolderLayoutMode {
        if let raw = defaults.string(forKey: folderLayoutModeKey),
           let mode = FolderLayoutMode(rawValue: raw) {
            return mode
        }
        let existingInstall = isExistingInstall ?? (
            defaults.object(forKey: onboardingVersionKey) != nil ||
            defaults.object(forKey: useCAGridRendererKey) != nil ||
            defaults.object(forKey: "isFullscreenMode") != nil ||
            defaults.object(forKey: gridColumnsKey) != nil
        )
        return existingInstall ? .vertical : .paged
    }

    private static let defaultBackgroundMaskOpacity: Double = 0.1
    private static let defaultBackgroundMaskColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: defaultBackgroundMaskOpacity)

    private static func loadBackgroundMaskEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: backgroundMaskEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: backgroundMaskEnabledKey)
    }

    private static func loadBackgroundMaskColor(forKey key: String) -> RGBAColor {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return defaultBackgroundMaskColor
        }
        if let decoded = try? JSONDecoder().decode(RGBAColor.self, from: data) {
            return decoded
        }
        UserDefaults.standard.removeObject(forKey: key)
        return defaultBackgroundMaskColor
    }

    private static func persistBackgroundMaskColor(_ color: RGBAColor, forKey key: String) {
        if let data = try? JSONEncoder().encode(color) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static let minColumnsPerPage = 4
    private static let maxColumnsPerPage = 10
    private static let minRowsPerPage = 3
    private static let maxRowsPerPage = 8
    private static let minColumnSpacing: Double = 8
    private static let maxColumnSpacing: Double = 50
    private static let minRowSpacing: Double = 6
    private static let maxRowSpacing: Double = 40
    private static let defaultGridColumnsPerPage = 7
    private static let defaultGridRowsPerPage = 5
    private static let defaultColumnSpacing: Double = 20
    private static let defaultRowSpacing: Double = 14
    private static let defaultIconScale: Double = 0.95
    private static let defaultIconLabelFontSize: Double = 11.0
    static let defaultScrollSensitivity: Double = 0.2
    static var gridColumnRange: ClosedRange<Int> { minColumnsPerPage...maxColumnsPerPage }
    static var gridRowRange: ClosedRange<Int> { minRowsPerPage...maxRowsPerPage }
    static var columnSpacingRange: ClosedRange<Double> { minColumnSpacing...maxColumnSpacing }
    static var rowSpacingRange: ClosedRange<Double> { minRowSpacing...maxRowSpacing }
    static let hoverMagnificationRange: ClosedRange<Double> = 1.0...1.4
    private static let defaultHoverMagnificationScale: Double = 1.1
    static let activePressScaleRange: ClosedRange<Double> = 0.85...1.0
    private static let defaultActivePressScale: Double = 0.92
    static let folderPopoverWidthRange: ClosedRange<Double> = 0.6...0.95
    static let folderPopoverHeightRange: ClosedRange<Double> = 0.6...0.95
    private static let defaultFolderPopoverWidth: Double = 0.9
    private static let defaultFolderPopoverHeight: Double = 0.85
    static let folderDropZoneScaleRange: ClosedRange<Double> = 0.6...2.0
    static let defaultFolderDropZoneScale: Double = 1.6
    private static let defaultPageIndicatorOffset: Double = 27.0
    static let pageIndicatorTopPaddingRange: ClosedRange<Double> = 0...60
    static let defaultPageIndicatorTopPadding: Double = 12
    private static let defaultLaunchpadOpenSound = "Submarine"
    private static let defaultLaunchpadCloseSound = "Glass"
    private static let defaultNavigationSound = "Tink"
    private static func normalizedSoundName(_ raw: String?, defaultValue: String) -> String {
        guard let raw else { return defaultValue }
        if raw.isEmpty { return "" }
        return SoundManager.isValidSystemSoundName(raw) ? raw : defaultValue
    }

    struct HotKeyConfiguration: Equatable {
        let keyCode: UInt16
        let modifiersRawValue: NSEvent.ModifierFlags.RawValue

        init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiersRawValue = modifierFlags.normalizedShortcutFlags.rawValue
        }

        init?(dictionary: [String: Any]) {
            guard let rawKeyCode = dictionary["keyCode"] as? Int,
                  let rawModifiers = dictionary["modifiers"] as? Int else {
                return nil
            }
            self.keyCode = UInt16(rawKeyCode)
            self.modifiersRawValue = NSEvent.ModifierFlags.RawValue(rawModifiers)
        }

        var modifierFlags: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiersRawValue).normalizedShortcutFlags
        }

        var dictionaryRepresentation: [String: Any] {
            ["keyCode": Int(keyCode), "modifiers": Int(modifiersRawValue)]
        }

        var carbonModifierFlags: UInt32 { modifierFlags.carbonFlags }
        var keyCodeUInt32: UInt32 { UInt32(keyCode) }

        var displayString: String {
            let modifierSymbols = modifierFlags.displaySymbols.joined()
            let keyName = HotKeyConfiguration.keyDisplayName(for: keyCode)
            return modifierSymbols + keyName
        }

        private static func keyDisplayName(for keyCode: UInt16) -> String {
            if let special = Self.specialKeyNames[keyCode] {
                return special
            }

            guard let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let rawPtr = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else {
                return String(format: "Key %d", keyCode)
            }

            let data = unsafeBitCast(rawPtr, to: CFData.self) as Data
            return data.withUnsafeBytes { ptr -> String in
                guard let layoutPtr = ptr.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return String(format: "Key %d", keyCode)
                }
                var keysDown: UInt32 = 0
                var chars: [UniChar] = Array(repeating: 0, count: 4)
                var length: Int = 0
                let error = UCKeyTranslate(layoutPtr,
                                           keyCode,
                                           UInt16(kUCKeyActionDisplay),
                                           0,
                                           UInt32(LMGetKbdType()),
                                           UInt32(kUCKeyTranslateNoDeadKeysBit),
                                           &keysDown,
                                           chars.count,
                                           &length,
                                           &chars)
                if error == noErr, length > 0 {
                    return String(utf16CodeUnits: chars, count: length).uppercased()
                }
                return fallbackName(for: keyCode)
            }
        }

        private static func fallbackName(for keyCode: UInt16) -> String {
            Self.specialKeyNames[keyCode] ?? String(format: "Key %d", keyCode)
        }

        private static let specialKeyNames: [UInt16: String] = [
            36: "Return",
            48: "Tab",
            49: "Space",
            51: "Delete",
            53: "Esc",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
            123: "←",
            124: "→",
            125: "↓",
            126: "↑"
        ]
    }
    let settingsStore = SettingsStore()
    @Published var apps: [AppInfo] = []
    @Published var folders: [FolderInfo] = []
    @Published var items: [LaunchpadItem] = []
    @Published private(set) var missingPlaceholders: [String: MissingAppPlaceholder] = [:]
    @Published private(set) var hiddenAppPaths: Set<String> = AppStore.loadHiddenApps()

    private func persistHiddenApps(_ set: Set<String>) {
        let array = Array(set).sorted()
        UserDefaults.standard.set(array, forKey: Self.hiddenAppsKey)
    }

    private func updateHiddenAppPaths(_ changes: (inout Set<String>) -> Void) {
        var updated = hiddenAppPaths
        let original = updated
        changes(&updated)
        guard updated != original else { return }
        hiddenAppPaths = updated
        persistHiddenApps(updated)
    }

    @Published var launchpadBackgroundStyle: BackgroundStyle = AppStore.loadBackgroundStyle() {
        didSet {
            guard launchpadBackgroundStyle != oldValue else { return }
            UserDefaults.standard.set(launchpadBackgroundStyle.rawValue, forKey: Self.backgroundStyleKey)
        }
    }

    // Development-only override to capture flat screenshots quickly.
    @Published var developmentBackgroundOverride: DevelopmentBackgroundOverride = .none

    var developmentEnableCLICode: Bool {
        get { settingsStore.developmentEnableCLICode }
        set {
            let oldValue = settingsStore.developmentEnableCLICode
            settingsStore.developmentEnableCLICode = newValue
            if newValue && !oldValue {
                installCLICommandIfNeeded()
            } else if !newValue && oldValue {
                uninstallCLICommandIfNeeded()
            }
        }
    }

    @Published var backgroundMaskEnabled: Bool = AppStore.loadBackgroundMaskEnabled() {
        didSet {
            UserDefaults.standard.set(backgroundMaskEnabled, forKey: Self.backgroundMaskEnabledKey)
        }
    }

    @Published var backgroundMaskLightColor: RGBAColor = AppStore.loadBackgroundMaskColor(forKey: AppStore.backgroundMaskLightKey) {
        didSet {
            AppStore.persistBackgroundMaskColor(backgroundMaskLightColor, forKey: Self.backgroundMaskLightKey)
        }
    }

    @Published var backgroundMaskDarkColor: RGBAColor = AppStore.loadBackgroundMaskColor(forKey: AppStore.backgroundMaskDarkKey) {
        didSet {
            AppStore.persistBackgroundMaskColor(backgroundMaskDarkColor, forKey: Self.backgroundMaskDarkKey)
        }
    }

    @Published var sidebarIconPreset: SidebarIconPreset = {
        if let raw = UserDefaults.standard.string(forKey: AppStore.sidebarIconPresetKey),
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

    private static func writeDefaultAppearancePreferences(to defaults: UserDefaults) {
        defaults.set(SidebarIconPreset.large.rawValue, forKey: Self.sidebarIconPresetKey)
        defaults.set(AppearancePreference.system.rawValue, forKey: "appearancePreference")
        defaults.set(BackgroundStyle.glass.rawValue, forKey: Self.backgroundStyleKey)
        defaults.set(false, forKey: Self.backgroundMaskEnabledKey)
        Self.persistBackgroundMaskColor(Self.defaultBackgroundMaskColor, forKey: Self.backgroundMaskLightKey)
        Self.persistBackgroundMaskColor(Self.defaultBackgroundMaskColor, forKey: Self.backgroundMaskDarkKey)
        defaults.set(true, forKey: "isFullscreenMode")
        defaults.set(true, forKey: "showLabels")
        defaults.set(true, forKey: Self.folderPreviewHighResKey)
        defaults.set(FolderLayoutMode.paged.rawValue, forKey: Self.folderLayoutModeKey)
        defaults.set(false, forKey: "hideDock")
        defaults.set(false, forKey: Self.hideMenuBarKey)
        defaults.set(0.8, forKey: "scrollSensitivity")
        defaults.set(Self.defaultGridColumnsPerPage, forKey: Self.gridColumnsKey)
        defaults.set(Self.defaultGridRowsPerPage, forKey: Self.gridRowsKey)
        defaults.set(Self.defaultColumnSpacing, forKey: Self.columnSpacingKey)
        defaults.set(Self.defaultRowSpacing, forKey: Self.rowSpacingKey)
        defaults.set(true, forKey: "enableDropPrediction")
        defaults.set(true, forKey: "enableAnimations")
        defaults.set(false, forKey: Self.hoverMagnificationKey)
        defaults.set(Self.defaultHoverMagnificationScale, forKey: Self.hoverMagnificationScaleKey)
        defaults.set(false, forKey: Self.activePressEffectKey)
        defaults.set(false, forKey: Self.followScrollPagingKey)
        defaults.set(false, forKey: Self.reverseWheelPagingKey)
        defaults.set(Self.defaultActivePressScale, forKey: Self.activePressScaleKey)
        defaults.set(Self.defaultIconScale, forKey: "iconScale")
        defaults.set(Self.defaultIconLabelFontSize, forKey: "iconLabelFontSize")
        defaults.set(IconLabelFontWeightOption.medium.rawValue, forKey: Self.iconLabelFontWeightKey)
        defaults.set(Self.defaultAnimationDuration, forKey: "animationDuration")
        defaults.set(true, forKey: Self.windowOpenAnimationKey)
        defaults.set(true, forKey: "useLocalizedThirdPartyTitles")
        defaults.set(Self.defaultPageIndicatorOffset, forKey: "pageIndicatorOffset")
        defaults.set(Self.defaultPageIndicatorTopPadding, forKey: Self.pageIndicatorTopPaddingKey)
        defaults.set(false, forKey: Self.pageIndicatorPerDisplayEnabledKey)
        defaults.removeObject(forKey: Self.pageIndicatorPerDisplayOverridesKey)
        defaults.set(true, forKey: Self.rememberPageKey)
        defaults.removeObject(forKey: Self.rememberedPageIndexKey)
        defaults.set(Self.defaultFolderPopoverWidth, forKey: "folderPopoverWidthFactor")
        defaults.set(Self.defaultFolderPopoverHeight, forKey: "folderPopoverHeightFactor")
        defaults.set(false, forKey: "showFPSOverlay")
        if let data = try? JSONEncoder().encode(Self.defaultDualModeAppearanceSettings) {
            defaults.set(data, forKey: Self.dualModeAppearanceSettingsKey)
        }
    }

    private func reloadAppearancePreferencesFromDefaults() {
        let defaults = UserDefaults.standard

        if let raw = defaults.string(forKey: Self.sidebarIconPresetKey),
           let preset = SidebarIconPreset(rawValue: raw) {
            sidebarIconPreset = preset
        } else {
            sidebarIconPreset = .large
        }

        if let raw = defaults.string(forKey: "appearancePreference"),
           let preference = AppearancePreference(rawValue: raw) {
            appearancePreference = preference
        } else {
            appearancePreference = .system
        }

        launchpadBackgroundStyle = Self.loadBackgroundStyle()
        backgroundMaskEnabled = Self.loadBackgroundMaskEnabled()
        backgroundMaskLightColor = Self.loadBackgroundMaskColor(forKey: Self.backgroundMaskLightKey)
        backgroundMaskDarkColor = Self.loadBackgroundMaskColor(forKey: Self.backgroundMaskDarkKey)

        isFullscreenMode = defaults.object(forKey: "isFullscreenMode") as? Bool ?? true
        showLabels = defaults.object(forKey: "showLabels") as? Bool ?? true
        enableHighResFolderPreviews = defaults.object(forKey: Self.folderPreviewHighResKey) as? Bool ?? true
        folderLayoutMode = Self.loadFolderLayoutMode(from: defaults, isExistingInstall: nil)
        hideDock = defaults.object(forKey: "hideDock") as? Bool ?? false
        hideMenuBar = defaults.object(forKey: Self.hideMenuBarKey) as? Bool ?? false
        scrollSensitivity = defaults.object(forKey: "scrollSensitivity") as? Double ?? 0.8
        gridColumnsPerPage = Self.clampColumns(defaults.object(forKey: Self.gridColumnsKey) as? Int ?? Self.defaultGridColumnsPerPage)
        gridRowsPerPage = Self.clampRows(defaults.object(forKey: Self.gridRowsKey) as? Int ?? Self.defaultGridRowsPerPage)
        iconColumnSpacing = Self.clampColumnSpacing(defaults.object(forKey: Self.columnSpacingKey) as? Double ?? Self.defaultColumnSpacing)
        iconRowSpacing = Self.clampRowSpacing(defaults.object(forKey: Self.rowSpacingKey) as? Double ?? Self.defaultRowSpacing)
        enableDropPrediction = defaults.object(forKey: "enableDropPrediction") as? Bool ?? true
        enableAnimations = defaults.object(forKey: "enableAnimations") as? Bool ?? true
        enableHoverMagnification = defaults.object(forKey: Self.hoverMagnificationKey) as? Bool ?? false
        hoverMagnificationScale = defaults.object(forKey: Self.hoverMagnificationScaleKey) as? Double ?? Self.defaultHoverMagnificationScale
        enableActivePressEffect = defaults.object(forKey: Self.activePressEffectKey) as? Bool ?? false
        followScrollPagingEnabled = defaults.object(forKey: Self.followScrollPagingKey) as? Bool ?? false
        reverseWheelPagingDirection = defaults.object(forKey: Self.reverseWheelPagingKey) as? Bool ?? false
        activePressScale = defaults.object(forKey: Self.activePressScaleKey) as? Double ?? Self.defaultActivePressScale
        useLocalizedThirdPartyTitles = defaults.object(forKey: "useLocalizedThirdPartyTitles") as? Bool ?? true
        useCAGridRenderer = defaults.object(forKey: Self.useCAGridRendererKey) as? Bool ?? true
        iconLabelFontWeight = defaults.string(forKey: Self.iconLabelFontWeightKey).flatMap(IconLabelFontWeightOption.init(rawValue:)) ?? .medium
        showFPSOverlay = defaults.object(forKey: "showFPSOverlay") as? Bool ?? false
        enableWindowOpenAnimation = defaults.object(forKey: Self.windowOpenAnimationKey) as? Bool ?? true
        rememberLastPage = defaults.object(forKey: Self.rememberPageKey) as? Bool ?? true
        folderPopoverWidthFactor = Self.clampFolderWidth(defaults.object(forKey: "folderPopoverWidthFactor") as? Double ?? Self.defaultFolderPopoverWidth)
        folderPopoverHeightFactor = Self.clampFolderHeight(defaults.object(forKey: "folderPopoverHeightFactor") as? Double ?? Self.defaultFolderPopoverHeight)

        if let storedDualModeAppearance = Self.loadDualModeAppearanceSettings(from: defaults) {
            dualModeAppearanceSettings = storedDualModeAppearance
        } else {
            let legacy = Self.legacyAppearanceSettings(from: defaults)
            dualModeAppearanceSettings = DualModeAppearanceSettings(fullscreen: legacy, compact: legacy)
            persistDualModeAppearanceSettings()
        }
        syncActiveAppearanceProxies(from: currentAppearanceLayoutMode)
        persistLegacyAppearanceProxyValues()

        iconScale = dualModeAppearanceSettings[currentAppearanceLayoutMode].iconScale
        iconLabelFontSize = dualModeAppearanceSettings[currentAppearanceLayoutMode].iconLabelFontSize
        pageIndicatorOffset = dualModeAppearanceSettings[currentAppearanceLayoutMode].pageIndicatorOffset
        pageIndicatorTopPadding = dualModeAppearanceSettings[currentAppearanceLayoutMode].pageIndicatorTopPadding
        pageIndicatorPerDisplayEnabled = dualModeAppearanceSettings[currentAppearanceLayoutMode].pageIndicatorPerDisplayEnabled
        pageIndicatorOverrides = dualModeAppearanceSettings[currentAppearanceLayoutMode].pageIndicatorOverrides
        folderDropZoneScale = dualModeAppearanceSettings[currentAppearanceLayoutMode].folderDropZoneScale
        animationDuration = defaults.object(forKey: "animationDuration") as? Double ?? Self.defaultAnimationDuration
    }

    // Reload selected preferences from UserDefaults after an import
    func reloadPreferencesFromDefaults() {
        hiddenAppPaths = AppStore.loadHiddenApps()

        if let savedSources = UserDefaults.standard.array(forKey: AppStore.customAppSourcesKey) as? [String] {
            customAppSourcePaths = savedSources
        }

        uninstallToolAppPath = UserDefaults.standard.string(forKey: AppStore.uninstallToolAppPathKey) ?? ""
        reloadAppearancePreferencesFromDefaults()

        developmentEnableCLICode = UserDefaults.standard.object(forKey: Self.developmentEnableCLICodeKey) as? Bool ?? false
        fuzzySearchEnabled = UserDefaults.standard.object(forKey: Self.fuzzySearchEnabledKey) as? Bool ?? true
        searchDebounceMilliseconds = Self.clampedSearchDebounceMilliseconds(
            UserDefaults.standard.object(forKey: Self.searchDebounceMillisecondsKey) as? Double ?? 300
        )

        globalHotKey = Self.loadHotKeyConfiguration()
        gestureEnabled = UserDefaults.standard.object(forKey: Self.gestureEnabledKey) as? Bool ?? false
        gestureCloseOnPinchOut = UserDefaults.standard.object(forKey: Self.gestureCloseOnPinchOutKey) as? Bool ?? false
        gestureTapAction = GestureTapAction(rawValue: UserDefaults.standard.string(forKey: Self.gestureTapActionKey) ?? "") ?? .off
        gestureFingerCount = GestureFingerCount(rawValue: UserDefaults.standard.integer(forKey: Self.gestureFingerCountKey)) ?? .four
        gestureDeviceSelectionMode = GestureDeviceSelectionMode(rawValue: UserDefaults.standard.string(forKey: Self.gestureDeviceSelectionModeKey) ?? "") ?? .automatic
        gestureSelectedDeviceIDs = Array(Set(UserDefaults.standard.stringArray(forKey: Self.gestureSelectedDeviceIDsKey) ?? [])).sorted()

        // Apply hidden filtering immediately
        pruneHiddenAppsFromAppList()
        applyHiddenFilteringToOpenFolder()
        compactItemsWithinPages()
        removeEmptyPages()
        triggerFolderUpdate()
        triggerGridRefresh()
        refreshGestureDeviceInventory()
    }

    func refreshGestureDeviceInventory() {
        let provider = GestureTouchProvider()
        provider.refreshDevices()
        provider.configureDevices(mode: gestureDeviceSelectionMode, selectedDeviceIDs: gestureSelectedDeviceIDs)
        availableGestureDevices = provider.availableDevices.sorted {
            if $0.isBuiltIn != $1.isBuiltIn {
                return !$0.isBuiltIn && $1.isBuiltIn
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var gestureUnavailableSelectionCount: Int {
        let availableIDs = Set(availableGestureDevices.map(\.id))
        return gestureSelectedDeviceIDs.filter { !availableIDs.contains($0) }.count
    }

    @Published var isSetting = false
    @Published var isInitialLoading = true
    @Published var shouldShowOnboarding: Bool = false
    @Published var currentPage = 0 {
        didSet {
            if currentPage < 0 { currentPage = 0; return }
            if rememberLastPage {
                UserDefaults.standard.set(currentPage, forKey: Self.rememberedPageIndexKey)
            }
        }
    }
    @Published var searchText: String = "" {
        didSet {
            // When the user starts a new search, refresh the app list in the
            // background to ensure freshly installed/removed apps are reflected.
            if !searchText.isEmpty && oldValue.isEmpty {
                scheduleSoftRefreshOnSearch()
            }
        }
    }
    @Published private(set) var searchQuery: String = ""

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
            setupSearchPipeline()
        }
    }

    @Published var searchDebounceMs: Int = {
        let stored = UserDefaults.standard.integer(forKey: searchDebounceMsKey)
        return stored > 0 ? stored : 500
    }() {
        didSet {
            guard searchDebounceMs != oldValue else { return }
            UserDefaults.standard.set(searchDebounceMs, forKey: Self.searchDebounceMsKey)
            if searchStrategyType == .debounce { setupSearchPipeline() }
        }
    }

    @Published var searchThrottleMs: Int = {
        let stored = UserDefaults.standard.integer(forKey: searchThrottleMsKey)
        return stored > 0 ? stored : 50
    }() {
        didSet {
            guard searchThrottleMs != oldValue else { return }
            UserDefaults.standard.set(searchThrottleMs, forKey: Self.searchThrottleMsKey)
            if searchStrategyType == .throttle { setupSearchPipeline() }
        }
    }

    @Published var searchThrottleLatest: Bool = {
        if UserDefaults.standard.object(forKey: searchThrottleLatestKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: searchThrottleLatestKey)
    }() {
        didSet {
            guard searchThrottleLatest != oldValue else { return }
            UserDefaults.standard.set(searchThrottleLatest, forKey: Self.searchThrottleLatestKey)
            if searchStrategyType == .throttle { setupSearchPipeline() }
        }
    }

    static let searchDebounceMsRange: ClosedRange<Int> = 100...1000
    static let searchThrottleMsRange: ClosedRange<Int> = 16...500

    var currentSearchStrategy: SearchStrategy {
        switch searchStrategyType {
        case .debounce:
            return DebounceStrategy(milliseconds: searchDebounceMs)
        case .throttle:
            return ThrottleStrategy(milliseconds: searchThrottleMs, emitLatest: searchThrottleLatest)
        case .instant:
            return InstantStrategy()
        }
    }

    private var searchCancellable: AnyCancellable?

    func setupSearchPipeline() {
        searchCancellable?.cancel()

        searchCancellable = currentSearchStrategy
            .apply(to: $searchText.removeDuplicates())
            .sink { [weak self] value in
                self?.searchQuery = value
            }
    }

    var isStartOnLogin: Bool {
        get { settingsStore.isStartOnLogin }
        set { settingsStore.isStartOnLogin = newValue }
    }
    var canConfigureStartOnLogin: Bool {
        settingsStore.canConfigureStartOnLogin
    }
    var isFullscreenMode: Bool {
        get { settingsStore.isFullscreenMode }
        set {
            let oldValue = settingsStore.isFullscreenMode
            settingsStore.isFullscreenMode = newValue
            guard newValue != oldValue else { return }
            syncActiveAppearanceProxies(from: currentAppearanceLayoutMode)
            persistLegacyAppearanceProxyValues()
            DispatchQueue.main.async { [weak self] in
                if let appDelegate = AppDelegate.shared {
                    appDelegate.updateWindowMode(isFullscreen: self?.isFullscreenMode ?? false)
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.clearIconCachesForLayoutChange()
                self?.triggerGridRefresh()
            }
        }
    }
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

    private var appearanceRefreshWorkItem: DispatchWorkItem?
    private var lastAppearanceEventAt: TimeInterval = 0
    private var isApplyingScopedAppearanceState = false
    @Published private var dualModeAppearanceSettings: DualModeAppearanceSettings = AppStore.defaultDualModeAppearanceSettings

    static func screenIdentifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return screen.localizedName
    }

    private static func loadPageIndicatorOverrides() -> [String: PageIndicatorOverride] {
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

    private static func legacyAppearanceSettings(from defaults: UserDefaults) -> ModeScopedAppearanceSettings {
        let iconScale = defaults.object(forKey: "iconScale") as? Double ?? Self.defaultIconScale
        let iconLabelFontSize = defaults.object(forKey: "iconLabelFontSize") as? Double ?? Self.defaultIconLabelFontSize
        let dropZoneScale = clampFolderDropZoneScale(defaults.object(forKey: Self.folderDropZoneScaleKey) as? Double ?? Self.defaultFolderDropZoneScale)
        let indicatorOffset = defaults.object(forKey: "pageIndicatorOffset") as? Double ?? Self.defaultPageIndicatorOffset
        let indicatorTopPadding = clampPageIndicatorTopPadding(defaults.object(forKey: Self.pageIndicatorTopPaddingKey) as? Double ?? Self.defaultPageIndicatorTopPadding)
        let perDisplayEnabled = defaults.object(forKey: Self.pageIndicatorPerDisplayEnabledKey) as? Bool ?? false
        let overrides = (try? JSONDecoder().decode([String: PageIndicatorOverride].self,
                                                   from: defaults.data(forKey: Self.pageIndicatorPerDisplayOverridesKey) ?? Data())) ?? [:]
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

    private static var defaultScopedAppearanceSettings: ModeScopedAppearanceSettings {
        ModeScopedAppearanceSettings(
            iconScale: defaultIconScale,
            iconLabelFontSize: defaultIconLabelFontSize,
            folderDropZoneScale: defaultFolderDropZoneScale,
            pageIndicatorOffset: defaultPageIndicatorOffset,
            pageIndicatorTopPadding: defaultPageIndicatorTopPadding,
            pageIndicatorPerDisplayEnabled: false,
            pageIndicatorOverrides: [:]
        )
    }

    private static var defaultDualModeAppearanceSettings: DualModeAppearanceSettings {
        let scoped = defaultScopedAppearanceSettings
        return DualModeAppearanceSettings(fullscreen: scoped, compact: scoped)
    }

    private var currentAppearanceLayoutMode: AppearanceLayoutMode {
        isFullscreenMode ? .fullscreen : .compact
    }

    private func updateScopedAppearanceSettings(for mode: AppearanceLayoutMode,
                                                _ update: (inout ModeScopedAppearanceSettings) -> Void) {
        var settings = dualModeAppearanceSettings
        var scoped = settings[mode]
        update(&scoped)
        settings[mode] = Self.normalizedAppearanceSettings(scoped)
        dualModeAppearanceSettings = settings
        persistDualModeAppearanceSettings()
    }

    private func syncActiveAppearanceProxies(from mode: AppearanceLayoutMode) {
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

    private func persistLegacyAppearanceProxyValues() {
        let defaults = UserDefaults.standard
        defaults.set(iconScale, forKey: "iconScale")
        defaults.set(iconLabelFontSize, forKey: "iconLabelFontSize")
        defaults.set(folderDropZoneScale, forKey: Self.folderDropZoneScaleKey)
        defaults.set(pageIndicatorOffset, forKey: "pageIndicatorOffset")
        defaults.set(pageIndicatorTopPadding, forKey: Self.pageIndicatorTopPaddingKey)
        defaults.set(pageIndicatorPerDisplayEnabled, forKey: Self.pageIndicatorPerDisplayEnabledKey)
        persistPageIndicatorOverrides(pageIndicatorOverrides)
    }

    func scopedIconScale(for mode: AppearanceLayoutMode) -> Double {
        dualModeAppearanceSettings[mode].iconScale
    }

    func setScopedIconScale(_ value: Double, for mode: AppearanceLayoutMode) {
        if mode == currentAppearanceLayoutMode {
            iconScale = value
        } else {
            updateScopedAppearanceSettings(for: mode) { $0.iconScale = value }
        }
    }

    func scopedIconLabelFontSize(for mode: AppearanceLayoutMode) -> Double {
        dualModeAppearanceSettings[mode].iconLabelFontSize
    }

    func setScopedIconLabelFontSize(_ value: Double, for mode: AppearanceLayoutMode) {
        if mode == currentAppearanceLayoutMode {
            iconLabelFontSize = value
        } else {
            updateScopedAppearanceSettings(for: mode) { $0.iconLabelFontSize = value }
        }
    }

    func scopedFolderDropZoneScale(for mode: AppearanceLayoutMode) -> Double {
        dualModeAppearanceSettings[mode].folderDropZoneScale
    }

    func setScopedFolderDropZoneScale(_ value: Double, for mode: AppearanceLayoutMode) {
        let clamped = Self.clampFolderDropZoneScale(value)
        if mode == currentAppearanceLayoutMode {
            folderDropZoneScale = clamped
        } else {
            updateScopedAppearanceSettings(for: mode) { $0.folderDropZoneScale = clamped }
        }
    }

    func scopedPageIndicatorOffset(for mode: AppearanceLayoutMode) -> Double {
        dualModeAppearanceSettings[mode].pageIndicatorOffset
    }

    func setScopedPageIndicatorOffset(_ value: Double, for mode: AppearanceLayoutMode) {
        if mode == currentAppearanceLayoutMode {
            pageIndicatorOffset = value
        } else {
            updateScopedAppearanceSettings(for: mode) { $0.pageIndicatorOffset = value }
        }
    }

    func scopedPageIndicatorTopPadding(for mode: AppearanceLayoutMode) -> Double {
        dualModeAppearanceSettings[mode].pageIndicatorTopPadding
    }

    func setScopedPageIndicatorTopPadding(_ value: Double, for mode: AppearanceLayoutMode) {
        let clamped = Self.clampPageIndicatorTopPadding(value)
        if mode == currentAppearanceLayoutMode {
            pageIndicatorTopPadding = clamped
        } else {
            updateScopedAppearanceSettings(for: mode) { $0.pageIndicatorTopPadding = clamped }
        }
    }

    func scopedPageIndicatorPerDisplayEnabled(for mode: AppearanceLayoutMode) -> Bool {
        dualModeAppearanceSettings[mode].pageIndicatorPerDisplayEnabled
    }

    func setScopedPageIndicatorPerDisplayEnabled(_ enabled: Bool, for mode: AppearanceLayoutMode) {
        if mode == currentAppearanceLayoutMode {
            pageIndicatorPerDisplayEnabled = enabled
        } else {
            updateScopedAppearanceSettings(for: mode) { $0.pageIndicatorPerDisplayEnabled = enabled }
        }
    }

    func scopedPageIndicatorOverrides(for mode: AppearanceLayoutMode) -> [String: PageIndicatorOverride] {
        dualModeAppearanceSettings[mode].pageIndicatorOverrides
    }

    func scopedPageIndicatorOverride(for screenID: String, mode: AppearanceLayoutMode) -> PageIndicatorOverride? {
        dualModeAppearanceSettings[mode].pageIndicatorOverrides[screenID]
    }

    func setScopedPageIndicatorOverride(_ override: PageIndicatorOverride?, for screenID: String, mode: AppearanceLayoutMode) {
        if mode == currentAppearanceLayoutMode {
            setPageIndicatorOverride(override, for: screenID)
            return
        }
        updateScopedAppearanceSettings(for: mode) { settings in
            if let override {
                settings.pageIndicatorOverrides[screenID] = override
            } else {
                settings.pageIndicatorOverrides.removeValue(forKey: screenID)
            }
        }
    }

    func applyIndicatorDefaults(to screenID: String, mode: AppearanceLayoutMode) {
        let settings = dualModeAppearanceSettings[mode]
        let override = PageIndicatorOverride(offset: settings.pageIndicatorOffset,
                                             topPadding: settings.pageIndicatorTopPadding)
        setScopedPageIndicatorOverride(override, for: screenID, mode: mode)
    }

    // Icon title display
    @Published var showLabels: Bool = {
        if UserDefaults.standard.object(forKey: "showLabels") == nil { return true }
        return UserDefaults.standard.bool(forKey: "showLabels")
    }() {
        didSet { UserDefaults.standard.set(showLabels, forKey: "showLabels") }
    }

    @Published var enableHighResFolderPreviews: Bool = {
        if UserDefaults.standard.object(forKey: AppStore.folderPreviewHighResKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: AppStore.folderPreviewHighResKey)
    }() {
        didSet {
            guard enableHighResFolderPreviews != oldValue else { return }
            UserDefaults.standard.set(enableHighResFolderPreviews, forKey: AppStore.folderPreviewHighResKey)
            clearIconCachesForLayoutChange()
            triggerFolderUpdate()
            triggerGridRefresh()
        }
    }

    @Published var folderLayoutMode: FolderLayoutMode = AppStore.loadFolderLayoutMode() {
        didSet {
            guard folderLayoutMode != oldValue else { return }
            UserDefaults.standard.set(folderLayoutMode.rawValue, forKey: Self.folderLayoutModeKey)
            DispatchQueue.main.async { [weak self] in
                self?.triggerFolderUpdate()
            }
        }
    }

    var hideDock: Bool {
        get { settingsStore.hideDock }
        set { settingsStore.hideDock = newValue }
    }

    var hideMenuBar: Bool {
        get { settingsStore.hideMenuBar }
        set { settingsStore.hideMenuBar = newValue }
    }
    
    @Published var scrollSensitivity: Double {
        didSet {
            UserDefaults.standard.set(scrollSensitivity, forKey: "scrollSensitivity")
        }
    }

    var gridColumnsPerPage: Int {
        get { settingsStore.gridColumnsPerPage }
        set {
            let oldValue = settingsStore.gridColumnsPerPage
            settingsStore.gridColumnsPerPage = newValue
            guard settingsStore.gridColumnsPerPage != oldValue else { return }
            handleGridConfigurationChange()
        }
    }

    var gridRowsPerPage: Int {
        get { settingsStore.gridRowsPerPage }
        set {
            let oldValue = settingsStore.gridRowsPerPage
            settingsStore.gridRowsPerPage = newValue
            guard settingsStore.gridRowsPerPage != oldValue else { return }
            handleGridConfigurationChange()
        }
    }

    @Published var iconColumnSpacing: Double {
        didSet {
            let clamped = Self.clampColumnSpacing(iconColumnSpacing)
            if iconColumnSpacing != clamped {
                iconColumnSpacing = clamped
                return
            }
            guard iconColumnSpacing != oldValue else { return }
            UserDefaults.standard.set(iconColumnSpacing, forKey: Self.columnSpacingKey)
            triggerGridRefresh()
        }
    }

    @Published var iconRowSpacing: Double {
        didSet {
            let clamped = Self.clampRowSpacing(iconRowSpacing)
            if iconRowSpacing != clamped {
                iconRowSpacing = clamped
                return
            }
            guard iconRowSpacing != oldValue else { return }
            UserDefaults.standard.set(iconRowSpacing, forKey: Self.rowSpacingKey)
            triggerGridRefresh()
        }
    }

    @Published var enableDropPrediction: Bool = {
        if UserDefaults.standard.object(forKey: "enableDropPrediction") == nil { return true }
        return UserDefaults.standard.bool(forKey: "enableDropPrediction")
    }() {
        didSet { UserDefaults.standard.set(enableDropPrediction, forKey: "enableDropPrediction") }
    }

    @Published var folderDropZoneScale: Double = AppStore.defaultFolderDropZoneScale {
        didSet {
            let clamped = Self.clampFolderDropZoneScale(folderDropZoneScale)
            if folderDropZoneScale != clamped {
                folderDropZoneScale = clamped
                return
            }
            UserDefaults.standard.set(folderDropZoneScale, forKey: Self.folderDropZoneScaleKey)
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.folderDropZoneScale = folderDropZoneScale }
        }
    }

    @Published var pageIndicatorTopPadding: Double = AppStore.defaultPageIndicatorTopPadding {
        didSet {
            let clamped = Self.clampPageIndicatorTopPadding(pageIndicatorTopPadding)
            if pageIndicatorTopPadding != clamped {
                pageIndicatorTopPadding = clamped
                return
            }
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
        if UserDefaults.standard.object(forKey: AppStore.hoverMagnificationKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: AppStore.hoverMagnificationKey)
    }() {
        didSet { UserDefaults.standard.set(enableHoverMagnification, forKey: Self.hoverMagnificationKey) }
    }

    @Published var hoverMagnificationScale: Double = {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: AppStore.hoverMagnificationScaleKey) as? Double
        let initial = stored ?? AppStore.defaultHoverMagnificationScale
        let clamped = min(max(initial, AppStore.hoverMagnificationRange.lowerBound), AppStore.hoverMagnificationRange.upperBound)
        if stored == nil || stored != clamped {
            defaults.set(clamped, forKey: AppStore.hoverMagnificationScaleKey)
        }
        return clamped
    }() {
        didSet {
            let clamped = min(max(hoverMagnificationScale, Self.hoverMagnificationRange.lowerBound), Self.hoverMagnificationRange.upperBound)
            if hoverMagnificationScale != clamped {
                hoverMagnificationScale = clamped
                return
            }
            UserDefaults.standard.set(hoverMagnificationScale, forKey: Self.hoverMagnificationScaleKey)
        }
    }

    @Published var enableActivePressEffect: Bool = {
        if UserDefaults.standard.object(forKey: AppStore.activePressEffectKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: AppStore.activePressEffectKey)
    }() {
        didSet { UserDefaults.standard.set(enableActivePressEffect, forKey: Self.activePressEffectKey) }
    }

    @Published var followScrollPagingEnabled: Bool = {
        if UserDefaults.standard.object(forKey: AppStore.followScrollPagingKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: AppStore.followScrollPagingKey)
    }() {
        didSet { UserDefaults.standard.set(followScrollPagingEnabled, forKey: Self.followScrollPagingKey) }
    }

    @Published var reverseWheelPagingDirection: Bool = {
        if UserDefaults.standard.object(forKey: AppStore.reverseWheelPagingKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: AppStore.reverseWheelPagingKey)
    }() {
        didSet { UserDefaults.standard.set(reverseWheelPagingDirection, forKey: Self.reverseWheelPagingKey) }
    }

    @Published var useCAGridRenderer: Bool = {
        if UserDefaults.standard.object(forKey: AppStore.useCAGridRendererKey) == nil { return true }
        let enabled = UserDefaults.standard.bool(forKey: AppStore.useCAGridRendererKey)
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

    var layoutStrategy: LayoutStrategy {
        switch layoutMode {
        case .paged: return PagedLayoutStrategy()
        case .vertical: return VerticalLayoutStrategy()
        }
    }

    // MARK: - Dock & Menu Bar

    @Published var showInDock: Bool = {
        UserDefaults.standard.bool(forKey: showInDockKey)
    }() {
        didSet {
            guard showInDock != oldValue else { return }
            UserDefaults.standard.set(showInDock, forKey: Self.showInDockKey)
            updateActivationPolicy()
        }
    }

    func updateActivationPolicy() {
        if showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    var showInMenuBar: Bool {
        get { settingsStore.showInMenuBar }
        set { settingsStore.showInMenuBar = newValue }
    }

    @Published var activePressScale: Double = {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: AppStore.activePressScaleKey) as? Double
        let initial = stored ?? AppStore.defaultActivePressScale
        let clamped = min(max(initial, AppStore.activePressScaleRange.lowerBound), AppStore.activePressScaleRange.upperBound)
        if stored == nil || stored != clamped {
            defaults.set(clamped, forKey: AppStore.activePressScaleKey)
        }
        return clamped
    }() {
        didSet {
            let clamped = min(max(activePressScale, Self.activePressScaleRange.lowerBound), Self.activePressScaleRange.upperBound)
            if activePressScale != clamped {
                activePressScale = clamped
                return
            }
            UserDefaults.standard.set(activePressScale, forKey: Self.activePressScaleKey)
        }
    }

    @Published var iconLabelFontSize: Double = {
        let stored = UserDefaults.standard.double(forKey: "iconLabelFontSize")
        return stored == 0 ? 11.0 : stored
    }() {
        didSet {
            UserDefaults.standard.set(iconLabelFontSize, forKey: "iconLabelFontSize")
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.iconLabelFontSize = iconLabelFontSize }
            triggerGridRefresh()
        }
    }

    @Published var iconLabelFontWeight: IconLabelFontWeightOption = {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: AppStore.iconLabelFontWeightKey),
           let value = IconLabelFontWeightOption(rawValue: raw) {
            return value
        }
        return .medium
    }() {
        didSet {
            guard iconLabelFontWeight != oldValue else { return }
            UserDefaults.standard.set(iconLabelFontWeight.rawValue, forKey: AppStore.iconLabelFontWeightKey)
            triggerGridRefresh()
        }
    }

    var iconLabelFontWeightValue: Font.Weight {
        iconLabelFontWeight.fontWeight
    }

    @Published var showQuickRefreshButton: Bool = {
        if UserDefaults.standard.object(forKey: AppStore.showQuickRefreshButtonKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: AppStore.showQuickRefreshButtonKey)
    }() {
        didSet {
            guard showQuickRefreshButton != oldValue else { return }
            UserDefaults.standard.set(showQuickRefreshButton, forKey: AppStore.showQuickRefreshButtonKey)
        }
    }

    @Published var uninstallToolAppPath: String = {
        UserDefaults.standard.string(forKey: AppStore.uninstallToolAppPathKey) ?? ""
    }() {
        didSet {
            guard uninstallToolAppPath != oldValue else { return }
            let trimmed = uninstallToolAppPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: AppStore.uninstallToolAppPathKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: AppStore.uninstallToolAppPathKey)
            }
        }
    }

    var isLayoutLocked: Bool {
        get { settingsStore.isLayoutLocked }
        set {
            let oldValue = settingsStore.isLayoutLocked
            settingsStore.isLayoutLocked = newValue
            guard newValue != oldValue else { return }
            triggerGridRefresh()
        }
    }

    // Update check related properties
    @Published var updateState: UpdateState = .idle

    @Published var autoCheckForUpdates: Bool = {
        if UserDefaults.standard.object(forKey: "autoCheckForUpdates") == nil { return true }
        return UserDefaults.standard.bool(forKey: "autoCheckForUpdates")
    }() {
        didSet {
            UserDefaults.standard.set(autoCheckForUpdates, forKey: "autoCheckForUpdates")
            if autoCheckForUpdates {
                updateChecker.scheduleAutomaticUpdateCheck()
            } else {
                updateChecker.cancelAutoCheck()
            }
        }
    }

    private(set) lazy var updateChecker = UpdateChecker(
        delegate: self,
        localized: { [weak self] key in self?.localized(key) ?? "" }
    )

    @Published var animationDuration: Double = {
        let stored = UserDefaults.standard.double(forKey: "animationDuration")
        return stored == 0 ? 0.3 : stored
    }() {
        didSet { UserDefaults.standard.set(animationDuration, forKey: "animationDuration") }
    }

    var enableWindowOpenAnimation: Bool {
        get { settingsStore.enableWindowOpenAnimation }
        set { settingsStore.enableWindowOpenAnimation = newValue }
    }

    @Published var useLocalizedThirdPartyTitles: Bool = {
        if UserDefaults.standard.object(forKey: "useLocalizedThirdPartyTitles") == nil { return true }
        return UserDefaults.standard.bool(forKey: "useLocalizedThirdPartyTitles")
    }() {
        didSet {
            guard oldValue != useLocalizedThirdPartyTitles else { return }
            UserDefaults.standard.set(useLocalizedThirdPartyTitles, forKey: "useLocalizedThirdPartyTitles")
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
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

    var gameControllerEnabled: Bool {
        get { settingsStore.gameControllerEnabled }
        set { settingsStore.gameControllerEnabled = newValue }
    }

    var gameControllerMenuTogglesLaunchpad: Bool {
        get { settingsStore.gameControllerMenuTogglesLaunchpad }
        set { settingsStore.gameControllerMenuTogglesLaunchpad = newValue }
    }

    @Published var soundEffectsEnabled: Bool = {
        if UserDefaults.standard.object(forKey: AppStore.soundEffectsEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: AppStore.soundEffectsEnabledKey)
    }() {
        didSet {
            guard oldValue != soundEffectsEnabled else { return }
            UserDefaults.standard.set(soundEffectsEnabled, forKey: AppStore.soundEffectsEnabledKey)
        }
    }

    @Published var soundLaunchpadOpenSound: String = {
        let stored = UserDefaults.standard.string(forKey: AppStore.soundLaunchpadOpenKey)
        return AppStore.normalizedSoundName(stored, defaultValue: AppStore.defaultLaunchpadOpenSound)
    }() {
        didSet {
            UserDefaults.standard.set(soundLaunchpadOpenSound, forKey: AppStore.soundLaunchpadOpenKey)
        }
    }

    @Published var soundLaunchpadCloseSound: String = {
        let stored = UserDefaults.standard.string(forKey: AppStore.soundLaunchpadCloseKey)
        return AppStore.normalizedSoundName(stored, defaultValue: AppStore.defaultLaunchpadCloseSound)
    }() {
        didSet {
            UserDefaults.standard.set(soundLaunchpadCloseSound, forKey: AppStore.soundLaunchpadCloseKey)
        }
    }

    @Published var soundNavigationSound: String = {
        let stored = UserDefaults.standard.string(forKey: AppStore.soundNavigationKey)
        return AppStore.normalizedSoundName(stored, defaultValue: AppStore.defaultNavigationSound)
    }() {
        didSet {
            UserDefaults.standard.set(soundNavigationSound, forKey: AppStore.soundNavigationKey)
        }
    }

    @Published var voiceFeedbackEnabled: Bool = {
        if UserDefaults.standard.object(forKey: AppStore.voiceFeedbackEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: AppStore.voiceFeedbackEnabledKey)
    }() {
        didSet {
            guard oldValue != voiceFeedbackEnabled else { return }
            UserDefaults.standard.set(voiceFeedbackEnabled, forKey: AppStore.voiceFeedbackEnabledKey)
            if !voiceFeedbackEnabled {
                VoiceManager.shared.stop()
            }
        }
    }

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
        if UserDefaults.standard.object(forKey: AppStore.pageIndicatorPerDisplayEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: AppStore.pageIndicatorPerDisplayEnabledKey)
    }() {
        didSet {
            UserDefaults.standard.set(pageIndicatorPerDisplayEnabled, forKey: AppStore.pageIndicatorPerDisplayEnabledKey)
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.pageIndicatorPerDisplayEnabled = pageIndicatorPerDisplayEnabled }
        }
    }

    @Published private(set) var pageIndicatorOverrides: [String: PageIndicatorOverride] = AppStore.loadPageIndicatorOverrides() {
        didSet {
            persistPageIndicatorOverrides(pageIndicatorOverrides)
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.pageIndicatorOverrides = pageIndicatorOverrides }
        }
    }

    var rememberLastPage: Bool {
        get { settingsStore.rememberLastPage }
        set {
            settingsStore.rememberLastPage = newValue
            if newValue {
                UserDefaults.standard.set(currentPage, forKey: AppStore.rememberedPageIndexKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppStore.rememberedPageIndexKey)
            }
        }
    }

    @Published var folderPopoverWidthFactor: Double = {
        let stored = UserDefaults.standard.double(forKey: "folderPopoverWidthFactor")
        if stored == 0 { return defaultFolderPopoverWidth }
        return clampFolderWidth(stored)
    }() {
        didSet {
            let clamped = AppStore.clampFolderWidth(folderPopoverWidthFactor)
            if folderPopoverWidthFactor != clamped {
                folderPopoverWidthFactor = clamped
                return
            }
            UserDefaults.standard.set(folderPopoverWidthFactor, forKey: "folderPopoverWidthFactor")
        }
    }

    @Published var folderPopoverHeightFactor: Double = {
        let stored = UserDefaults.standard.double(forKey: "folderPopoverHeightFactor")
        if stored == 0 { return defaultFolderPopoverHeight }
        return clampFolderHeight(stored)
    }() {
        didSet {
            let clamped = AppStore.clampFolderHeight(folderPopoverHeightFactor)
            if folderPopoverHeightFactor != clamped {
                folderPopoverHeightFactor = clamped
                return
            }
            UserDefaults.standard.set(folderPopoverHeightFactor, forKey: "folderPopoverHeightFactor")
        }
    }

    var appearancePreference: AppearancePreference {
        get { settingsStore.appearancePreference }
        set { settingsStore.appearancePreference = newValue }
    }

    @Published var globalHotKey: HotKeyConfiguration? = AppStore.loadHotKeyConfiguration() {
        didSet {
            persistHotKeyConfiguration()
            AppDelegate.shared?.updateGlobalHotKey(configuration: globalHotKey)
        }
    }

    @Published var dockDragEnabled: Bool = {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: AppStore.dockDragEnabledKey) as? Bool {
            return stored
        }
        let legacySideRaw = defaults.string(forKey: AppStore.dockDragSideKey)
        let enabled = legacySideRaw != DockDragSide.disabled.rawValue
        defaults.set(enabled, forKey: AppStore.dockDragEnabledKey)
        return enabled
    }() {
        didSet {
            guard dockDragEnabled != oldValue else { return }
            UserDefaults.standard.set(dockDragEnabled, forKey: Self.dockDragEnabledKey)
        }
    }

    @Published var dockDragSide: DockDragSide = {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: AppStore.dockDragSideKey),
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
        let stored = defaults.object(forKey: AppStore.dockDragTriggerDistanceKey) as? Double
        let initial = stored ?? AppStore.defaultDockDragTriggerDistance
        let clamped = AppStore.clampDockDragTriggerDistance(initial)
        if stored == nil || stored != clamped {
            defaults.set(clamped, forKey: AppStore.dockDragTriggerDistanceKey)
        }
        return clamped
    }() {
        didSet {
            let clamped = Self.clampDockDragTriggerDistance(dockDragTriggerDistance)
            if dockDragTriggerDistance != clamped {
                dockDragTriggerDistance = clamped
                return
            }
            UserDefaults.standard.set(dockDragTriggerDistance, forKey: Self.dockDragTriggerDistanceKey)
        }
    }

    var hotCornerEnabled: Bool {
        get { settingsStore.hotCornerEnabled }
        set { settingsStore.hotCornerEnabled = newValue }
    }

    var hotCornerPosition: HotCornerPosition {
        get { settingsStore.hotCornerPosition }
        set { settingsStore.hotCornerPosition = newValue }
    }

    var hotCornerTriggerDelay: Double {
        get { settingsStore.hotCornerTriggerDelay }
        set { settingsStore.hotCornerTriggerDelay = newValue }
    }

    var hotCornerHitboxSize: Double {
        get { settingsStore.hotCornerHitboxSize }
        set { settingsStore.hotCornerHitboxSize = newValue }
    }

    var hotCornerToggleWhenOpen: Bool {
        get { settingsStore.hotCornerToggleWhenOpen }
        set { settingsStore.hotCornerToggleWhenOpen = newValue }
    }

    // Experimental gesture settings consumed by LaunchpadApp gesture wiring.
    // Remove these fields together with the gesture monitor/configuration flow
    // if low-level multitouch support is no longer needed.
    var gestureEnabled: Bool {
        get { settingsStore.gestureEnabled }
        set { settingsStore.gestureEnabled = newValue }
    }

    var gestureCloseOnPinchOut: Bool {
        get { settingsStore.gestureCloseOnPinchOut }
        set { settingsStore.gestureCloseOnPinchOut = newValue }
    }

    var gestureTapAction: GestureTapAction {
        get { settingsStore.gestureTapAction }
        set { settingsStore.gestureTapAction = newValue }
    }

    var gestureFingerCount: GestureFingerCount {
        get { settingsStore.gestureFingerCount }
        set { settingsStore.gestureFingerCount = newValue }
    }

    var gestureDeviceSelectionMode: GestureDeviceSelectionMode {
        get { settingsStore.gestureDeviceSelectionMode }
        set { settingsStore.gestureDeviceSelectionMode = newValue }
    }

    var gestureSelectedDeviceIDs: [String] {
        get { settingsStore.gestureSelectedDeviceIDs }
        set { settingsStore.gestureSelectedDeviceIDs = newValue }
    }

    @Published private(set) var availableGestureDevices: [GestureInputDevice] = []

    // @Published var isAIEnabled: Bool = {
    //     if UserDefaults.standard.object(forKey: AppStore.aiFeatureEnabledKey) == nil { return false }
    //     return UserDefaults.standard.bool(forKey: AppStore.aiFeatureEnabledKey)
    // }() {
    //     didSet {
    //         guard isAIEnabled != oldValue else { return }
    //         UserDefaults.standard.set(isAIEnabled, forKey: AppStore.aiFeatureEnabledKey)
    //         // if !isAIEnabled {
    //         //     AIOverlayController.shared.hide()
    //         // }
    //         // AppDelegate.shared?.updateAIOverlayHotKey(configuration: isAIEnabled ? aiOverlayHotKey : nil)
    //     }
    // }
    //
    // @Published var aiOverlayHotKey: HotKeyConfiguration? = AppStore.loadAIOverlayHotKeyConfiguration() {
    //     didSet {
    //         persistAIOverlayHotKeyConfiguration()
    //         // if isAIEnabled {
    //         //     AppDelegate.shared?.updateAIOverlayHotKey(configuration: aiOverlayHotKey)
    //         // }
    //     }
    // }

    @Published private(set) var currentAppIcon: NSImage {
        didSet { applyCurrentAppIcon() }
    }

    @Published private(set) var hasCustomAppIcon: Bool

    @Published var preferredLanguage: AppLanguage = {
        if let raw = UserDefaults.standard.string(forKey: "preferredLanguage"),
           let lang = AppLanguage(rawValue: raw) {
            return lang
        }
        return .system
    }() {
        didSet { UserDefaults.standard.set(preferredLanguage.rawValue, forKey: "preferredLanguage") }
    }

    @Published private(set) var customTitles: [String: String] = AppStore.loadCustomTitles() {
        didSet { persistCustomTitles() }
    }

    // Cache manager
    private let cacheManager = AppCacheManager.shared
    
    // Folder related state
    @Published var openFolder: FolderInfo? = nil
    @Published var isDragCreatingFolder = false
    @Published var folderCreationTarget: AppInfo? = nil
    @Published var openFolderActivatedByKeyboard: Bool = false
    @Published var isFolderNameEditing: Bool = false
    @Published var folderRenameRequestID: String? = nil
    @Published var handoffDraggingApp: AppInfo? = nil
    @Published var handoffDragScreenLocation: CGPoint? = nil
    
    // Triggers
    @Published var folderUpdateTrigger: UUID = UUID()
    @Published var gridRefreshTrigger: UUID = UUID()
    @Published var iconCacheRefreshTrigger: UUID = UUID()
    private var folderUpdateScheduled = false
    private var gridRefreshScheduled = false
    
    var modelContext: ModelContext?

    // MARK: - Auto rescan (FSEvents)

    // MARK: - Volume observers
    private var hasPerformedInitialScan: Bool = false
    private var cancellables: Set<AnyCancellable> = []
    var hasAppliedOrderFromStore: Bool = false
    private(set) lazy var persistence = OrderPersistence(delegate: self)
    private(set) lazy var scanner = AppScanner(delegate: self)
    
    // Background refresh queue and throttle
    private let refreshQueue = DispatchQueue(label: "app.store.refresh", qos: .userInitiated)
    private var gridRefreshWorkItem: DispatchWorkItem?
    private var iconScaleWorkItem: DispatchWorkItem?
    private var rescanWorkItem: DispatchWorkItem?
    private var customTitleRefreshWorkItem: DispatchWorkItem?
    private var searchQueryWorkItem: DispatchWorkItem?
    private let fsEventsQueue = DispatchQueue(label: "app.store.fsevents")
    private let customIconFileURL: URL
    private let defaultAppIcon: NSImage

    private var volumeObservers: [NSObjectProtocol] = []
    
    // Computed properties
    private var itemsPerPage: Int { gridColumnsPerPage * gridRowsPerPage }

    var builtinAppSourcePaths: [String] { systemApplicationSearchPaths }

    private var applicationSearchPaths: [String] {
        var seen = Set<String>()
        var result: [String] = []
        let candidates = systemApplicationSearchPaths + customAppSourcePaths
        let fileManager = FileManager.default

        for raw in candidates {
            guard let standardized = normalizeApplicationPath(raw) else { continue }
            guard !standardized.isEmpty, !seen.contains(standardized) else { continue }

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory), isDirectory.boolValue {
                seen.insert(standardized)
                result.append(standardized)
            }
        }

        return result
    }

    private func normalizeApplicationPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded).standardized.path
    }

    func standardizedFilePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    func removableSourcePath(forAppPath path: String) -> String? {
        let standardizedApp = standardizedFilePath(path)
        for source in customAppSourcePaths {
            guard let normalizedSource = normalizeApplicationPath(source) else { continue }
            if standardizedApp == normalizedSource { return normalizedSource }
            if standardizedApp.hasPrefix(normalizedSource.hasSuffix("/") ? normalizedSource : normalizedSource + "/") {
                return normalizedSource
            }
        }
        return nil
    }

    private func placeholderDisplayName(for path: String, preferred: String?) -> String {
        let normalizedPath = standardizedFilePath(path)
        let legacyMatch = missingPlaceholders.first { standardizedFilePath($0.key) == normalizedPath }?.value.displayName
        let candidates: [String?] = [preferred,
                                     missingPlaceholders[normalizedPath]?.displayName,
                                     legacyMatch,
                                     URL(fileURLWithPath: normalizedPath).deletingPathExtension().lastPathComponent]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return normalizedPath
    }

    func updateMissingPlaceholder(path: String,
                                           displayName: String? = nil,
                                           removableSource: String? = nil) -> MissingAppPlaceholder? {
        let normalizedPath = standardizedFilePath(path)
        let resolvedDisplayName = placeholderDisplayName(for: normalizedPath, preferred: displayName)
        let resolvedSource = removableSource ?? removableSourcePath(forAppPath: normalizedPath) ?? missingPlaceholders[normalizedPath]?.removableSource
        guard shouldTrackMissingPlaceholder(at: normalizedPath, removableSource: resolvedSource) else {
            missingPlaceholders.removeValue(forKey: normalizedPath)
            return nil
        }

        let placeholder = MissingAppPlaceholder(bundlePath: normalizedPath,
                                               displayName: resolvedDisplayName,
                                               removableSource: resolvedSource)
        missingPlaceholders[normalizedPath] = placeholder
        if missingPlaceholders.count > 1 {
            missingPlaceholders = missingPlaceholders.filter { key, _ in
                let normalizedKey = standardizedFilePath(key)
                return normalizedKey != normalizedPath || key == normalizedPath
            }
            missingPlaceholders[normalizedPath] = placeholder
        }
        return placeholder
    }

    private func shouldTrackMissingPlaceholder(at normalizedPath: String,
                                               removableSource: String?) -> Bool {
        guard let removableSource else { return false }

        let normalizedSource = normalizeApplicationPath(removableSource) ?? standardizedFilePath(removableSource)
        let customSources = customAppSourcePaths.map { normalizeApplicationPath($0) ?? standardizedFilePath($0) }
        return customSources.contains(normalizedSource)
    }

    func clearMissingPlaceholder(for path: String) {
        missingPlaceholders.removeValue(forKey: standardizedFilePath(path))
    }

    private func currentMissingAppItem(for placeholder: MissingAppPlaceholder) -> LaunchpadItem? {
        let normalizedPath = standardizedFilePath(placeholder.bundlePath)
        guard let currentPlaceholder = missingPlaceholders[normalizedPath] else { return nil }
        return .missingApp(currentPlaceholder)
    }

    func placeholderAppInfo(forMissingPath path: String, preferredName: String? = nil) -> AppInfo? {
        guard let placeholder = updateMissingPlaceholder(path: path, displayName: preferredName) else {
            return nil
        }
        let placeholderURL = URL(fileURLWithPath: placeholder.bundlePath)
        let info = AppInfo(name: placeholder.displayName,
                           icon: placeholder.icon,
                           url: placeholderURL)
        return info
    }

    func refreshMissingPlaceholders() {
        guard !items.isEmpty else {
            if !missingPlaceholders.isEmpty {
                missingPlaceholders.removeAll()
            }
            return
        }

        var updatedItems = items
        var mutated = false
        let fileManager = FileManager.default

        for index in updatedItems.indices {
            switch updatedItems[index] {
            case .app(let app):
                let path = standardizedFilePath(app.url.path)
                if fileManager.fileExists(atPath: path) {
                    clearMissingPlaceholder(for: path)
                } else {
                    if let placeholder = updateMissingPlaceholder(path: path, displayName: app.name) {
                        updatedItems[index] = .missingApp(placeholder)
                    } else {
                        updatedItems[index] = .empty(UUID().uuidString)
                    }
                    mutated = true
                }
            case .missingApp(let placeholder):
                let path = standardizedFilePath(placeholder.bundlePath)
                if fileManager.fileExists(atPath: path) {
                    if let existing = apps.first(where: { standardizedFilePath($0.url.path) == path }) {
                        clearMissingPlaceholder(for: path)
                        updatedItems[index] = .app(existing)
                        mutated = true
                    } else {
                        let url = URL(fileURLWithPath: path)
                        let info = appInfo(from: url, preferredName: placeholder.displayName)
                        clearMissingPlaceholder(for: path)
                        if !apps.contains(where: { standardizedFilePath($0.url.path) == path }) {
                            apps.append(info)
                            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                            pruneHiddenAppsFromAppList()
                        }
                        updatedItems[index] = .app(info)
                        mutated = true
                    }
                } else {
                    if updateMissingPlaceholder(path: path,
                                                displayName: placeholder.displayName,
                                                removableSource: placeholder.removableSource) == nil {
                        updatedItems[index] = .empty(UUID().uuidString)
                        mutated = true
                    }
                }
            default:
                break
            }
        }

        if mutated {
            updatedItems = filteredItemsRemovingHidden(from: updatedItems)
            items = updatedItems
        }

        let placeholderPathsInUse = Set(updatedItems.compactMap { item -> String? in
            if case let .missingApp(placeholder) = item { return standardizedFilePath(placeholder.bundlePath) }
            return nil
        })
        if placeholderPathsInUse.count != missingPlaceholders.count {
            missingPlaceholders = missingPlaceholders.filter { key, _ in
                placeholderPathsInUse.contains(standardizedFilePath(key))
            }
        }
    }

    private func purgeMissingPlaceholders(forRemovedSources rawSources: [String]) {
        guard !rawSources.isEmpty else { return }
        let normalizedSources = rawSources.compactMap { path in
            normalizeApplicationPath(path) ?? standardizedFilePath(path)
        }
        guard !normalizedSources.isEmpty else { return }
        let sourceSet = Set(normalizedSources)

        var removalSet = Set<String>()
        var removalRawPaths = Set<String>()
        for (key, placeholder) in missingPlaceholders {
            let normalizedKey = standardizedFilePath(key)

            var matchesRemovedSource = false
            if let source = placeholder.removableSource {
                let normalizedSource = normalizeApplicationPath(source) ?? standardizedFilePath(source)
                if sourceSet.contains(normalizedSource) {
                    matchesRemovedSource = true
                }
            }

            if !matchesRemovedSource {
                matchesRemovedSource = sourceSet.contains { source in
                    if normalizedKey == source { return true }
                    let prefix = source.hasSuffix("/") ? source : source + "/"
                    return normalizedKey.hasPrefix(prefix)
                }
            }

            if matchesRemovedSource {
                removalSet.insert(normalizedKey)
                removalRawPaths.insert(key)
            }
        }

        // Actively add all existing app paths from removed sources (regardless of missing status)
        if !sourceSet.isEmpty {
            let prefixes: [String] = sourceSet.map { $0.hasSuffix("/") ? $0 : $0 + "/" }

            func considerRemoval(path raw: String) {
                let normalized = standardizedFilePath(raw)
                if sourceSet.contains(normalized) || prefixes.contains(where: { normalized.hasPrefix($0) }) {
                    removalSet.insert(normalized)
                    removalRawPaths.insert(raw)
                }
            }

            for app in apps {
                considerRemoval(path: app.url.path)
            }

            for folder in folders {
                for app in folder.apps {
                    considerRemoval(path: app.url.path)
                }
            }

            for item in items {
                switch item {
                case .app(let app):
                    considerRemoval(path: app.url.path)
                case .missingApp(let placeholder):
                    considerRemoval(path: placeholder.bundlePath)
                case .folder(let folder):
                    for app in folder.apps {
                        considerRemoval(path: app.url.path)
                    }
                case .empty:
                    break
                }
            }
        }

        guard !removalSet.isEmpty else { return }

        var updatedItems = items
        var mutatedItems = false
        for index in updatedItems.indices {
            switch updatedItems[index] {
            case .missingApp(let placeholder):
                if removalSet.contains(standardizedFilePath(placeholder.bundlePath)) {
                    updatedItems[index] = .empty(UUID().uuidString)
                    mutatedItems = true
                }
            case .app(let app):
                if removalSet.contains(standardizedFilePath(app.url.path)) {
                    updatedItems[index] = .empty(UUID().uuidString)
                    mutatedItems = true
                }
            case .folder(var folder):
                let originalCount = folder.apps.count
                folder.apps.removeAll { removalSet.contains(standardizedFilePath($0.url.path)) }
                if folder.apps.count != originalCount {
                    mutatedItems = true
                    if folder.apps.isEmpty {
                        updatedItems[index] = .empty(UUID().uuidString)
                    } else {
                        updatedItems[index] = .folder(folder)
                    }
                }
            case .empty:
                break
            }
        }
        if mutatedItems {
            updatedItems = filteredItemsRemovingHidden(from: updatedItems)
            items = updatedItems
        }

        if !removalSet.isEmpty {
            apps.removeAll { removalSet.contains(standardizedFilePath($0.url.path)) }
            for idx in folders.indices {
                folders[idx].apps.removeAll { removalSet.contains(standardizedFilePath($0.url.path)) }
            }
            pruneHiddenAppsFromAppList()
            if !customTitles.isEmpty {
                customTitles = customTitles.filter { key, _ in
                    !removalSet.contains(standardizedFilePath(key))
                }
            }
            if !hiddenAppPaths.isEmpty {
                updateHiddenAppPaths { hidden in
                    for path in removalSet { hidden.remove(path) }
                    for raw in removalRawPaths { hidden.remove(raw) }
                }
            }
        }

        missingPlaceholders = missingPlaceholders.filter { key, _ in
            !removalSet.contains(standardizedFilePath(key))
        }

        triggerFolderUpdate()
        triggerGridRefresh()
        compactItemsWithinPages()
        refreshMissingPlaceholders()
        persistence.saveAllOrder()
    }

    private func sanitizedCustomPaths(from rawPaths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for raw in rawPaths {
            guard let normalized = normalizeApplicationPath(raw) else { continue }
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }

        return result
    }
    


    private let systemApplicationSearchPaths: [String] = [
        "/Applications",
        "\(NSHomeDirectory())/Applications",
        "/System/Applications",
        "/System/Cryptexes/App/System/Applications"
    ]

    static let customAppSourcesKey = "customApplicationSourcePaths"

    @Published var customAppSourcePaths: [String] = {
        guard let saved = UserDefaults.standard.array(forKey: AppStore.customAppSourcesKey) as? [String] else { return [] }
        return saved
    }() {
        didSet {
            guard customAppSourcePaths != oldValue else { return }
            UserDefaults.standard.set(customAppSourcePaths, forKey: AppStore.customAppSourcesKey)
            restartAutoRescan()
            scanApplicationsWithOrderPreservation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.removeEmptyPages()
            }
        }
    }

    init() {
        // Forward settingsStore change notifications so views observing
        // `appStore.{setting}` (computed forwarding wrappers) receive updates.
        settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        let cache = DefaultsCache()

        if !cache.containsKey("isFullscreenMode") {
            self.isFullscreenMode = true // New user default Classic (Fullscreen)
            UserDefaults.standard.set(true, forKey: "isFullscreenMode")
        } else {
            self.isFullscreenMode = cache.bool(forKey: "isFullscreenMode")
        }
        if !cache.containsKey(PerformanceMode.userDefaultsKey) {
            PerformanceMode.persist(.lean)
        }
        let defaults = UserDefaults.standard // kept for write-backs only

        let shouldRememberPage = !cache.containsKey(Self.rememberPageKey) ? true : cache.bool(forKey: Self.rememberPageKey)
        let savedPageIndex = cache.object(forKey: Self.rememberedPageIndexKey) as Int?

        let initialScrollSensitivity: Double
        if !cache.containsKey("scrollSensitivity") {
            initialScrollSensitivity = 0.8
            defaults.set(initialScrollSensitivity, forKey: "scrollSensitivity")
        } else {
            let storedSensitivity = cache.double(forKey: "scrollSensitivity")
            initialScrollSensitivity = storedSensitivity == 0 ? Self.defaultScrollSensitivity : storedSensitivity
        }
        scrollSensitivity = initialScrollSensitivity

        let storedColumns = cache.object(forKey: Self.gridColumnsKey) ?? 7
        let clampedColumns = Self.clampColumns(storedColumns)
        self.gridColumnsPerPage = clampedColumns

        defaults.set(clampedColumns, forKey: Self.gridColumnsKey)

        let storedRows = cache.object(forKey: Self.gridRowsKey) ?? 5
        let clampedRows = Self.clampRows(storedRows)
        self.gridRowsPerPage = clampedRows
        defaults.set(clampedRows, forKey: Self.gridRowsKey)

        let storedColumnSpacing = cache.object(forKey: Self.columnSpacingKey) ?? 20.0
        let clampedColumnSpacing = Self.clampColumnSpacing(storedColumnSpacing)
        self.iconColumnSpacing = clampedColumnSpacing
        defaults.set(clampedColumnSpacing, forKey: Self.columnSpacingKey)

        let storedRowSpacing = cache.object(forKey: Self.rowSpacingKey) ?? 14.0
        let clampedRowSpacing = Self.clampRowSpacing(storedRowSpacing)
        self.iconRowSpacing = clampedRowSpacing
        defaults.set(clampedRowSpacing, forKey: Self.rowSpacingKey)
        let storedDropZoneScale = cache.object(forKey: Self.folderDropZoneScaleKey) ?? Self.defaultFolderDropZoneScale
        let clampedDropZoneScale = Self.clampFolderDropZoneScale(storedDropZoneScale)
        self.folderDropZoneScale = clampedDropZoneScale
        defaults.set(clampedDropZoneScale, forKey: Self.folderDropZoneScaleKey)
        if !cache.containsKey(Self.pageIndicatorTopPaddingKey) {
            defaults.set(Self.defaultPageIndicatorTopPadding, forKey: Self.pageIndicatorTopPaddingKey)
        }
        if !cache.containsKey(Self.pageIndicatorPerDisplayEnabledKey) {
            defaults.set(false, forKey: Self.pageIndicatorPerDisplayEnabledKey)
        }
        let storedTopPadding = cache.object(forKey: Self.pageIndicatorTopPaddingKey) ?? Self.defaultPageIndicatorTopPadding
        let clampedTopPadding = Self.clampPageIndicatorTopPadding(storedTopPadding)
        self.pageIndicatorTopPadding = clampedTopPadding
        defaults.set(clampedTopPadding, forKey: Self.pageIndicatorTopPaddingKey)
        // Read icon scale default
        if let v = cache.object(forKey: "iconScale") as Double? {
            self.iconScale = v
        }
        if !cache.containsKey("enableDropPrediction") {
            defaults.set(true, forKey: "enableDropPrediction")
        }
        if !cache.containsKey("useLocalizedThirdPartyTitles") {
            defaults.set(true, forKey: "useLocalizedThirdPartyTitles")
        }
        if !cache.containsKey("enableAnimations") {
            defaults.set(true, forKey: "enableAnimations")
        }
        if !cache.containsKey(AppStore.followScrollPagingKey) {
            defaults.set(false, forKey: AppStore.followScrollPagingKey)
        }
        if !cache.containsKey(AppStore.reverseWheelPagingKey) {
            defaults.set(false, forKey: AppStore.reverseWheelPagingKey)
        }
        if !cache.containsKey(Self.dockDragEnabledKey) {
            let legacySideRaw = cache.string(forKey: Self.dockDragSideKey)
            defaults.set(legacySideRaw != DockDragSide.disabled.rawValue, forKey: Self.dockDragEnabledKey)
        }
        if !cache.containsKey(Self.dockDragSideKey) {
            defaults.set(DockDragSide.bottom.rawValue, forKey: Self.dockDragSideKey)
        }
        let storedDockDragDistance = cache.object(forKey: Self.dockDragTriggerDistanceKey) ?? Self.defaultDockDragTriggerDistance
        let clampedDockDragDistance = Self.clampDockDragTriggerDistance(storedDockDragDistance)
        defaults.set(clampedDockDragDistance, forKey: Self.dockDragTriggerDistanceKey)
        if !cache.containsKey(Self.hotCornerEnabledKey) {
            defaults.set(false, forKey: Self.hotCornerEnabledKey)
        }
        if !cache.containsKey(Self.hotCornerPositionKey) {
            defaults.set(HotCornerPosition.topLeft.rawValue, forKey: Self.hotCornerPositionKey)
        }
        let storedHotCornerDelay = cache.object(forKey: Self.hotCornerTriggerDelayKey) ?? Self.defaultHotCornerTriggerDelay
        let clampedHotCornerDelay = Self.clampHotCornerTriggerDelay(storedHotCornerDelay)
        defaults.set(clampedHotCornerDelay, forKey: Self.hotCornerTriggerDelayKey)
        let storedHotCornerHitboxSize = cache.object(forKey: Self.hotCornerHitboxSizeKey) ?? Self.defaultHotCornerHitboxSize
        let clampedHotCornerHitboxSize = Self.clampHotCornerHitboxSize(storedHotCornerHitboxSize)
        defaults.set(clampedHotCornerHitboxSize, forKey: Self.hotCornerHitboxSizeKey)
        if !cache.containsKey(Self.hotCornerToggleWhenOpenKey) {
            defaults.set(false, forKey: Self.hotCornerToggleWhenOpenKey)
        }
        if !cache.containsKey(Self.gestureEnabledKey) {
            defaults.set(false, forKey: Self.gestureEnabledKey)
        }
        if !cache.containsKey(Self.gestureCloseOnPinchOutKey) {
            defaults.set(false, forKey: Self.gestureCloseOnPinchOutKey)
        }
        // Keep a one-time migration path from the older tap booleans so users
        // do not lose settings if gesture support remains enabled.
        if !cache.containsKey(Self.gestureTapActionKey) {
            let legacyEnabled = cache.object(forKey: "gestureTapEnabled") ?? false
            let legacyToggle = cache.object(forKey: "gestureTapToggleWhenOpen") ?? false
            let migratedAction: GestureTapAction = legacyEnabled ? (legacyToggle ? .toggle : .open) : .off
            defaults.set(migratedAction.rawValue, forKey: Self.gestureTapActionKey)
        }
        if !cache.containsKey(Self.gameControllerMenuToggleKey) {
            defaults.set(true, forKey: Self.gameControllerMenuToggleKey)
        }
        if !cache.containsKey(Self.useCAGridRendererKey) {
            defaults.set(true, forKey: Self.useCAGridRendererKey)
        }
        if !cache.containsKey(Self.developmentEnableCLICodeKey) {
            defaults.set(false, forKey: Self.developmentEnableCLICodeKey)
        }
        if !cache.containsKey(Self.backgroundMaskEnabledKey) {
            defaults.set(false, forKey: Self.backgroundMaskEnabledKey)
        }
        if !cache.containsKey(Self.backgroundMaskLightKey) {
            Self.persistBackgroundMaskColor(Self.defaultBackgroundMaskColor, forKey: Self.backgroundMaskLightKey)
        }
        if !cache.containsKey(Self.backgroundMaskDarkKey) {
            Self.persistBackgroundMaskColor(Self.defaultBackgroundMaskColor, forKey: Self.backgroundMaskDarkKey)
        }
        if !cache.containsKey("iconLabelFontSize") {
            defaults.set(11.0, forKey: "iconLabelFontSize")
        }
        if !cache.containsKey(AppStore.iconLabelFontWeightKey) {
            defaults.set(IconLabelFontWeightOption.medium.rawValue, forKey: AppStore.iconLabelFontWeightKey)
        }
        if !cache.containsKey("animationDuration") {
            defaults.set(0.3, forKey: "animationDuration")
        }
        if !cache.containsKey(Self.windowOpenAnimationKey) {
            defaults.set(true, forKey: Self.windowOpenAnimationKey)
        }
        if !cache.containsKey("showFPSOverlay") {
            defaults.set(false, forKey: "showFPSOverlay")
        }
        if !cache.containsKey("pageIndicatorOffset") {
            defaults.set(27.0, forKey: "pageIndicatorOffset")
        }

        if let storedDualModeAppearance = Self.loadDualModeAppearanceSettings(from: defaults) {
            self.dualModeAppearanceSettings = storedDualModeAppearance
        } else {
            let legacy = Self.legacyAppearanceSettings(from: defaults)
            let migrated = DualModeAppearanceSettings(fullscreen: legacy, compact: legacy)
            self.dualModeAppearanceSettings = migrated
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: Self.dualModeAppearanceSettingsKey)
            }
        }

        let storedDuration = cache.double(forKey: "animationDuration")
        self.animationDuration = storedDuration == 0 ? 0.3 : storedDuration
        self.enableWindowOpenAnimation = cache.object(forKey: Self.windowOpenAnimationKey) ?? true
        self.dockDragEnabled = cache.object(forKey: Self.dockDragEnabledKey) ?? true
        let storedDockDragSide = DockDragSide(rawValue: cache.string(forKey: Self.dockDragSideKey) ?? "")
        self.dockDragSide = storedDockDragSide == .disabled ? .bottom : (storedDockDragSide ?? .bottom)
        self.dockDragTriggerDistance = clampedDockDragDistance
        self.hotCornerEnabled = cache.object(forKey: Self.hotCornerEnabledKey) ?? false
        self.hotCornerPosition = HotCornerPosition(rawValue: cache.string(forKey: Self.hotCornerPositionKey) ?? "") ?? .topLeft
        self.hotCornerTriggerDelay = clampedHotCornerDelay
        self.hotCornerHitboxSize = clampedHotCornerHitboxSize
        self.hotCornerToggleWhenOpen = cache.object(forKey: Self.hotCornerToggleWhenOpenKey) ?? false
        self.gestureEnabled = cache.object(forKey: Self.gestureEnabledKey) ?? false
        self.gestureCloseOnPinchOut = cache.object(forKey: Self.gestureCloseOnPinchOutKey) ?? false
        self.gestureTapAction = GestureTapAction(rawValue: cache.string(forKey: Self.gestureTapActionKey) ?? "") ?? .off
        self.enableAnimations = cache.object(forKey: "enableAnimations") ?? true
        self.customIconFileURL = AppStore.customIconFileURL

        let fallbackIcon = (NSApplication.shared.applicationIconImage?.copy() as? NSImage) ?? NSImage(size: NSSize(width: 512, height: 512))
        self.defaultAppIcon = fallbackIcon
        if let storedIcon = AppStore.loadStoredAppIcon(from: customIconFileURL) {
            self.hasCustomAppIcon = true
            self.currentAppIcon = storedIcon
        } else {
            self.hasCustomAppIcon = false
            self.currentAppIcon = fallbackIcon
        }
        applyCurrentAppIcon()
        syncActiveAppearanceProxies(from: currentAppearanceLayoutMode)
        persistLegacyAppearanceProxyValues()

        let sanitizedSources = sanitizedCustomPaths(from: customAppSourcePaths)
        if sanitizedSources != customAppSourcePaths {
            customAppSourcePaths = sanitizedSources
        }
        refreshGestureDeviceInventory()

        setupVolumeObservers()

        setupSearchPipeline()

        searchQuery = searchText

        if developmentEnableCLICode {
            installCLICommandIfNeeded()
        } else {
            uninstallCLICommandIfNeeded()
        }

        updateChecker.scheduleAutomaticUpdateCheck()

        self.rememberLastPage = shouldRememberPage
        if shouldRememberPage, let savedPageIndex {
            self.currentPage = max(0, savedPageIndex)
        }

        syncLoginItemStatusFromSystem()
    }

    private static func clampedSearchDebounceMilliseconds(_ value: Double) -> Double {
        min(max(value, searchDebounceMillisecondsRange.lowerBound), searchDebounceMillisecondsRange.upperBound)
    }

    private func scheduleSearchQueryUpdate(with value: String) {
        searchQueryWorkItem?.cancel()

        let delayMilliseconds = Self.clampedSearchDebounceMilliseconds(searchDebounceMilliseconds)
        guard delayMilliseconds > 0 else {
            searchQuery = value
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.searchQuery = value
        }
        searchQueryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delayMilliseconds / 1000, execute: work)
    }

    func syncLoginItemStatusFromSystem() {
        settingsStore.syncFromSystem()
    }

    private func installCLICommandIfNeeded() {
        guard let executablePath = Bundle.main.executableURL?.path else { return }
        for path in cliCommandTargets() {
            if installCLIShim(at: path, executablePath: executablePath) {
                let directory = (path as NSString).deletingLastPathComponent
                ensureZProfilePathIncludes(directory: directory)
                return
            }
        }
    }

    @discardableResult
    func removeInstalledCLICommand() -> Bool {
        uninstallCLICommandIfNeeded()
    }

    private func cliCommandTargets() -> [String] {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/launchnext",
            "/usr/local/bin/launchnext",
            "\(homePath)/.local/bin/launchnext",
            "\(homePath)/bin/launchnext"
        ]
    }

    private func installCLIShim(at shimPath: String, executablePath: String) -> Bool {
        let fileManager = FileManager.default
        let directoryPath = (shimPath as NSString).deletingLastPathComponent

        if !fileManager.fileExists(atPath: directoryPath) {
            do {
                try fileManager.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }

        guard fileManager.isWritableFile(atPath: directoryPath) else {
            return false
        }

        if fileManager.fileExists(atPath: shimPath) {
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: shimPath),
               destination == executablePath {
                return true
            }
            if let existing = try? String(contentsOfFile: shimPath, encoding: .utf8),
               existing.contains(Self.cliShimMarker) {
                // Managed shim, safe to replace.
            } else {
                return false
            }
        }

        let escapedExecutable = executablePath.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        #!/bin/zsh
        \(Self.cliShimMarker)
        
        if [[ "$1" == "--help" || "$1" == "-h" || "$1" == "help" ]]; then
          cat <<'EOF'
        LaunchNext CLI
        
        Usage:
          launchnext --help
          launchnext --gui
          launchnext --tui
          launchnext --cli help
          launchnext --cli list
          launchnext --cli snapshot
          launchnext --cli search --query "safari"
          launchnext --cli move --source normal-app --path "/Applications/Thaw.app" --to folder-append --target-folder-id <folder-id>
        
        Notes:
          - Keep `--cli --help` and `--cli help` for full in-app CLI help.
          - LaunchNext GUI must be running for list/snapshot/search/move.
          - "Command line interface" must be ON in General settings.
        EOF
          exit 0
        fi
        
        exec "\(escapedExecutable)" "$@"
        """

        do {
            try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: shimPath)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func uninstallCLICommandIfNeeded() -> Bool {
        var removedAny = false
        for path in cliCommandTargets() {
            let directory = (path as NSString).deletingLastPathComponent
            if uninstallCLIShim(at: path) { removedAny = true }
            if removeCLIPathSnippetFromZProfile(directory: directory) { removedAny = true }
        }
        return removedAny
    }

    private func uninstallCLIShim(at shimPath: String) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: shimPath) else { return false }

        let isManagedShim: Bool = {
            if let existing = try? String(contentsOfFile: shimPath, encoding: .utf8),
               existing.contains(Self.cliShimMarker) {
                return true
            }
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: shimPath),
               destination.contains("/LaunchNext.app/Contents/MacOS/LaunchNext") {
                return true
            }
            return false
        }()

        guard isManagedShim else { return false }
        do {
            try fileManager.removeItem(atPath: shimPath)
            return true
        } catch {
            return false
        }
    }

    private func ensureZProfilePathIncludes(directory: String) {
        guard directory.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path) else { return }

        let zprofileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zprofile")
        let snippet = cliPathSnippet(directory: directory)

        if let existing = try? String(contentsOf: zprofileURL, encoding: .utf8) {
            if existing.contains(":\(directory):") || existing.contains("export PATH=\"\(directory):$PATH\"") {
                return
            }
            try? (existing + snippet).write(to: zprofileURL, atomically: true, encoding: .utf8)
        } else {
            try? snippet.write(to: zprofileURL, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    private func removeCLIPathSnippetFromZProfile(directory: String) -> Bool {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        guard directory.hasPrefix(homePath) else { return false }

        let zprofileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zprofile")
        guard let existing = try? String(contentsOf: zprofileURL, encoding: .utf8) else { return false }

        var updated = existing
        updated = updated.replacingOccurrences(of: cliPathSnippet(directory: directory), with: "")
        updated = updated.replacingOccurrences(of: legacyCLIPathSnippet(directory: directory), with: "")

        guard updated != existing else { return false }
        do {
            try updated.write(to: zprofileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func cliPathSnippet(directory: String) -> String {
        """
        
        \(Self.cliPathSnippetHeader)
        if [[ ":$PATH:" != *":\(directory):"* ]]; then
          export PATH="\(directory):$PATH"
        fi
        \(Self.cliPathSnippetFooter)
        """
    }

    private func legacyCLIPathSnippet(directory: String) -> String {
        """
        
        # LaunchNext CLI
        if [[ ":$PATH:" != *":\(directory):"* ]]; then
          export PATH="\(directory):$PATH"
        fi
        """
    }

    private static func loadCustomTitles() -> [String: String] {
        guard let raw = UserDefaults.standard.dictionary(forKey: AppStore.customTitlesKey) else {
            return [:]
        }

        var result: [String: String] = [:]
        for (key, value) in raw {
            guard let stringValue = value as? String else { continue }
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result[key] = trimmed
            }
        }
        return result
    }

    private static func loadHotKeyConfiguration() -> HotKeyConfiguration? {
        guard let dict = UserDefaults.standard.dictionary(forKey: globalHotKeyKey) else { return nil }
        return HotKeyConfiguration(dictionary: dict)
    }

    // private static func loadAIOverlayHotKeyConfiguration() -> HotKeyConfiguration? {
    //     guard let dict = UserDefaults.standard.dictionary(forKey: aiOverlayHotKeyKey) else { return nil }
    //     return HotKeyConfiguration(dictionary: dict)
    // }

    private func persistCustomTitles() {
        let sanitized = customTitles.reduce(into: [String: String]()) { partialResult, entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                partialResult[entry.key] = trimmed
            }
        }

        if sanitized.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppStore.customTitlesKey)
        } else {
            UserDefaults.standard.set(sanitized, forKey: AppStore.customTitlesKey)
        }
    }

    // private func persistAIOverlayHotKeyConfiguration() {
    //     let defaults = UserDefaults.standard
    //     if let config = aiOverlayHotKey {
    //         defaults.set(config.dictionaryRepresentation, forKey: Self.aiOverlayHotKeyKey)
    //     } else {
    //         defaults.removeObject(forKey: Self.aiOverlayHotKeyKey)
    //     }
    // }

    private func persistHotKeyConfiguration() {
        let defaults = UserDefaults.standard
        if let config = globalHotKey {
            defaults.set(config.dictionaryRepresentation, forKey: Self.globalHotKeyKey)
        } else {
            defaults.removeObject(forKey: Self.globalHotKeyKey)
        }
    }


    // Icon scale (relative to cell): default 0.95, recommended range 0.8~1.1
    @Published var iconScale: Double = 0.95 {
        didSet {
            UserDefaults.standard.set(iconScale, forKey: "iconScale")
            guard !isApplyingScopedAppearanceState else { return }
            updateScopedAppearanceSettings(for: currentAppearanceLayoutMode) { $0.iconScale = iconScale }
            iconScaleWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.triggerGridRefresh() }
            iconScaleWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        evaluateOnboardingGate()
        
        // Try loading persistence data immediately (if available) — do not set flag too early, wait until loading completes
        if !hasAppliedOrderFromStore {
            persistence.loadAllOrder()
        }
        
        $apps
            .map { !$0.isEmpty }
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.hasAppliedOrderFromStore {
                    self.persistence.loadAllOrder()
                }
            }
            .store(in: &cancellables)
        
        // Monitor items changes, auto-save sort order
        $items
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, !self.items.isEmpty else { return }
                // Debounced save to avoid frequent writes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.persistence.saveAllOrder()
                }
            }
            .store(in: &cancellables)
    }

    func completeOnboarding() {
        UserDefaults.standard.set(Self.currentOnboardingVersion, forKey: Self.onboardingVersionKey)
        shouldShowOnboarding = false
    }

    func forceShowOnboarding() {
        guard isFullscreenMode else { return }

        if isSetting {
            isSetting = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                self.shouldShowOnboarding = false
                self.shouldShowOnboarding = true
            }
            return
        }

        shouldShowOnboarding = false
        DispatchQueue.main.async { [weak self] in
            self?.shouldShowOnboarding = true
        }
    }

    private func evaluateOnboardingGate() {
        let shownVersion = UserDefaults.standard.object(forKey: Self.onboardingVersionKey) as? Int ?? 0
        guard shownVersion < Self.currentOnboardingVersion else {
            shouldShowOnboarding = false
            return
        }

        if isExistingUserForOnboarding() {
            UserDefaults.standard.set(Self.currentOnboardingVersion, forKey: Self.onboardingVersionKey)
            shouldShowOnboarding = false
            return
        }

        shouldShowOnboarding = true
    }

    private func isExistingUserForOnboarding() -> Bool {
        if !hiddenAppPaths.isEmpty { return true }
        if !customTitles.isEmpty { return true }
        if persistence.hasPersistedOrderData() { return true }
        return false
    }

    // MARK: - Order Persistence
    func applyOrderAndFolders() {
        self.persistence.loadAllOrder()
    }

    // MARK: - Initial scan (once)
    func performInitialScanIfNeeded() {
        guard !hasPerformedInitialScan else { return }

        // Load persisted order first (before scan can overwrite it)
        if !hasAppliedOrderFromStore {
            persistence.loadAllOrder()
        }

        hasPerformedInitialScan = true

        // Soft check: compare persisted apps against a quick filesystem listing.
        // Skip the full scan if nothing changed since last time.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let currentPaths = Set(self.apps.map { $0.url.path })
            var diskPaths = Set<String>()
            for path in self.applicationSearchPaths {
                let url = URL(fileURLWithPath: path)
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let item as URL in enumerator {
                    let resolved = item.resolvingSymlinksInPath()
                    guard resolved.pathExtension == "app",
                          self.isValidApp(at: resolved),
                          !self.isInsideAnotherApp(resolved) else { continue }
                    diskPaths.insert(resolved.path)
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if diskPaths == currentPaths {
                    // Nothing changed — display persisted data as-is
                    self.generateCacheAfterScan()
                } else {
                    self.scanApplicationsWithOrderPreservation()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.generateCacheAfterScan()
                    }
                }
            }
        }
    }

    /// Lightweight background check: re-scan if the on-disk app set differs
    /// from what we have. Runs at low priority so it doesn't interrupt search.
    private func softRefreshInBackground() {
        let currentPaths = Set(apps.map { $0.url.path })
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var diskPaths = Set<String>()
            for path in self.applicationSearchPaths {
                let url = URL(fileURLWithPath: path)
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let item as URL in enumerator {
                    let resolved = item.resolvingSymlinksInPath()
                    guard resolved.pathExtension == "app",
                          self.isValidApp(at: resolved),
                          !self.isInsideAnotherApp(resolved) else { continue }
                    diskPaths.insert(resolved.path)
                }
            }
            if diskPaths != currentPaths {
                DispatchQueue.main.async { [weak self] in
                    self?.scanApplicationsWithOrderPreservation()
                }
            }
        }
    }

    private var searchRefreshWorkItem: DispatchWorkItem?

    private func scheduleSoftRefreshOnSearch() {
        searchRefreshWorkItem?.cancel()
        searchRefreshWorkItem = DispatchWorkItem { [weak self] in
            self?.softRefreshInBackground()
        }
        DispatchQueue.main.async(execute: searchRefreshWorkItem!)
    }

    func scanApplications(loadPersistedOrder: Bool = true) {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AppInfo] = []
            var seenPaths = Set<String>()

            for path in self.applicationSearchPaths {
                let url = URL(fileURLWithPath: path)
                
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let item as URL in enumerator {
                        let resolved = item.resolvingSymlinksInPath()
                        guard resolved.pathExtension == "app",
                              self.isValidApp(at: resolved),
                              !self.isInsideAnotherApp(resolved) else { continue }
                        if !seenPaths.contains(resolved.path) {
                            seenPaths.insert(resolved.path)
                            found.append(self.appInfo(from: resolved, loadIcon: false))
                        }
                    }
                }
            }

            let sorted = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.apps = sorted
                self.pruneHiddenAppsFromAppList()
                if loadPersistedOrder {
                    self.persistence.rebuildItems()
                    self.persistence.loadAllOrder()
                } else {
                    self.items = self.filteredItemsRemovingHidden(from: sorted.map { .app($0) })
                    self.persistence.saveAllOrder()
                }
                self.refreshMissingPlaceholders()
                
                // Generate cache after scan completes
                self.generateCacheAfterScan()
            }
        }
    }
    
    /// Smart scan: maintain existing order, append new apps at the end，Missing apps removed, auto-fill within pages
    func scanApplicationsWithOrderPreservation() {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AppInfo] = []
            var seenPaths = Set<String>()

            // Use concurrent queue to accelerate scanning
            let scanQueue = DispatchQueue(label: "app.scan", attributes: .concurrent)
            let group = DispatchGroup()
            let lock = NSLock()
            
            // Scan all apps
            for path in self.applicationSearchPaths {
                group.enter()
                scanQueue.async {
                    let url = URL(fileURLWithPath: path)
                    
                    if let enumerator = FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) {
                        var localFound: [AppInfo] = []
                        var localSeenPaths = Set<String>()
                        
                        for case let item as URL in enumerator {
                            let resolved = item.resolvingSymlinksInPath()
                            guard resolved.pathExtension == "app",
                                  self.isValidApp(at: resolved),
                                  !self.isInsideAnotherApp(resolved) else { continue }
                            if !localSeenPaths.contains(resolved.path) {
                                localSeenPaths.insert(resolved.path)
                                localFound.append(self.appInfo(from: resolved, loadIcon: false))
                            }
                        }
                        
                        // Thread-safe merge of results
                        lock.lock()
                        found.append(contentsOf: localFound)
                        seenPaths.formUnion(localSeenPaths)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            
            group.wait()
            
            // Deduplicate and sort - using safer method
            var uniqueApps: [AppInfo] = []
            var uniqueSeenPaths = Set<String>()
            
            for app in found {
                if !uniqueSeenPaths.contains(app.url.path) {
                    uniqueSeenPaths.insert(app.url.path)
                    uniqueApps.append(app)
                }
            }
            
            // Preserve existing app order, sort only new apps by name
            var newApps: [AppInfo] = []
            var existingAppPaths = Set<String>()
            let refreshedMap = Dictionary(uniqueKeysWithValues: uniqueApps.map { ($0.url.path, $0) })

            for app in self.apps {
                guard let refreshed = refreshedMap[app.url.path] else { continue }
                newApps.append(refreshed)
                existingAppPaths.insert(app.url.path)
            }

            let newAppPaths = uniqueApps.filter { !existingAppPaths.contains($0.url.path) }
            let sortedNewApps = newAppPaths.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            newApps.append(contentsOf: sortedNewApps)
            
            DispatchQueue.main.async {
                self.processScannedApplications(newApps)
                
                // Generate cache after scan completes
                self.generateCacheAfterScan()
            }
        }
    }
    
    /// Manually trigger full rescan (for manual refresh in settings)
    func forceFullRescan() {
        // Clear cache
        cacheManager.clearAllCaches()
        
        hasPerformedInitialScan = false
        scanApplicationsWithOrderPreservation()
    }
    
    /// Processscanned apps, smart-match with existing order
    private func processScannedApplications(_ newApps: [AppInfo]) {
        // Save current items order and structure
        let currentItems = self.items
        
        // Create new app list, but preserve existing order
        var updatedApps: [AppInfo] = []
        var newAppsToAdd: [AppInfo] = []
        var freshMap: [String: AppInfo] = [:]
        for app in newApps {
            freshMap[app.url.path] = app
        }

        // Step 1: Preserve existing order, refresh app info with latest scan results
        for app in self.apps {
            updatedApps.append(freshMap[app.url.path] ?? app)
        }

        // Sync update folderapp objects, ensure name/icontimelyrefresh
        for folderIndex in folders.indices {
            let refreshedApps = folders[folderIndex].apps.map { freshMap[$0.url.path] ?? $0 }
            folders[folderIndex].apps = refreshedApps
        }
        
        // Step 2: Find newly added apps (preserve order matching scan results)
        let existingPaths = Set(updatedApps.map { $0.url.path })
        for newApp in newApps where !existingPaths.contains(newApp.url.path) {
            newAppsToAdd.append(newApp)
        }

        // Step 3: Append new apps to the end, keep existing app order unchanged
        updatedApps.append(contentsOf: newAppsToAdd)

        // updateapplist
        self.apps = updatedApps
        pruneHiddenAppsFromAppList()
        
        // Step 4: Smart-rebuild items list, preserve user order
        self.persistence.smartRebuildItemsWithOrderPreservation(currentItems: currentItems, newApps: newAppsToAdd)
        
        // Step 5: Auto-fill within pages
        self.compactItemsWithinPages()

        // Step 5.5: Sync missing placeholders based on latest disk state
        self.refreshMissingPlaceholders()

        // Step 6: Save new order
        self.persistence.saveAllOrder()

        // Trigger UI update
        self.triggerFolderUpdate()
        self.triggerGridRefresh()
    }

    // MARK: - AI Overlay Preview
    //
    // func presentAIOverlayPreview() {
    //     // guard isAIEnabled else { return }
    //     // DispatchQueue.main.async { [weak self] in
    //     //     guard let self else { return }
    //     //     AIOverlayController.shared.show(with: self)
    //     // }
    // }
    //
    // func dismissAIOverlayPreview() {
    //     // DispatchQueue.main.async {
    //     //     AIOverlayController.shared.hide()
    //     // }
    // }
    //
    // func toggleAIOverlayPreview() {
    //     // guard isAIEnabled else {
    //     //     AIOverlayController.shared.hide()
    //     //     return
    //     // }
    //     // DispatchQueue.main.async { [weak self] in
    //     //     guard let self else { return }
    //     //     AIOverlayController.shared.toggle(with: self)
    //     // }
    // }

    deinit {
        MainActor.assumeIsolated {
            updateChecker.cancelAutoCheck()
            stopAutoRescan()
            let center = NSWorkspace.shared.notificationCenter
            volumeObservers.forEach { center.removeObserver($0) }
        }
    }

    // MARK: - FSEvents wiring
    func startAutoRescan() {
        guard fsEventStream == nil else { return }

        let pathsToWatch = applicationSearchPaths
        guard !pathsToWatch.isEmpty else { return }

        let box = FSEventContextBox(store: self)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        fsEventContextPointer = UnsafeMutableRawPointer(ptr)
        var context = FSEventStreamContext(
            version: 0,
            info: fsEventContextPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, clientInfo, numEvents, eventPaths, eventFlags, _) in
            guard let info = clientInfo else { return }
            let box = Unmanaged<FSEventContextBox>.fromOpaque(info).takeUnretainedValue()
            guard let appStore = box.store else { return }

            guard numEvents > 0 else {
                appStore.handleFSEvents(paths: [], flagsPointer: eventFlags, count: 0)
                return
            }

            // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray of CFString
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let nsArray = cfArray as NSArray
            guard let pathsArray = nsArray as? [String] else { return }

            appStore.handleFSEvents(paths: pathsArray, flagsPointer: eventFlags, count: numEvents)
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let latency: CFTimeInterval = 0.0

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            // Balance the passRetained if stream creation fails
            Unmanaged<FSEventContextBox>.fromOpaque(ptr).release()
            fsEventContextPointer = nil
            return
        }

        fsEventStream = stream
        FSEventStreamSetDispatchQueue(stream, fsEventsQueue)
        FSEventStreamStart(stream)
    }

    func stopAutoRescan() {
        // Balance the passRetained from startAutoRescan
        if let ptr = fsEventContextPointer {
            Unmanaged<FSEventContextBox>.fromOpaque(ptr).release()
            fsEventContextPointer = nil
        }
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
        stopFallbackScanTimer()
    }

    func restartAutoRescan() {
        stopAutoRescan()
        startAutoRescan()
    }

    // MARK: - Fallback periodic scan

    /// Periodically verifies the app list against the filesystem to catch
    /// changes that FSEvents may have missed (e.g. events dropped during
    /// app install, or while the process was suspended).
    private static let fallbackScanInterval: TimeInterval = 5 * 60 // 5 minutes

    func startFallbackScanTimer() {
        stopFallbackScanTimer()
        let timer = DispatchSource.makeTimerSource(queue: refreshQueue)
        timer.schedule(deadline: .now() + Self.fallbackScanInterval,
                       repeating: Self.fallbackScanInterval)
        timer.setEventHandler { [weak self] in
            self?.performFallbackScanIfNeeded()
        }
        timer.activate()
        fallbackScanTimer = timer
    }

    private func stopFallbackScanTimer() {
        fallbackScanTimer?.cancel()
        fallbackScanTimer = nil
    }

    private func performFallbackScanIfNeeded() {
        guard !apps.isEmpty else { return }
        let currentPaths = Set(apps.map { $0.url.path })

        refreshQueue.async { [weak self] in
            guard let self else { return }
            var diskPaths = Set<String>()
            for path in self.applicationSearchPaths {
                let url = URL(fileURLWithPath: path)
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let item as URL in enumerator {
                        let resolved = item.resolvingSymlinksInPath()
                        guard resolved.pathExtension == "app",
                              self.isValidApp(at: resolved),
                              !self.isInsideAnotherApp(resolved) else { continue }
                        diskPaths.insert(resolved.path)
                    }
                }
            }
            if diskPaths != currentPaths {
                DispatchQueue.main.async { [weak self] in
                    self?.scanApplicationsWithOrderPreservation()
                }
            }
        }
    }

    @discardableResult
    func addCustomAppSource(path: String) -> Bool {
        guard let normalized = normalizeApplicationPath(path) else { return false }
        if customAppSourcePaths.contains(where: { normalizeApplicationPath($0) == normalized }) { return false }
        customAppSourcePaths.append(normalized)
        return true
    }

    func removeCustomAppSource(at index: Int) {
        guard customAppSourcePaths.indices.contains(index) else { return }
        let removed = customAppSourcePaths[index]
        purgeMissingPlaceholders(forRemovedSources: [removed])
        customAppSourcePaths.remove(at: index)
    }

    func removeCustomAppSources(at offsets: IndexSet) {
        let removed = offsets.compactMap { offset -> String? in
            guard customAppSourcePaths.indices.contains(offset) else { return nil }
            return customAppSourcePaths[offset]
        }
        purgeMissingPlaceholders(forRemovedSources: removed)
        customAppSourcePaths.remove(atOffsets: offsets)
    }

    func resetCustomAppSources() {
        guard !customAppSourcePaths.isEmpty else { return }
        let removed = customAppSourcePaths
        purgeMissingPlaceholders(forRemovedSources: removed)
        customAppSourcePaths.removeAll()
    }

    func removeCustomAppSource(path: String) {
        guard let normalized = normalizeApplicationPath(path) else { return }
        if let index = customAppSourcePaths.firstIndex(where: { normalizeApplicationPath($0) == normalized }) {
            let removed = customAppSourcePaths[index]
            purgeMissingPlaceholders(forRemovedSources: [removed])
            customAppSourcePaths.remove(at: index)
        }
    }

    private func setupVolumeObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let mountObserver = center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self.handleVolumeEvent(at: url, isMount: true)
        }

        let unmountObserver = center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self.handleVolumeEvent(at: url, isMount: false)
        }

        volumeObservers = [mountObserver, unmountObserver]
    }

    private func handleVolumeEvent(at url: URL, isMount: Bool) {
        let volumePath = url.standardizedFileURL.path
        guard !volumePath.isEmpty else { return }

        let relevant = customAppSourcePaths.contains { source in
            guard let normalized = normalizeApplicationPath(source) else { return false }
            return normalized.hasPrefix(volumePath)
        }

        guard relevant else { return }

        let delay: TimeInterval = isMount ? 1.0 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restartAutoRescan()
            self.scanApplicationsWithOrderPreservation()
        }
    }

    private func handleFSEvents(paths: [String], flagsPointer: UnsafePointer<FSEventStreamEventFlags>?, count: Int) {
        let maxCount = min(paths.count, count)
        var localForceFull = false
        
        for i in 0..<maxCount {
            let rawPath = paths[i]
            let flags = flagsPointer?[i] ?? 0

            let created = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)) != 0
            let removed = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)) != 0
            let renamed = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0
            let modified = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) != 0
            let isDir = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) != 0

            if isDir && (created || removed || renamed), applicationSearchPaths.contains(where: { rawPath.hasPrefix($0) }) {
                localForceFull = true
                break
            }

            guard let appBundlePath = self.canonicalAppBundlePath(for: rawPath) else { continue }
            if created || removed || renamed || modified {
                pendingChangedAppPaths.insert(appBundlePath)
            }
        }

        if localForceFull { pendingForceFullScan = true }
        scheduleRescan()
    }

    private func scheduleRescan() {
        // Debounce to coalesce rapid FSEvents (e.g. app installs write many files).
        // 1 second lets the dust settle before rescanning.
        rescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performImmediateRefresh() }
        rescanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func performImmediateRefresh() {
        if pendingForceFullScan || pendingChangedAppPaths.count > fullRescanThreshold {
            pendingForceFullScan = false
            pendingChangedAppPaths.removeAll()
            scanApplications()
            return
        }
        
        let changed = pendingChangedAppPaths
        pendingChangedAppPaths.removeAll()
        
        if !changed.isEmpty {
            applyIncrementalChanges(for: changed)
        }
    }


    private func applyIncrementalChanges(for changedPaths: Set<String>) {
        guard !changedPaths.isEmpty else { return }
        
        // Move disk I/O and icon parsing to background; main thread only applies results to reduce jank
        let snapshotApps = self.apps
        refreshQueue.async { [weak self] in
            guard let self else { return }
            
            enum PendingChange {
                case insert(AppInfo)
                case update(AppInfo)
                case remove(String) // path
            }
            var changes: [PendingChange] = []
            var pathToIndex: [String: Int] = [:]
            for (idx, app) in snapshotApps.enumerated() { pathToIndex[app.url.path] = idx }
            
            for path in changedPaths {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let exists = FileManager.default.fileExists(atPath: url.path)
                let valid = exists && self.isValidApp(at: url) && !self.isInsideAnotherApp(url)
                if valid {
                    let info = self.appInfo(from: url)
                    if pathToIndex[url.path] != nil {
                        changes.append(.update(info))
                    } else {
                        changes.append(.insert(info))
                    }
                } else {
                    changes.append(.remove(url.path))
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                
                // App delete event: preserve existing icon, etc. pending volume remount
                
                // appupdate
                let updates: [AppInfo] = changes.compactMap { if case .update(let info) = $0 { return info } else { return nil } }
                if !updates.isEmpty {
                    var map: [String: Int] = [:]
                    for (idx, app) in self.apps.enumerated() { map[app.url.path] = idx }
                    for info in updates {
                        let standardizedInfoPath = self.standardizedFilePath(info.url.path)
                        if let idx = map[info.url.path], self.apps.indices.contains(idx) { self.apps[idx] = info }
                        for fIdx in self.folders.indices {
                            for aIdx in self.folders[fIdx].apps.indices where self.folders[fIdx].apps[aIdx].url.path == info.url.path {
                                self.folders[fIdx].apps[aIdx] = info
                            }
                        }
                        for iIdx in self.items.indices {
                            switch self.items[iIdx] {
                            case .app(let a):
                                if self.standardizedFilePath(a.url.path) == standardizedInfoPath {
                                    self.items[iIdx] = .app(info)
                                    self.clearMissingPlaceholder(for: standardizedInfoPath)
                                }
                            case .missingApp(let placeholder):
                                if self.standardizedFilePath(placeholder.bundlePath) == standardizedInfoPath {
                                    self.items[iIdx] = .app(info)
                                    self.clearMissingPlaceholder(for: standardizedInfoPath)
                                }
                            default:
                                break
                            }
                        }
                    }
                    self.persistence.rebuildItems()
                }
                
                // Add new apps
                let inserts: [AppInfo] = changes.compactMap { if case .insert(let info) = $0 { return info } else { return nil } }
                if !inserts.isEmpty {
                    self.apps.append(contentsOf: inserts)
                    self.apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.persistence.rebuildItems()
                }
                
                // refreshandPersistence
                self.triggerFolderUpdate()
                self.triggerGridRefresh()
                self.refreshMissingPlaceholders()
                self.persistence.saveAllOrder()
                self.updateCacheAfterChanges()
            }
        }
    }

    private func canonicalAppBundlePath(for rawPath: String) -> String? {
        guard let range = rawPath.range(of: ".app") else { return nil }
        let end = rawPath.index(range.lowerBound, offsetBy: 4)
        let bundlePath = String(rawPath[..<end])
        return bundlePath
    }

    private func isInsideAnotherApp(_ url: URL) -> Bool {
        let appCount = url.pathComponents.filter { $0.hasSuffix(".app") }.count
        return appCount > 1
    }

    private func isValidApp(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) &&
        NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    func appInfo(from url: URL, preferredName: String? = nil, loadIcon: Bool? = nil) -> AppInfo {
        let shouldLoad = loadIcon ?? (PerformanceMode.current == .full)
        return AppInfo.from(url: url,
                     preferredName: preferredName,
                     customTitle: customTitles[url.path],
                     loadIcon: shouldLoad)
    }
    
    // MARK: - Folder management
    func createFolder(with apps: [AppInfo], name: String = "Untitled") -> FolderInfo {
        return createFolder(with: apps, name: name, insertAt: nil)
    }

    func createFolder(with apps: [AppInfo], name: String = "Untitled", insertAt insertIndex: Int?) -> FolderInfo {
        let folder = FolderInfo(name: name, apps: apps)
        folders.append(folder)

        // Remove apps already added to folder from app list (top-layer apps)
        for app in apps {
            if let index = self.apps.firstIndex(of: app) {
                self.apps.remove(at: index)
            }
        }

        // In current items: replace these top-layer apps with nil/empty slots, place folder at target position, maintain total length
        var newItems = self.items
        // Find these app positions
        var placeholders: [(Int, AppInfo)] = []
        var remainingApps = apps
        for (idx, item) in newItems.enumerated() {
            guard !remainingApps.isEmpty else { break }
            if case let .app(a) = item, let matchIndex = remainingApps.firstIndex(of: a) {
                let match = remainingApps.remove(at: matchIndex)
                placeholders.append((idx, match))
            }
        }
        // Set involved app slots to nil/empty first
        for (idx, _) in placeholders {
            newItems[idx] = .empty(UUID().uuidString)
        }
        // Choose folder position: prefer insertIndex, otherwise use smallest index; clamp range and use replace not insert
        let baseIndex = placeholders.map { $0.0 }.min() ?? min(newItems.count - 1, max(0, insertIndex ?? (newItems.count - 1)))
        let desiredIndex = insertIndex ?? baseIndex
        let safeIndex = min(max(0, desiredIndex), max(0, newItems.count - 1))
        if newItems.isEmpty {
            newItems = [.folder(folder)]
        } else {
            newItems[safeIndex] = .folder(folder)
        }
        self.items = filteredItemsRemovingHidden(from: newItems)
        // Auto-fill within single page: move nil/empty slots to page end
        compactItemsWithinPages()
        removeEmptyPages()

        // triggerfolderupdate，notificationallrelatedviewrefreshicon
        DispatchQueue.main.async { [weak self] in
            self?.triggerFolderUpdate()
        }
        
        // Trigger grid view refresh, ensure UI updates immediately
        triggerGridRefresh()
        
        // Refresh cache, ensure search can find newly created folder's apps
        refreshCacheAfterFolderOperation()

        persistence.saveAllOrder()
        return folder
    }
    
    func addAppToFolder(_ app: AppInfo, folder: FolderInfo) {
        guard let folderIndex = folders.firstIndex(of: folder) else { return }
        
        
        // Create new FolderInfo instance, ensure SwiftUI can detect changes
        var updatedFolder = folders[folderIndex]
        updatedFolder.apps.append(app)
        folders[folderIndex] = updatedFolder
        
        
        // fromapplistinremove
        if let appIndex = apps.firstIndex(of: app) {
            apps.remove(at: appIndex)
        }
        
        // Set top-layer app slot positions as empty (maintain page independence)
        if let pos = items.firstIndex(of: .app(app)) {
            items[pos] = .empty(UUID().uuidString)
            // Auto-fill within single page
            compactItemsWithinPages()
            removeEmptyPages()
        } else {
            // If not found, fall back to rebuild
            persistence.rebuildItems()
        }
        
        // Ensure items for corresponding folder also update to latest contents, for search visibility
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == updatedFolder.id {
                items[idx] = .folder(updatedFolder)
            }
        }
        
        // Immediately trigger folder update, notify all related views to refresh icon and name
        triggerFolderUpdate()
        
        // Trigger grid view refresh, ensure UI updates immediately
        triggerGridRefresh()
        
        // refreshcache，ensuresearchwhencan findnewaddapp
        refreshCacheAfterFolderOperation()
        
        persistence.saveAllOrder()
    }
    
    func removeAppFromFolder(_ app: AppInfo, folder: FolderInfo) {
        guard let folderIndex = folders.firstIndex(of: folder) else { return }
        
        
        // Create new FolderInfo instance, ensure SwiftUI can detect changes
        var updatedFolder = folders[folderIndex]
        updatedFolder.apps.removeAll { $0 == app }
        
        
        // iffoldernil/empty，Delete folder
        if updatedFolder.apps.isEmpty {
            folders.remove(at: folderIndex)
        } else {
            // Update folder
            folders[folderIndex] = updatedFolder
        }
        
        // Sync update items thefolder item，avoidUIcontinuereferenceoldfolderContents
        var emptiedSlots: [Int] = []
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == folder.id {
                if updatedFolder.apps.isEmpty {
                    // folder already nil/empty, then deleted, thenthe position flagged as nil/empty slot，etc.pending subsequentfill
                    items[idx] = .empty(UUID().uuidString)
                    emptiedSlots.append(idx)
                } else {
                    items[idx] = .folder(updatedFolder)
                }
            }
        }
        
        // App re-added to app list (if already exists then update, avoid duplicates)
        if let existingIndex = apps.firstIndex(where: { $0.url == app.url }) {
            apps[existingIndex] = app
        } else {
            apps.append(app)
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Prefer using recorded nil/empty slot, search for other nil/empty slots, then append new slot as last resort
        var targetSlot: Int? = nil
        if let firstEmptied = emptiedSlots.first, firstEmptied < items.count {
            targetSlot = firstEmptied
        } else {
            targetSlot = items.firstIndex {
                if case .empty = $0 { return true }
                return false
            }
        }
        if let slot = targetSlot {
            items[slot] = .app(app)
        } else {
            items.append(.app(app))
        }

        // Immediately trigger folder update, notify all related views to refresh icon and name
        triggerFolderUpdate()

        // Only compact nil/empty slots within the page
        compactItemsWithinPages()
        removeEmptyPages()

        // Trigger grid view refresh, ensure UI updates immediately
        triggerGridRefresh()

        // refreshcache，ensuresearchwhencan findfromfolderremoveapp（inrebuildafterrefresh)
        refreshCacheAfterFolderOperation()

        persistence.saveAllOrder()
    }
    
    func renameFolder(_ folder: FolderInfo, newName: String) {
        guard let index = folders.firstIndex(of: folder) else { return }
        
        
        // Create new FolderInfo instance, ensure SwiftUI can detect changes
        var updatedFolder = folders[index]
        updatedFolder.name = newName
        folders[index] = updatedFolder
        
        // Sync update the folder item, avoid main grid continuing to show old name
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == updatedFolder.id {
                items[idx] = .folder(updatedFolder)
            }
        }
        
        
        // Immediately triggerfolderupdate，notificationallrelatedviewrefresh
        triggerFolderUpdate()
        
        // Trigger grid view refresh, ensure UI updates immediately
        triggerGridRefresh()
        
        // Refresh cache, ensure search functionality works
        refreshCacheAfterFolderOperation()
        
        persistence.rebuildItems()
        persistence.saveAllOrder()
    }

    @discardableResult
    func reorderAppInFolder(folderID: String, from sourceIndex: Int, to destinationIndex: Int) -> Bool {
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }) else { return false }
        var updatedFolder = folders[folderIndex]
        guard updatedFolder.apps.indices.contains(sourceIndex) else { return false }

        let movingApp = updatedFolder.apps.remove(at: sourceIndex)
        let clampedDestination = min(max(0, destinationIndex), updatedFolder.apps.count)
        updatedFolder.apps.insert(movingApp, at: clampedDestination)
        folders[folderIndex] = updatedFolder

        for idx in items.indices {
            if case .folder(let folder) = items[idx], folder.id == folderID {
                items[idx] = .folder(updatedFolder)
            }
        }

        if openFolder?.id == folderID {
            openFolder = updatedFolder
        }

        triggerFolderUpdate()
        triggerGridRefresh()
        refreshCacheAfterFolderOperation()
        saveAllOrder()
        return true
    }

    @discardableResult
    func showAppInFinder(_ app: AppInfo) -> Bool {
        guard FileManager.default.fileExists(atPath: app.url.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
        return true
    }

    @discardableResult
    func copyAppPath(_ app: AppInfo) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(app.url.path, forType: .string)
    }

    func requestRenameFolder(_ folder: FolderInfo) {
        let folderID = folder.id
        let resolvedFolder: FolderInfo
        if let latest = folders.first(where: { $0.id == folderID }) {
            resolvedFolder = latest
        } else if let item = items.first(where: {
            if case .folder(let existing) = $0 { return existing.id == folderID }
            return false
        }), case .folder(let existing) = item {
            resolvedFolder = existing
        } else {
            resolvedFolder = folder
        }

        openFolderActivatedByKeyboard = false
        openFolder = resolvedFolder
        folderRenameRequestID = folderID
    }

    @discardableResult
    func dissolveFolder(_ folder: FolderInfo) -> Bool {
        let folderID = folder.id

        let resolvedFolder: FolderInfo
        if let index = folders.firstIndex(where: { $0.id == folderID }) {
            resolvedFolder = folders[index]
            folders.remove(at: index)
        } else if let itemIndex = items.firstIndex(where: {
            if case .folder(let f) = $0 { return f.id == folderID }
            return false
        }), case .folder(let fallbackFolder) = items[itemIndex] {
            resolvedFolder = fallbackFolder
        } else {
            return false
        }

        let folderApps = resolvedFolder.apps
        let folderAppPaths = Set(folderApps.map { standardizedFilePath($0.url.path) })
        var newItems = items

        // Remove stale duplicates first; the folder slot will be reused for the first restored app.
        if !folderAppPaths.isEmpty {
            for idx in newItems.indices {
                if case .app(let app) = newItems[idx],
                   folderAppPaths.contains(standardizedFilePath(app.url.path)) {
                    newItems[idx] = .empty(UUID().uuidString)
                }
            }
        }

        if let folderItemIndex = newItems.firstIndex(where: {
            if case .folder(let f) = $0 { return f.id == folderID }
            return false
        }) {
            newItems[folderItemIndex] = .empty(UUID().uuidString)
            var insertIndex = folderItemIndex
            for app in folderApps {
                newItems = cascadeInsert(into: newItems, item: .app(app), at: insertIndex)
                insertIndex += 1
            }
        } else if !folderApps.isEmpty {
            newItems.append(contentsOf: folderApps.map { .app($0) })
        }

        var existingTopLevelPaths = Set(apps.map { standardizedFilePath($0.url.path) })
        for app in folderApps {
            let normalized = standardizedFilePath(app.url.path)
            if !existingTopLevelPaths.contains(normalized) {
                apps.append(app)
                existingTopLevelPaths.insert(normalized)
            }
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        pruneHiddenAppsFromAppList()

        items = filteredItemsRemovingHidden(from: newItems)
        if openFolder?.id == folderID {
            openFolder = nil
        }

        compactItemsWithinPages()
        removeEmptyPages()
        triggerFolderUpdate()
        triggerGridRefresh()
        refreshCacheAfterFolderOperation()
        persistence.saveAllOrder()
        return true
    }
    
    // onekeyresetlayout：full renewscanapp，deleteallfolder、order/sortandemptypadding
    func resetLayout() {
        // closeOpen folder
        openFolder = nil
        
        // clearallfolderandorder/sortdata
        folders.removeAll()
        
        // clearallPersistenceorder/sortdata
        persistence.clearAllPersistedData()
        
        // Clear cache
        cacheManager.clearAllCaches()
        
        // resetscanflag，force renewscan
        hasPerformedInitialScan = false
        
        // clearcurrentitems list
        items.removeAll()
        missingPlaceholders.removeAll()

        // renewscanapp，notloadPersistencedata
        scanApplications(loadPersistedOrder: false)
        
        // resettoFirst page
        currentPage = 0
        
        // triggerfolderupdate，notificationallrelatedviewrefresh
        triggerFolderUpdate()
        
        // Trigger grid view refresh, ensure UI updates immediately
        triggerGridRefresh()
        
        // scanCompleteafterrefreshcache
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshCacheAfterFolderOperation()
        }
    }

    func resetAppearanceSettings() {
        let defaults = UserDefaults.standard
        let keysToClear: [String] = [
            Self.sidebarIconPresetKey,
            "appearancePreference",
            Self.backgroundStyleKey,
            Self.backgroundMaskEnabledKey,
            Self.backgroundMaskLightKey,
            Self.backgroundMaskDarkKey,
            "isFullscreenMode",
            "showLabels",
            Self.folderPreviewHighResKey,
            Self.folderLayoutModeKey,
            "hideDock",
            Self.hideMenuBarKey,
            "scrollSensitivity",
            Self.gridColumnsKey,
            Self.gridRowsKey,
            Self.columnSpacingKey,
            Self.rowSpacingKey,
            "enableDropPrediction",
            Self.folderDropZoneScaleKey,
            "enableAnimations",
            Self.hoverMagnificationKey,
            Self.hoverMagnificationScaleKey,
            Self.activePressEffectKey,
            Self.followScrollPagingKey,
            Self.reverseWheelPagingKey,
            Self.activePressScaleKey,
            "iconScale",
            "iconLabelFontSize",
            Self.iconLabelFontWeightKey,
            "animationDuration",
            Self.windowOpenAnimationKey,
            "useLocalizedThirdPartyTitles",
            "pageIndicatorOffset",
            Self.pageIndicatorTopPaddingKey,
            Self.pageIndicatorPerDisplayEnabledKey,
            Self.pageIndicatorPerDisplayOverridesKey,
            Self.dualModeAppearanceSettingsKey,
            Self.rememberPageKey,
            Self.rememberedPageIndexKey,
            "folderPopoverWidthFactor",
            "folderPopoverHeightFactor",
            "showFPSOverlay"
        ]

        keysToClear.forEach { defaults.removeObject(forKey: $0) }
        Self.writeDefaultAppearancePreferences(to: defaults)
        reloadAppearancePreferencesFromDefaults()

        clearIconCachesForLayoutChange()
        triggerFolderUpdate()
        triggerGridRefresh()
    }
    
    /// Auto-fill within single page：eachpage .empty slotmovetothepage end，maintainnon-nil/non-emptyitemmutualfororder
    func compactItemsWithinPages() {
        guard !items.isEmpty else { return }
        items = filteredItemsRemovingHidden(from: compactedItemsWithinPages(items))
    }

    private func compactedItemsWithinPages(_ source: [LaunchpadItem]) -> [LaunchpadItem] {
        guard !source.isEmpty else { return source }
        let itemsPerPage = self.itemsPerPage // useComputed properties
        var result: [LaunchpadItem] = []
        result.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let end = min(index + itemsPerPage, source.count)
            let pageSlice = Array(source[index..<end])
            var nonEmpty: [LaunchpadItem] = []
            var emptyTokens: [String] = []
            nonEmpty.reserveCapacity(pageSlice.count)
            emptyTokens.reserveCapacity(pageSlice.count)

            for item in pageSlice {
                switch item {
                case .empty(let token):
                    emptyTokens.append(token)
                default:
                    nonEmpty.append(item)
                }
            }

            // firstaddnon-nil/non-emptyitemitem ，maintainoriginalorder
            result.append(contentsOf: nonEmpty)

            // re-addemptyitemitem topageend
            if !emptyTokens.isEmpty {
                result.append(contentsOf: emptyTokens.map { .empty($0) })
            }

            index = end
        }
        return result
    }

    // MARK: - Cross-page drag：cascadeinsert（full pagethenthen once pushed intoNext page)
    func moveSelectedAppsAcrossPagesWithCascade(appPathsOrdered: [String], to targetIndex: Int) {
        guard !appPathsOrdered.isEmpty else { return }

        var seenPaths = Set<String>()
        let normalizedOrderedPaths: [String] = appPathsOrdered.compactMap { raw in
            let normalized = standardizedFilePath(raw)
            guard seenPaths.insert(normalized).inserted else { return nil }
            return normalized
        }
        guard !normalizedOrderedPaths.isEmpty else { return }
        let movingPathSet = Set(normalizedOrderedPaths)

        var movingItemsByPath: [String: LaunchpadItem] = [:]
        for item in items {
            guard case .app(let app) = item else { continue }
            let path = standardizedFilePath(app.url.path)
            if movingPathSet.contains(path), movingItemsByPath[path] == nil {
                movingItemsByPath[path] = .app(app)
            }
        }

        let orderedMovingItems = normalizedOrderedPaths.compactMap { movingItemsByPath[$0] }
        guard !orderedMovingItems.isEmpty else { return }

        var result = items
        let sourceIndexes = result.indices.filter { index in
            guard case .app(let app) = result[index] else { return false }
            return movingPathSet.contains(standardizedFilePath(app.url.path))
        }
        guard !sourceIndexes.isEmpty else { return }

        for index in sourceIndexes {
            result[index] = .empty(UUID().uuidString)
        }

        result = compactedItemsWithinPages(result)
        var insertionIndex = max(0, min(targetIndex, result.count))

        for movingItem in orderedMovingItems {
            result = cascadeInsert(into: result, item: movingItem, at: insertionIndex)
            insertionIndex += 1
        }

        items = filteredItemsRemovingHidden(from: result)
        compactItemsWithinPages()
        removeEmptyPages()
        triggerGridRefresh()
        persistence.saveAllOrder()
    }

    func moveItemAcrossPagesWithCascade(item: LaunchpadItem, to targetIndex: Int) {
        guard items.indices.contains(targetIndex) || targetIndex == items.count else {
            return
        }
        guard let source = items.firstIndex(of: item) else { return }
        var result = items
        // sourcepositionsetnil/empty，maintainlength
        result[source] = .empty(UUID().uuidString)
        // executecascadeinsert
        result = cascadeInsert(into: result, item: item, at: targetIndex)
        items = filteredItemsRemovingHidden(from: result)
        
        // eachtime(s)dragendafterallenterrowcompact，ensureeachpageemptyitemitem movetopageend
        let targetPage = targetIndex / itemsPerPage
        let currentPages = (items.count + itemsPerPage - 1) / itemsPerPage
        
        if targetPage == currentPages - 1 {
            // dragtonewpage，delaycompact toensureapppositionstable
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.compactItemsWithinPages()
                self.removeEmptyPages()
                self.triggerGridRefresh()
            }
        } else {
            // dragtoexistingpage，Immediately compact
            compactItemsWithinPages()
            removeEmptyPages()
        }
        
        // Trigger grid view refresh, ensure UI updates immediately
        triggerGridRefresh()
        
        persistence.saveAllOrder()
    }

    private func cascadeInsert(into array: [LaunchpadItem], item: LaunchpadItem, at targetIndex: Int) -> [LaunchpadItem] {
        var result = array
        let p = self.itemsPerPage // useComputed properties

        // ensurelengthpaddingaswhole page，forProcess
        if result.count % p != 0 {
            let remain = p - (result.count % p)
            for _ in 0..<remain { result.append(.empty(UUID().uuidString)) }
        }

        var currentPage = max(0, targetIndex / p)
        var localIndex = max(0, min(targetIndex - currentPage * p, p - 1))
        var carry: LaunchpadItem? = item

        while let moving = carry {
            let pageStart = currentPage * p
            let pageEnd = pageStart + p
            if result.count < pageEnd {
                let need = pageEnd - result.count
                for _ in 0..<need { result.append(.empty(UUID().uuidString)) }
            }
            var slice = Array(result[pageStart..<pageEnd])
            
            // ensureinsertpositioninvalidrangeinside
            let safeLocalIndex = max(0, min(localIndex, slice.count))
            slice.insert(moving, at: safeLocalIndex)
            
            var spilled: LaunchpadItem? = nil
            if slice.count > p {
                spilled = slice.removeLast()
            }
            result.replaceSubrange(pageStart..<pageEnd, with: slice)
            if let s = spilled, case .empty = s {
                // overflowasnil/empty：end
                carry = nil
            } else if let s = spilled {
                // overflownon-nil/non-empty：pushtoNext pagepage start
                carry = s
                currentPage += 1
                localIndex = 0
                // iftothen exceeds length，paddingNext page
                let nextEnd = (currentPage + 1) * p
                if result.count < nextEnd {
                    let need = nextEnd - result.count
                    for _ in 0..<need { result.append(.empty(UUID().uuidString)) }
                }
            } else {
                carry = nil
            }
        }
        return result
    }

    // triggerfolderupdate，notificationallrelatedviewrefreshicon
    func triggerFolderUpdate() {
        folderUpdateTrigger = UUID()
        FolderPreviewCache.shared.clear()
    }

    func scheduleSystemAppearanceRefresh() {
        guard appearancePreference == .system else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAppearanceEventAt < 0.2 { return }
        lastAppearanceEventAt = now

        appearanceRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.clearIconCachesForLayoutChange()
            self.triggerFolderUpdate()
            self.triggerGridRefresh()
            self.iconCacheRefreshTrigger = UUID()
        }
        appearanceRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    func effectivePageIndicatorOffset(for screenID: String?) -> Double {
        guard pageIndicatorPerDisplayEnabled, let screenID,
              let override = pageIndicatorOverrides[screenID] else {
            return pageIndicatorOffset
        }
        return override.offset
    }

    func effectivePageIndicatorTopPadding(for screenID: String?) -> Double {
        guard pageIndicatorPerDisplayEnabled, let screenID,
              let override = pageIndicatorOverrides[screenID] else {
            return pageIndicatorTopPadding
        }
        return override.topPadding
    }

    func backgroundMaskColor(for colorScheme: ColorScheme) -> Color? {
        guard backgroundMaskEnabled else { return nil }
        let rgba = (colorScheme == .dark) ? backgroundMaskDarkColor : backgroundMaskLightColor
        return rgba.color
    }

    func pageIndicatorOverride(for screenID: String) -> PageIndicatorOverride? {
        pageIndicatorOverrides[screenID]
    }

    func setPageIndicatorOverride(_ override: PageIndicatorOverride?, for screenID: String) {
        var updated = pageIndicatorOverrides
        if let override {
            updated[screenID] = override
        } else {
            updated.removeValue(forKey: screenID)
        }
        pageIndicatorOverrides = updated
        persistPageIndicatorOverrides(updated)
    }

    func applyIndicatorDefaults(to screenID: String) {
        let override = PageIndicatorOverride(offset: pageIndicatorOffset,
                                             topPadding: pageIndicatorTopPadding)
        setPageIndicatorOverride(override, for: screenID)
    }

    func notifyFolderContentChanged(_ folder: FolderInfo) {
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == folder.id {
                items[idx] = .folder(folder)
            }
        }
        triggerFolderUpdate()
        triggerGridRefresh()
        persistence.saveAllOrder()
    }

    private func clearIconCachesForLayoutChange() {
        FolderPreviewCache.shared.clear()
        IconStore.shared.clear()
        purgeIconRenderCaches()
    }

    private func purgeIconRenderCaches() {
        var seen = Set<ObjectIdentifier>()

        func purge(_ image: NSImage) {
            let identifier = ObjectIdentifier(image)
            guard seen.insert(identifier).inserted else { return }
            let originalCacheMode = image.cacheMode
            image.cacheMode = .never
            image.recache()
            image.cacheMode = originalCacheMode
        }

        for app in apps {
            purge(app.icon)
        }

        for folder in folders {
            for app in folder.apps {
                purge(app.icon)
            }
        }

        for item in items {
            if case let .app(app) = item {
                purge(app.icon)
            }
        }
    }
    
    // triggergridviewrefresh，used fordragoperationafterUIupdate
    func triggerGridRefresh() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.triggerGridRefresh()
            }
            return
        }

        guard !gridRefreshScheduled else { return }
        gridRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.gridRefreshScheduled = false
            self.clampCurrentPageWithinBounds()
            self.gridRefreshTrigger = UUID()
        }
    }
    
    
    private func clampCurrentPageWithinBounds() {
        let perPage = max(itemsPerPage, 1)
        let maxPageIndex = items.isEmpty ? 0 : max(0, (items.count - 1) / perPage)
        if currentPage > maxPageIndex {
            currentPage = maxPageIndex
        }
    }

    // MARK: - dragwhenautoCreatenewpage
    private var pendingNewPage: (pageIndex: Int, itemCount: Int)? = nil
    
    func createNewPageForDrag() -> Bool {
        let itemsPerPage = self.itemsPerPage
        let currentPages = (items.count + itemsPerPage - 1) / itemsPerPage
        let newPageIndex = currentPages
        
        // asnewpageaddemptyplaceholder
        for _ in 0..<itemsPerPage {
            items.append(.empty(UUID().uuidString))
        }
        
        // recordpendingProcessnewpageinfo
        pendingNewPage = (pageIndex: newPageIndex, itemCount: itemsPerPage)
        
        // triggergridviewrefresh
        triggerGridRefresh()
        
        return true
    }
    
    func cleanupUnusedNewPage() {
        guard let pending = pendingNewPage else { return }
        
        // checknewpagewhetheruse（whetherhasnotemptyitemitem )
        let pageStart = pending.pageIndex * pending.itemCount
        let pageEnd = min(pageStart + pending.itemCount, items.count)
        
        if pageStart < items.count {
            let pageSlice = Array(items[pageStart..<pageEnd])
            let hasNonEmptyItems = pageSlice.contains { item in
                if case .empty = item { return false } else { return true }
            }
            
            if !hasNonEmptyItems {
                // newpage has nouse，deleteit
                items.removeSubrange(pageStart..<pageEnd)
                
                // triggergridviewrefresh
                triggerGridRefresh()
            }
        }
        
        // clear pendingProcessinfo
        pendingNewPage = nil
    }

    // MARK: - autodeletenil/emptyemptypage
    /// autodeletenil/emptyemptypage：deleteallallisemptypaddingpage
    func removeEmptyPages() {
        guard !items.isEmpty else { return }
        let itemsPerPage = self.itemsPerPage
        
        var newItems: [LaunchpadItem] = []
        var index = 0
        
        while index < items.count {
            let end = min(index + itemsPerPage, items.count)
            let pageSlice = Array(items[index..<end])
            
            // checkcurrentpagewhetherallallisempty
            let isEmptyPage = pageSlice.allSatisfy { item in
                if case .empty = item { return true } else { return false }
            }
            
            // ifnotisnil/emptyemptypage，preservethepageContents
            if !isEmptyPage {
                newItems.append(contentsOf: pageSlice)
            }
            // ifisnil/emptyemptypage，Skipnotadd
            
            index = end
        }
        
        // onlyhasinactualdeletenil/emptyemptypagewhenonly thenupdateitems
        if newItems.count != items.count {
            items = filteredItemsRemovingHidden(from: newItems)
            
            // deletenil/emptyemptypageafter，ensurecurrentpageindexinvalidrangeinside
            let maxPageIndex = max(0, (items.count - 1) / itemsPerPage)
            if currentPage > maxPageIndex {
                currentPage = maxPageIndex
            }
            
            // triggergridviewrefresh
            triggerGridRefresh()
        }
    }

    private func handleGridConfigurationChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.compactItemsWithinPages()
            self.removeEmptyPages()
            self.cleanupUnusedNewPage()
            let maxPageIndex = max(0, (self.items.count - 1) / max(self.itemsPerPage, 1))
            if self.currentPage > maxPageIndex {
                self.currentPage = maxPageIndex
            }
            self.triggerGridRefresh()
            self.cacheManager.refreshCache(from: self.apps,
                                           items: self.items,
                                           itemsPerPage: self.itemsPerPage,
                                           columns: self.gridColumnsPerPage,
                                           rows: self.gridRowsPerPage)
            if self.rememberLastPage {
                UserDefaults.standard.set(self.currentPage, forKey: Self.rememberedPageIndexKey)
            }
            self.persistence.saveAllOrder()
        }
    }
    
    // MARK: - exportapporder/sortfeature
    /// exportapporder/sortasJSONformat
    func exportAppOrderAsJSON() -> String? {
        let exportData = buildExportData()
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    /// buildexportdata
    private func buildExportData() -> [String: Any] {
        var pages: [[String: Any]] = []
        let itemsPerPage = self.itemsPerPage
        
        for (index, item) in items.enumerated() {
            let pageIndex = index / itemsPerPage
            let position = index % itemsPerPage
            
            var itemData: [String: Any] = [
                "pageIndex": pageIndex,
                "position": position,
                "kind": itemKind(for: item),
                "name": item.name,
                "path": itemPath(for: item),
                "folderApps": []
            ]
            
            // ifisfolder，addfolderinsideappinfo
            if case let .folder(folder) = item {
                itemData["folderApps"] = folder.apps.map { $0.name }
                itemData["folderAppPaths"] = folder.apps.map { $0.url.path }
            }
            
            pages.append(itemData)
        }
        
        return [
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "totalPages": (items.count + itemsPerPage - 1) / itemsPerPage,
            "totalItems": items.count,
            "fullscreenMode": isFullscreenMode,
            "pages": pages
        ]
    }
    
    /// Getitemitem typedescription
    private func itemKind(for item: LaunchpadItem) -> String {
        switch item {
        case .app:
            return "app"
        case .folder:
            return "folder"
        case .empty:
            return "empty slot"
        case .missingApp:
            return "missingapp"
        }
    }
    
    /// Getitemitem path
    private func itemPath(for item: LaunchpadItem) -> String {
        switch item {
        case let .app(app):
            return app.url.path
        case let .folder(folder):
            return "folder: \(folder.name)"
        case .empty:
            return "empty slot"
        case let .missingApp(placeholder):
            return "missingapp: \(placeholder.bundlePath)"
        }
    }
    
    /// usesystemfilesavefordialogsaveexportfile
    func saveExportFileWithDialog(content: String, filename: String, fileExtension: String, fileType: String) -> Bool {
        let savePanel = NSSavePanel()
        savePanel.title = "saveexportfile"
        savePanel.nameFieldStringValue = filename
        savePanel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        
        // setdefaultsavepositionasdesktopside
        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            savePanel.directoryURL = desktopURL
        }
        
        let response = savePanel.runModal()
        if response == .OK, let url = savePanel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
        return false
    }
    
    // MARK: - cachemanagement
    
    /// Generate cache after scan completes
    private func generateCacheAfterScan() {
        
        // Check if cache is valid
        if !cacheManager.isCacheValid {
            // Generatenewcache
            cacheManager.generateCache(from: apps,
                                      items: items,
                                      itemsPerPage: itemsPerPage,
                                      columns: gridColumnsPerPage,
                                      rows: gridRowsPerPage)
        } else {
            // cachevalid，butcanPreloadicon
            let appPaths = apps.map { $0.url.path }
            cacheManager.preloadIcons(for: appPaths)
        }

        cacheManager.smartPreloadIcons(for: items, currentPage: currentPage, itemsPerPage: itemsPerPage)

        if isInitialLoading {
            isInitialLoading = false
        }
    }
    
    /// Manualrefresh（simulate fullnewlaunchcompleteflow)
    func refresh() {
        print("LaunchNext: Manual refresh triggered")
        
        // Clear cache，ensureiconandsearchindexrenewGenerate
        cacheManager.clearAllCaches()

        // resetUIandstate，bring it closer to"firsttime(s)launch"
        openFolder = nil
        currentPage = 0
        if !searchText.isEmpty { searchText = "" }

        // notneedreset hasAppliedOrderFromStore，maintainlayoutdata
        hasPerformedInitialScan = true

        // executeandfirsttime(s)launchsameScan path（Maintain existingorder，addinend)
        scanApplicationsWithOrderPreservation()

        // Generate cache after scan completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.generateCacheAfterScan()
        }

        // forceUIrefresh
        triggerFolderUpdate()
        triggerGridRefresh()
    }
    
    /// Clear cache
    func clearCache() {
        cacheManager.clearAllCaches()
    }
    
    /// GetCache stats
    var cacheStatistics: CacheStatistics {
        return cacheManager.cacheStatistics
    }
    
    /// Incremental updateafterupdatecache
    private func updateCacheAfterChanges() {
        // checkcachewhetherneedupdate
        if !cacheManager.isCacheValid {
            // cacheinvalid，renewGenerate
            cacheManager.generateCache(from: apps,
                                      items: items,
                                      itemsPerPage: itemsPerPage,
                                      columns: gridColumnsPerPage,
                                      rows: gridRowsPerPage)
        } else {
            // cachevalid，onlyupdatechangepartial
            let changedAppPaths = apps.map { $0.url.path }
            cacheManager.preloadIcons(for: changedAppPaths)
        }
    }

    private var resolvedLanguage: AppLanguage {
        preferredLanguage == .system ? AppLanguage.resolveSystemDefault() : preferredLanguage
    }

    func localized(_ key: LocalizationKey) -> String {
        LocalizationManager.shared.localized(key, language: resolvedLanguage)
    }

    func localizedLanguageName(for language: AppLanguage) -> String {
        LocalizationManager.shared.languageDisplayName(for: language, displayLanguage: resolvedLanguage)
    }

    // MARK: - Hidden Apps

    @discardableResult
    func hideApp(_ app: AppInfo) -> Bool {
        hideApp(atPath: app.url.path)
    }

    @discardableResult
    func hideApp(at url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return false }
        guard FileManager.default.fileExists(atPath: resolved.path) else { return false }
        return hideApp(atPath: resolved.path)
    }

    @discardableResult
    func hideApp(atPath path: String) -> Bool {
        var didInsert = false
        updateHiddenAppPaths { set in
            if !set.contains(path) {
                set.insert(path)
                didInsert = true
            }
        }
        guard didInsert else { return false }

        removeHiddenAppMetadata(forPath: path)
        items = filteredItemsRemovingHidden(from: items)
        folders = sanitizedFolders(folders)
        applyHiddenFilteringToOpenFolder()
        compactItemsWithinPages()
        removeEmptyPages()
        triggerFolderUpdate()
        triggerGridRefresh()
        updateCacheAfterChanges()
        persistence.saveAllOrder()
        return true
    }

    @discardableResult
    func hideApps(at urls: [URL]) -> Bool {
        let resolvedPaths = urls.compactMap { url -> String? in
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
            guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }
            return resolved.path
        }

        guard !resolvedPaths.isEmpty else { return false }

        var inserted = false
        updateHiddenAppPaths { set in
            for path in resolvedPaths {
                if !set.contains(path) {
                    set.insert(path)
                    inserted = true
                }
            }
        }

        guard inserted else { return false }

        for path in resolvedPaths {
            removeHiddenAppMetadata(forPath: path)
        }

        items = filteredItemsRemovingHidden(from: items)
        folders = sanitizedFolders(folders)
        applyHiddenFilteringToOpenFolder()
        compactItemsWithinPages()
        removeEmptyPages()
        triggerFolderUpdate()
        triggerGridRefresh()
        updateCacheAfterChanges()
        persistence.saveAllOrder()
        return true
    }

    func unhideApp(path: String) {
        var didRemove = false
        updateHiddenAppPaths { set in
            if set.remove(path) != nil {
                didRemove = true
            }
        }
        guard didRemove else { return }

        guard FileManager.default.fileExists(atPath: path) else {
            triggerFolderUpdate()
            triggerGridRefresh()
            return
        }

        let url = URL(fileURLWithPath: path)
        let info = appInfo(from: url)
        if !apps.contains(info) {
            apps.append(info)
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        persistence.rebuildItems()
        folders = sanitizedFolders(folders)
        applyHiddenFilteringToOpenFolder()
        compactItemsWithinPages()
        triggerFolderUpdate()
        triggerGridRefresh()
        updateCacheAfterChanges()
        persistence.saveAllOrder()
    }

    private func removeHiddenAppMetadata(forPath path: String) {
        if let index = apps.firstIndex(where: { $0.url.path == path }) {
            apps.remove(at: index)
        }
    }

    func pruneHiddenAppsFromAppList() {
        guard !hiddenAppPaths.isEmpty else { return }
        apps.removeAll { hiddenAppPaths.contains($0.url.path) }
    }

    private func applyHiddenFilteringToOpenFolder() {
        guard let folder = openFolder else { return }
        let filtered = filteredFolderRemovingHidden(from: folder)
        if filtered.apps.count != folder.apps.count {
            openFolder = filtered
        }
    }

    func sanitizedFolders(_ input: [FolderInfo]) -> [FolderInfo] {
        guard !hiddenAppPaths.isEmpty else { return input }
        let hidden = hiddenAppPaths
        var result: [FolderInfo] = []
        result.reserveCapacity(input.count)
        var didChange = false
        for folder in input {
            let filtered = filteredFolderRemovingHidden(from: folder, hidden: hidden)
            if filtered.apps.count != folder.apps.count {
                didChange = true
            }
            result.append(filtered)
        }
        return didChange ? result : input
    }

    func filteredItemsRemovingHidden(from input: [LaunchpadItem]) -> [LaunchpadItem] {
        guard !hiddenAppPaths.isEmpty else { return input }
        let hidden = hiddenAppPaths
        var result: [LaunchpadItem] = []
        result.reserveCapacity(input.count)
        var didChange = false
        for item in input {
            switch item {
            case .app(let app):
                if hidden.contains(app.url.path) {
                    didChange = true
                    continue
                }
                result.append(.app(app))
            case .missingApp(let placeholder):
                let rawPath = placeholder.bundlePath
                let path = standardizedFilePath(rawPath)
                if hidden.contains(rawPath) || hidden.contains(path) {
                    didChange = true
                    continue
                }
                result.append(.missingApp(placeholder))
            case .folder(let folder):
                let filteredFolder = filteredFolderRemovingHidden(from: folder, hidden: hidden)
                if filteredFolder.apps.count != folder.apps.count {
                    didChange = true
                }
                result.append(.folder(filteredFolder))
            case .empty:
                result.append(item)
            }
        }
        return didChange ? result : input
    }

    private func filteredFolderRemovingHidden(from folder: FolderInfo) -> FolderInfo {
        filteredFolderRemovingHidden(from: folder, hidden: hiddenAppPaths)
    }

    private func filteredFolderRemovingHidden(from folder: FolderInfo, hidden: Set<String>) -> FolderInfo {
        guard !hidden.isEmpty else { return folder }
        let filteredApps = folder.apps.filter { !hidden.contains($0.url.path) }
        if filteredApps.count == folder.apps.count {
            return folder
        }
        var copy = folder
        copy.apps = filteredApps
        return copy
    }

    // MARK: - Custom Titles

    func customTitle(for app: AppInfo) -> String {
        customTitles[app.url.path] ?? ""
    }

    func setCustomTitle(_ rawValue: String, for app: AppInfo) {
        let key = app.url.path
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            if customTitles[key] != nil {
                var updated = customTitles
                updated.removeValue(forKey: key)
                customTitles = updated
                applyCustomTitleOverride(for: app.url, title: nil)
            }
            return
        }

        if customTitles[key] == trimmed { return }

        var updated = customTitles
        updated[key] = trimmed
        customTitles = updated
        applyCustomTitleOverride(for: app.url, title: trimmed)
    }

    func clearCustomTitle(for app: AppInfo) {
        setCustomTitle("", for: app)
    }

    func appInfoForCustomTitle(path: String) -> AppInfo {
        if let existing = apps.first(where: { $0.url.path == path }) {
            return existing
        }
        for folder in folders {
            if let existing = folder.apps.first(where: { $0.url.path == path }) {
                return existing
            }
        }

        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            return AppInfo.from(url: url,
                                customTitle: customTitles[path],
                                loadIcon: PerformanceMode.current == .full)
        }

        let fallbackName = customTitles[path] ?? url.deletingPathExtension().lastPathComponent
        let icon: NSImage
        if PerformanceMode.current == .full {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = AppInfo.transparentPlaceholderIcon
        }
        return AppInfo(name: fallbackName, icon: icon, url: url)
    }

    func defaultDisplayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return url.deletingPathExtension().lastPathComponent
        }
        return AppInfo.from(url: url, customTitle: nil, loadIcon: PerformanceMode.current == .full).name
    }

    var uninstallToolAppURL: URL? {
        let trimmed = uninstallToolAppPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard resolved.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
        return resolved
    }

    var uninstallToolAppDisplayName: String {
        guard let url = uninstallToolAppURL else { return "" }
        return AppInfo.from(url: url, loadIcon: false).name
    }

    var uninstallToolBundleIdentifier: String {
        guard let url = uninstallToolAppURL else { return "" }
        return Bundle(url: url)?.bundleIdentifier ?? ""
    }

    var uninstallToolVersionText: String {
        guard let url = uninstallToolAppURL,
              let info = Bundle(url: url)?.infoDictionary else { return "" }

        let shortVersion = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let buildVersion = (info["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !shortVersion.isEmpty && !buildVersion.isEmpty && shortVersion != buildVersion {
            return "\(shortVersion) (\(buildVersion))"
        }
        if !shortVersion.isEmpty { return shortVersion }
        return buildVersion
    }

    var uninstallToolAppIcon: NSImage {
        let icon: NSImage
        if let url = uninstallToolAppURL {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            if let appType = UTType(filenameExtension: "app") {
                icon = NSWorkspace.shared.icon(for: appType)
            } else {
                icon = NSWorkspace.shared.icon(forFile: "/Applications")
            }
        }
        let rendered = (icon.copy() as? NSImage) ?? icon
        rendered.size = NSSize(width: 64, height: 64)
        return rendered
    }

    var uninstallToolConfiguredButMissing: Bool {
        let trimmed = uninstallToolAppPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && uninstallToolAppURL == nil
    }

    @discardableResult
    func setUninstallToolApplication(url: URL?) -> Bool {
        guard let url else {
            uninstallToolAppPath = ""
            return true
        }

        let resolved = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard resolved.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return false }
        uninstallToolAppPath = resolved.path
        return true
    }

    @discardableResult
    func openConfiguredUninstallTool() -> Bool {
        guard let helper = uninstallToolAppURL else { return false }
        return NSWorkspace.shared.open(helper)
    }

    @discardableResult
    func openConfiguredUninstallTool(for app: AppInfo) -> Bool {
        guard let helper = uninstallToolAppURL else { return false }
        let target = app.url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([target], withApplicationAt: helper, configuration: configuration) { _, _ in }
        return true
    }

    @discardableResult
    func ensureCustomTitleEntry(for url: URL) -> AppInfo? {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.pathExtension.lowercased() == "app" else { return nil }
        guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }

        let info = appInfo(from: resolved)
        if customTitles[resolved.path] == nil {
            setCustomTitle(info.name, for: info)
        } else {
            applyCustomTitleOverride(for: resolved, title: customTitles[resolved.path])
        }
        return info
    }

    private func applyCustomTitleOverride(for url: URL, title: String?) {
        let info = AppInfo.from(url: url, customTitle: title, loadIcon: PerformanceMode.current == .full)
        var changed = false

        if let index = apps.firstIndex(where: { $0.url == url }) {
            apps[index] = info
            changed = true
        }

        for folderIndex in folders.indices {
            var folder = folders[folderIndex]
            var folderChanged = false
            for appIndex in folder.apps.indices where folder.apps[appIndex].url == url {
                folder.apps[appIndex] = info
                folderChanged = true
            }
            if folderChanged {
                folders[folderIndex] = folder
                changed = true
            }
        }

        for itemIndex in items.indices {
            switch items[itemIndex] {
            case .app(let app) where app.url == url:
                items[itemIndex] = .app(info)
                changed = true
            case .app:
                break
            case .folder(var folder):
                var folderChanged = false
                for appIndex in folder.apps.indices where folder.apps[appIndex].url == url {
                    folder.apps[appIndex] = info
                    folderChanged = true
                }
                if folderChanged {
                    items[itemIndex] = .folder(folder)
                    changed = true
                }
            case .empty:
                break
            case .missingApp:
                break
            }
        }

        if changed {
            triggerFolderUpdate()
            triggerGridRefresh()
            scheduleCustomTitleCacheRefresh()
        }
    }

    private func scheduleCustomTitleCacheRefresh() {
        customTitleRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cacheManager.refreshCache(from: self.apps,
                                           items: self.items,
                                           itemsPerPage: self.itemsPerPage,
                                           columns: self.gridColumnsPerPage,
                                           rows: self.gridRowsPerPage)
        }
        customTitleRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func setCustomAppIcon(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url),
              let normalized = AppStore.normalizedIconImage(from: image),
              let data = AppStore.pngData(from: normalized) else {
            return false
        }
        do {
            try data.write(to: customIconFileURL, options: .atomic)
            hasCustomAppIcon = true
            currentAppIcon = normalized
            return true
        } catch {
            return false
        }
    }

    func resetCustomAppIcon() {
        try? FileManager.default.removeItem(at: customIconFileURL)
        hasCustomAppIcon = false
        currentAppIcon = defaultAppIcon
    }

    private func applyCurrentAppIcon() {
        let icon = currentAppIcon
        let bundlePath = Bundle.main.bundlePath
        let hasCustomIconFile = FileManager.default.fileExists(atPath: customIconFileURL.path)
        DispatchQueue.main.async {
            let application = NSApplication.shared
            application.applicationIconImage = icon
            application.dockTile.display()

            let workspace = NSWorkspace.shared
            let success: Bool
            if hasCustomIconFile {
                success = workspace.setIcon(icon, forFile: bundlePath, options: [])
            } else {
                success = workspace.setIcon(nil, forFile: bundlePath, options: [])
            }

            if success {
                workspace.noteFileSystemChanged(bundlePath)
            } else {
                NSLog("LaunchNext: Failed to update application bundle icon at %@", bundlePath)
            }
        }
    }

    private static func loadStoredAppIcon(from url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        return image
    }

    private static func normalizedIconImage(from image: NSImage, size: CGFloat = 512) -> NSImage? {
        let targetSize = NSSize(width: size, height: size)
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let scaledSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = NSRect(x: (targetSize.width - scaledSize.width) / 2,
                              y: (targetSize.height - scaledSize.height) / 2,
                              width: scaledSize.width,
                              height: scaledSize.height)

        let output = NSImage(size: targetSize)
        output.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: targetSize)).fill()
        let sourceRect = NSRect(origin: .zero, size: image.size)
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high.rawValue]
        image.draw(in: drawRect, from: sourceRect, operation: .sourceOver, fraction: 1.0, respectFlipped: false, hints: hints)
        output.unlockFocus()
        return output
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        rep.size = image.size
        return rep.representation(using: .png, properties: [:])
    }

    private static func ensureAppSupportDirectory() -> URL {
        let fm = FileManager.default
        if let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let dir = base.appendingPathComponent("LaunchNext", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private static var customIconFileURL: URL {
        ensureAppSupportDirectory().appendingPathComponent("CustomAppIcon.png", isDirectory: false)
    }

    /// folderoperationafterRefresh cache, ensure search functionality works
    func refreshCacheAfterFolderOperation() {
        // directlyrefreshcache，ensureincludeallapp（includingfolderinsideapp)
        cacheManager.refreshCache(from: apps,
                                  items: items,
                                  itemsPerPage: itemsPerPage,
                                  columns: gridColumnsPerPage,
                                  rows: gridRowsPerPage)
        
        // Clear searchinfothis，ensuresearchstatereset
        // this waycanavoidsearchwhenshowoverwhenresults
        if !searchText.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.searchText = ""
            }
        }
    }

    func setGlobalHotKey(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let normalized = modifierFlags.normalizedShortcutFlags
        let configuration = HotKeyConfiguration(keyCode: keyCode, modifierFlags: normalized)
        if globalHotKey != configuration {
            globalHotKey = configuration
        }
    }

    func clearGlobalHotKey() {
        if globalHotKey != nil {
            globalHotKey = nil
        }
    }

    // func setAIOverlayHotKey(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
    //     let normalized = modifierFlags.normalizedShortcutFlags
    //     let configuration = HotKeyConfiguration(keyCode: keyCode, modifierFlags: normalized)
    //     if aiOverlayHotKey != configuration {
    //         aiOverlayHotKey = configuration
    //     }
    // }
    //
    // func clearAIOverlayHotKey() {
    //     if aiOverlayHotKey != nil {
    //         aiOverlayHotKey = nil
    //     }
    // }

    func persistCurrentPageIfNeeded() {
        guard rememberLastPage else { return }
        UserDefaults.standard.set(currentPage, forKey: Self.rememberedPageIndexKey)
    }

    func hotKeyDisplayText(nonePlaceholder: String) -> String {
        guard let config = globalHotKey else { return nonePlaceholder }
        let base = config.displayString
        if config.modifierFlags.isEmpty {
            return base + " • " + localized(.shortcutNoModifierWarning)
        }
        return base
    }

    func syncGlobalHotKeyRegistration() {
        AppDelegate.shared?.updateGlobalHotKey(configuration: globalHotKey)
    }

    // func aiOverlayHotKeyDisplayText(nonePlaceholder: String) -> String {
    //     guard let config = aiOverlayHotKey else { return nonePlaceholder }
    //     let base = config.displayString
    //     if config.modifierFlags.isEmpty {
    //         return base + " • " + localized(.shortcutNoModifierWarning)
    //     }
    //     return base
    // }
    //
    // func syncAIOverlayHotKeyRegistration() {
    //     // AppDelegate.shared?.updateAIOverlayHotKey(configuration: isAIEnabled ? aiOverlayHotKey : nil)
    // }
    
    // MARK: - importapporder/sortfeature
    /// fromJSONdataimportapporder/sort
    func importAppOrderFromJSON(_ jsonData: Data) -> Bool {
        do {
            let importData = try JSONSerialization.jsonObject(with: jsonData, options: [])
            return processImportedData(importData)
        } catch {
            return false
        }
    }

    @discardableResult
    func applyMacOS26PresetLayout() -> Bool {
        let candidates = presetCandidateAppsInCurrentOrder()
        guard !candidates.isEmpty else { return false }

        let candidateByPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0) })
        var unusedPaths = Set(candidates.map(\.path))
        var rebuiltItems: [LaunchpadItem] = []
        rebuiltItems.reserveCapacity(candidates.count + 1)
        var rebuiltFolders: [FolderInfo] = []

        for slot in LayoutPresetCatalog.macOS26Default.slots {
            switch slot {
            case let .app(bundleIdentifiers, aliases):
                guard let matchedPath = matchPresetSlot(bundleIdentifiers: bundleIdentifiers,
                                                        aliases: aliases,
                                                        candidates: candidates,
                                                        unusedPaths: unusedPaths),
                      let matched = candidateByPath[matchedPath] else {
                    continue
                }
                unusedPaths.remove(matchedPath)
                rebuiltItems.append(.app(matched.app))
            case .utilitiesFolder:
                let folderApps = candidates
                    .filter { unusedPaths.contains($0.path) && shouldIncludeInPresetOtherFolder($0) }
                    .map(\.app)

                guard !folderApps.isEmpty else { continue }
                for app in folderApps {
                    unusedPaths.remove(standardizedFilePath(app.url.path))
                }

                let folder = FolderInfo(name: localized(.layoutPresetOtherFolderTitle), apps: folderApps)
                rebuiltFolders.append(folder)
                rebuiltItems.append(.folder(folder))
            }
        }

        let remainingApps = candidates
            .filter { unusedPaths.contains($0.path) }
            .map(\.app)
        rebuiltItems.append(contentsOf: remainingApps.map { .app($0) })

        guard !rebuiltItems.isEmpty else { return false }

        apps = candidates.map(\.app)
        pruneHiddenAppsFromAppList()
        folders = sanitizedFolders(rebuiltFolders)
        items = filteredItemsRemovingHidden(from: rebuiltItems)
        openFolder = nil
        compactItemsWithinPages()
        removeEmptyPages()
        currentPage = 0
        if !searchText.isEmpty { searchText = "" }
        refreshMissingPlaceholders()
        triggerFolderUpdate()
        triggerGridRefresh()
        updateCacheAfterChanges()
        persistence.saveAllOrder()
        return true
    }

    private struct PresetAppCandidate {
        let app: AppInfo
        let path: String
        let bundleIdentifier: String?
        let normalizedNames: Set<String>
    }

    private func presetCandidateAppsInCurrentOrder() -> [PresetAppCandidate] {
        var orderedApps: [AppInfo] = []
        orderedApps.reserveCapacity(items.count + apps.count + folders.reduce(0) { $0 + $1.apps.count })

        for item in items {
            switch item {
            case .app(let app):
                orderedApps.append(app)
            case .folder(let folder):
                orderedApps.append(contentsOf: folder.apps)
            case .empty:
                break
            case .missingApp:
                break
            }
        }
        orderedApps.append(contentsOf: apps)
        for folder in folders {
            orderedApps.append(contentsOf: folder.apps)
        }

        var seenPaths = Set<String>()
        var result: [PresetAppCandidate] = []
        result.reserveCapacity(orderedApps.count)

        for app in orderedApps {
            let path = standardizedFilePath(app.url.path)
            guard !seenPaths.contains(path) else { continue }
            guard !hiddenAppPaths.contains(path) && !hiddenAppPaths.contains(app.url.path) else { continue }
            guard path.lowercased().hasSuffix(".app") else { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            seenPaths.insert(path)
            result.append(presetCandidate(from: app, path: path))
        }

        return result
    }

    private func presetCandidate(from app: AppInfo, path: String) -> PresetAppCandidate {
        let appURL = URL(fileURLWithPath: path)
        let bundle = Bundle(url: appURL)
        let bundleIdentifier = bundle?.bundleIdentifier?.lowercased()

        var nameCandidates: [String] = [
            app.name,
            appURL.deletingPathExtension().lastPathComponent
        ]
        if let bundleDisplayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            nameCandidates.append(bundleDisplayName)
        }
        if let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String {
            nameCandidates.append(bundleName)
        }

        let normalizedNames = Set(nameCandidates.map(normalizedPresetToken).filter { !$0.isEmpty })
        return PresetAppCandidate(app: app,
                                  path: path,
                                  bundleIdentifier: bundleIdentifier,
                                  normalizedNames: normalizedNames)
    }

    private func matchPresetSlot(bundleIdentifiers: [String],
                                 aliases: [String],
                                 candidates: [PresetAppCandidate],
                                 unusedPaths: Set<String>) -> String? {
        let normalizedBundleIDs = Set(bundleIdentifiers.map { $0.lowercased() }.filter { !$0.isEmpty })
        if !normalizedBundleIDs.isEmpty {
            for candidate in candidates where unusedPaths.contains(candidate.path) {
                if let bundleIdentifier = candidate.bundleIdentifier,
                   normalizedBundleIDs.contains(bundleIdentifier) {
                    return candidate.path
                }
            }
        }

        let normalizedAliases = Set(aliases.map(normalizedPresetToken).filter { !$0.isEmpty })
        guard !normalizedAliases.isEmpty else { return nil }

        for candidate in candidates where unusedPaths.contains(candidate.path) {
            if !normalizedAliases.isDisjoint(with: candidate.normalizedNames) {
                return candidate.path
            }
        }

        return nil
    }

    private func normalizedPresetToken(_ rawValue: String) -> String {
        let folded = rawValue.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                      locale: .current)
        let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    private func shouldIncludeInPresetOtherFolder(_ candidate: PresetAppCandidate) -> Bool {
        if isAppInPresetUtilitiesFolders(candidate.path) {
            return true
        }
        let lowerPath = candidate.path.lowercased()
        if LayoutPresetCatalog.otherExtraPathSuffixes.contains(where: { lowerPath.hasSuffix($0) }) {
            return true
        }
        if let bundleIdentifier = candidate.bundleIdentifier,
           LayoutPresetCatalog.otherExtraBundleIDs.contains(bundleIdentifier) {
            return true
        }
        let normalizedAliases = Set(LayoutPresetCatalog.otherExtraAliases.map(normalizedPresetToken))
        return !normalizedAliases.isDisjoint(with: candidate.normalizedNames)
    }

    private func isAppInPresetUtilitiesFolders(_ path: String) -> Bool {
        let normalizedPath = standardizedFilePath(path)
        for root in LayoutPresetCatalog.utilityRootPaths {
            if normalizedPath == root || normalizedPath.hasPrefix(root + "/") {
                return true
            }
        }
        return false
    }

    /// fromnative macOS Launchpad importlayout
    func importFromNativeLaunchpad() async -> (success: Bool, message: String) {
        guard let modelContext = self.modelContext else {
            return (false, "datastorenot yetinitialize")
        }

        do {
            let importer = NativeLaunchpadImporter(modelContext: modelContext)
            let result = try importer.importFromNativeLaunchpad()

            // Import successfulafterrefreshappdata
            DispatchQueue.main.async { [weak self] in
                self?.performInitialScanIfNeeded()
                // newversionuse SwiftData unifiedloadentry point
                self?.persistence.loadAllOrder()
                self?.triggerGridRefresh()
            }

            return (true, result.summary)
        } catch {
            return (false, "Import failed: \(error.localizedDescription)")
        }
    }

    /// fromLegacy archive (.lmy/.zip ordirectly db)import
    func importFromLegacyLaunchpadArchive(url: URL) async -> (success: Bool, message: String) {
        guard let modelContext = self.modelContext else {
            return (false, "datastorenot yetinitialize")
        }

        do {
            let importer = NativeLaunchpadImporter(modelContext: modelContext)
            let result = try importer.importFromLegacyArchive(at: url)

            // Import successfulafterrefreshappdata
            DispatchQueue.main.async { [weak self] in
                self?.performInitialScanIfNeeded()
                self?.persistence.loadAllOrder()
                self?.triggerGridRefresh()
            }

            return (true, result.summary)
        } catch {
            return (false, "Import failed: \(error.localizedDescription)")
        }
    }

    /// Process import dataand rebuild app layout
    private func processImportedData(_ importData: Any) -> Bool {
        guard let data = importData as? [String: Any],
              let pagesData = data["pages"] as? [[String: Any]] else {
            return false
        }
        
        // buildapppathtoappobjectsmapping
        let appPathMap = Dictionary(uniqueKeysWithValues: apps.map { ($0.url.path, $0) })
        
        // rebuilditemsarray
        var newItems: [LaunchpadItem] = []
        var importedFolders: [FolderInfo] = []
        
        // Processeachone pagedata
        for pageData in pagesData {
            guard let kind = pageData["kind"] as? String,
                  let name = pageData["name"] as? String else { continue }
            
            switch kind {
            case "app":
                if let path = pageData["path"] as? String,
                   let app = appPathMap[path] {
                    newItems.append(.app(app))
                } else {
                    // appmissing，addempty slot
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case "folder":
                if let folderApps = pageData["folderApps"] as? [String],
                   let folderAppPaths = pageData["folderAppPaths"] as? [String] {
                    // rebuildfolder - preferuseapppathfrommatch，ensureaccuracy
                    let folderAppsList = folderAppPaths.compactMap { appPath in
                        // via app path match, this is most accurate approach
                        if let app = apps.first(where: { $0.url.path == appPath }) {
                            return app
                        }
                        // ifpathmatchfailure，tryvianamematch（backupuseapproach)
                        if let appName = folderApps.first(where: { _ in true }), // Getcorrespondingappname
                           let app = apps.first(where: { $0.name == appName }) {
                            return app
                        }
                        return nil
                    }
                    
                    if !folderAppsList.isEmpty {
                        // tryfromexistingfolderinfindmatch，maintainIDconsistent
                        let existingFolder = self.folders.first { existingFolder in
                            existingFolder.name == name &&
                            existingFolder.apps.count == folderAppsList.count &&
                            existingFolder.apps.allSatisfy { app in
                                folderAppsList.contains { $0.id == app.id }
                            }
                        }
                        
                        if let existing = existingFolder {
                            // useexistingfolder，maintainIDconsistent
                            importedFolders.append(existing)
                            newItems.append(.folder(existing))
                        } else {
                            // Createnewfolder
                            let folder = FolderInfo(name: name, apps: folderAppsList)
                            importedFolders.append(folder)
                            newItems.append(.folder(folder))
                        }
                    } else {
                        // folderasnil/empty，addempty slot
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else if let folderApps = pageData["folderApps"] as? [String] {
                    // compatibleoldversion：onlyhasappname，nopathinfo
                    let folderAppsList = folderApps.compactMap { appName in
                        apps.first { $0.name == appName }
                    }
                    
                    if !folderAppsList.isEmpty {
                        // tryfromexistingfolderinfindmatch，maintainIDconsistent
                        let existingFolder = self.folders.first { existingFolder in
                            existingFolder.name == name &&
                            existingFolder.apps.count == folderAppsList.count &&
                            existingFolder.apps.allSatisfy { app in
                                folderAppsList.contains { $0.id == app.id }
                            }
                        }
                        
                        if let existing = existingFolder {
                            // useexistingfolder，maintainIDconsistent
                            importedFolders.append(existing)
                            newItems.append(.folder(existing))
                        } else {
                            // Createnewfolder
                            let folder = FolderInfo(name: name, apps: folderAppsList)
                            importedFolders.append(folder)
                            newItems.append(.folder(folder))
                        }
                    } else {
                        // folderasnil/empty，addempty slot
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // folderdatainvalid，addempty slot
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case "empty slot":
                newItems.append(.empty(UUID().uuidString))
                
            default:
                // not yetknowtype，addempty slot
                newItems.append(.empty(UUID().uuidString))
            }
        }
        
        // Processextraapp（placetoLast page)
        let usedApps = Set(newItems.compactMap { item in
            if case let .app(app) = item { return app }
            return nil
        })
        
        let usedAppsInFolders = Set(importedFolders.flatMap { $0.apps })
        let allUsedApps = usedApps.union(usedAppsInFolders)
        
        let unusedApps = apps.filter { !allUsedApps.contains($0) }
        
        if !unusedApps.isEmpty {
            // calculateneedaddempty slotcount
            let itemsPerPage = self.itemsPerPage
            let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
            let lastPageStart = currentPages * itemsPerPage
            let lastPageEnd = lastPageStart + itemsPerPage
            
            // ensureLast pagehas enoughnil/emptybetween
            while newItems.count < lastPageEnd {
                newItems.append(.empty(UUID().uuidString))
            }
            
            // not yetuseappaddtoLast page
            for (index, app) in unusedApps.enumerated() {
                let insertIndex = lastPageStart + index
                if insertIndex < newItems.count {
                    newItems[insertIndex] = .app(app)
                } else {
                    newItems.append(.app(app))
                }
            }
            
            // ensureLast pagealsoiscomplete
            let finalPageCount = newItems.count
            let finalPages = (finalPageCount + itemsPerPage - 1) / itemsPerPage
            let finalLastPageStart = (finalPages - 1) * itemsPerPage
            let finalLastPageEnd = finalLastPageStart + itemsPerPage
            
            // ifLast pagenotcomplete，addempty slot
            while newItems.count < finalLastPageEnd {
                newItems.append(.empty(UUID().uuidString))
            }
        }
        
        // verificationimportdatastructure
        
        // updateappstate
        DispatchQueue.main.async {
            
            // setnewdata
            self.folders = self.sanitizedFolders(importedFolders)
            self.items = self.filteredItemsRemovingHidden(from: newItems)
            
            
            // forceTrigger UI update
            self.triggerFolderUpdate()
            self.triggerGridRefresh()
            
            // savenewlayout
            self.persistence.saveAllOrder()
            
            
            // tempwhennotadjustusepagefill，maintainimportoriginalorder
            // ifneedfill，caninuseuserManualoperationaftertrigger
        }
        
        return true
    }
    
    /// verificationimportdatacompleteity
    func validateImportData(_ jsonData: Data) -> (isValid: Bool, message: String) {
        do {
            let importData = try JSONSerialization.jsonObject(with: jsonData, options: [])
            guard let data = importData as? [String: Any] else {
                return (false, "dataformatinvalid")
            }
            
            guard let pagesData = data["pages"] as? [[String: Any]] else {
                return (false, "missingpagedata")
            }
            
            let totalPages = data["totalPages"] as? Int ?? 0
            let totalItems = data["totalItems"] as? Int ?? 0
            
            if pagesData.isEmpty {
                return (false, "nofoundappdata")
            }
            
            return (true, "dataverificationvia，shared\(totalPages)page，\(totalItems)itemitem ")
        } catch {
            return (false, "JSONParse failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Update checkfeature (routed to UpdateChecker)

    func checkForUpdates() { updateChecker.checkForUpdates() }
    func sendTestUpdateNotification() { updateChecker.sendTestUpdateNotification() }
    func launchUpdater(for release: UpdateRelease) { updateChecker.launchUpdater(for: release) }
    func openUpdaterConfigFile() { updateChecker.openUpdaterConfigFile() }
    func scheduleAutomaticUpdateCheck() { updateChecker.scheduleAutomaticUpdateCheck() }
}

// MARK: - AppStoreServiceDelegate Conformance

extension AppStore: AppStoreServiceDelegate {
    // State reads
    var currentApps: [AppInfo] { apps }
    var currentFolders: [FolderInfo] { folders }
    var currentItems: [LaunchpadItem] { items }
    var currentHiddenAppPaths: Set<String> { hiddenAppPaths }
    var currentMissingPlaceholders: [String: MissingAppPlaceholder] { missingPlaceholders }
    var currentModelContext: ModelContext? { modelContext }
    var currentItemsPerPage: Int { itemsPerPage }

    // State writes
    func applyScanResults(_ apps: [AppInfo],
                          missing: [String: MissingAppPlaceholder],
                          hidden: Set<String>) {
        self.apps = apps
        self.missingPlaceholders = missing
        self.hiddenAppPaths = hidden
    }

    func applyOrderedItems(_ items: [LaunchpadItem], folders: [FolderInfo]) {
        self.items = items
        self.folders = folders
    }

    func applyFolderChanges(_ folders: [FolderInfo], items: [LaunchpadItem]) {
        self.folders = folders
        self.items = items
    }

    func applyUpdateState(_ state: UpdateState) {
        self.updateState = state
    }

    // UI Triggers
    func triggerObjectWillChange() {
        objectWillChange.send()
    }

    // triggerGridRefresh, triggerFolderUpdate, refreshCacheAfterFolderOperation
    // already exist as methods on AppStore and satisfy the protocol requirements

    // Layout Helpers
    func compactItemsWithinPagesReturning() -> [LaunchpadItem] {
        compactItemsWithinPages()
        return items
    }

    func removeEmptyPagesReturning() -> [LaunchpadItem] {
        removeEmptyPages()
        return items
    }

    // filteredItemsRemovingHidden and sanitizedFolders already exist on AppStore

    // Cross-Manager Routing
    func persistenceSaveAllOrder() {
        persistence.saveAllOrder()
    }

    func persistenceLoadAllOrder() {
        persistence.loadAllOrder()
    }

    func persistenceRebuildItems() {
        persistence.rebuildItems()
    }

    // Persistence Helpers: removableSourcePath, updateMissingPlaceholder,
    // clearMissingPlaceholder, appInfo, standardizedFilePath, placeholderAppInfo,
    // pruneHiddenAppsFromAppList, refreshMissingPlaceholders already exist on AppStore
}

extension NSEvent.ModifierFlags {
    static let shortcutComponents: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var normalizedShortcutFlags: NSEvent.ModifierFlags {
        intersection(.deviceIndependentFlagsMask).intersection(Self.shortcutComponents)
    }

    var carbonFlags: UInt32 {
        var value: UInt32 = 0
        if contains(.command) { value |= UInt32(cmdKey) }
        if contains(.option) { value |= UInt32(optionKey) }
        if contains(.control) { value |= UInt32(controlKey) }
        if contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    var displaySymbols: [String] {
        var symbols: [String] = []
        if contains(.control) { symbols.append("⌃") }
        if contains(.option) { symbols.append("⌥") }
        if contains(.shift) { symbols.append("⇧") }
        if contains(.command) { symbols.append("⌘") }
        return symbols
    }
}
