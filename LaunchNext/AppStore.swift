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
    static let rememberedPageIndexKey = "rememberedPageIndex"
    // Experimental gesture persistence keys.
    // Safe to remove together with LaunchNext/Gesture/ and gesture UI wiring
    // if the private multitouch feature is dropped later.
    private static let cliShimMarker = "# LaunchNext CLI shim"
    private static let cliPathSnippetHeader = "# >>> LaunchNext CLI >>>"
    private static let cliPathSnippetFooter = "# <<< LaunchNext CLI <<<"
    static let onboardingVersionKey = "onboardingVersionShown"
    static let currentOnboardingVersion = 1
    // private static let aiFeatureEnabledKey = "aiFeatureEnabled"
    // private static let aiOverlayHotKeyKey = "aiOverlayHotKeyConfiguration"

    private static func loadHiddenApps() -> Set<String> {
        if let array = UserDefaults.standard.array(forKey: hiddenAppsKey) as? [String] {
            return Set(array)
        }
        return []
    }

    private static let minColumnsPerPage = 4
    private static let maxColumnsPerPage = 10
    private static let minRowsPerPage = 3
    private static let maxRowsPerPage = 8
    private static let minColumnSpacing: Double = 8
    private static let maxColumnSpacing: Double = 50
    private static let minRowSpacing: Double = 6
    private static let maxRowSpacing: Double = 40
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

    // Development-only override to capture flat screenshots quickly.
    // Reload selected preferences from UserDefaults after an import
    func reloadPreferencesFromDefaults() {
        hiddenAppPaths = AppStore.loadHiddenApps()

        // SettingsStore reads directly from UserDefaults, so we recreate it
        // to pick up the imported values
        let newStore = SettingsStore()

        if let savedSources = UserDefaults.standard.array(forKey: SettingsStore.customAppSourcesKey) as? [String] {
            newStore.customAppSourcePaths = savedSources
        }

        // Apply hidden filtering immediately
        pruneHiddenAppsFromAppList()
        applyHiddenFilteringToOpenFolder()
        compactItemsWithinPages()
        removeEmptyPages()
        triggerFolderUpdate()
        triggerGridRefresh()
    }
    @Published var isSetting = false
    @Published var isInitialLoading = true
    @Published var shouldShowOnboarding: Bool = false
    @Published var currentPage = 0 {
        didSet {
            if currentPage < 0 { currentPage = 0; return }
            if settingsStore.rememberLastPage {
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

    private var searchCancellable: AnyCancellable?

    func setupSearchPipeline() {
        searchCancellable?.cancel()

        searchCancellable = settingsStore.currentSearchStrategy
            .apply(to: $searchText.removeDuplicates())
            .sink { [weak self] value in
                self?.searchQuery = value
            }
    }

    var canConfigureStartOnLogin: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static func screenIdentifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return screen.localizedName
    }

    // MARK: - Scoped Appearance (forwarded to SettingsStore)

    func scopedIconScale(for mode: AppearanceLayoutMode) -> Double {
        settingsStore.scopedIconScale(for: mode)
    }

    func setScopedIconScale(_ value: Double, for mode: AppearanceLayoutMode) {
        settingsStore.setScopedIconScale(value, for: mode)
    }

    func scopedIconLabelFontSize(for mode: AppearanceLayoutMode) -> Double {
        settingsStore.scopedIconLabelFontSize(for: mode)
    }

    func setScopedIconLabelFontSize(_ value: Double, for mode: AppearanceLayoutMode) {
        settingsStore.setScopedIconLabelFontSize(value, for: mode)
    }

    func scopedFolderDropZoneScale(for mode: AppearanceLayoutMode) -> Double {
        settingsStore.scopedFolderDropZoneScale(for: mode)
    }

    func setScopedFolderDropZoneScale(_ value: Double, for mode: AppearanceLayoutMode) {
        settingsStore.setScopedFolderDropZoneScale(value, for: mode)
    }

    func scopedPageIndicatorOffset(for mode: AppearanceLayoutMode) -> Double {
        settingsStore.scopedPageIndicatorOffset(for: mode)
    }

    func setScopedPageIndicatorOffset(_ value: Double, for mode: AppearanceLayoutMode) {
        settingsStore.setScopedPageIndicatorOffset(value, for: mode)
    }

    func scopedPageIndicatorTopPadding(for mode: AppearanceLayoutMode) -> Double {
        settingsStore.scopedPageIndicatorTopPadding(for: mode)
    }

    func setScopedPageIndicatorTopPadding(_ value: Double, for mode: AppearanceLayoutMode) {
        settingsStore.setScopedPageIndicatorTopPadding(value, for: mode)
    }

    func scopedPageIndicatorPerDisplayEnabled(for mode: AppearanceLayoutMode) -> Bool {
        settingsStore.scopedPageIndicatorPerDisplayEnabled(for: mode)
    }

    func setScopedPageIndicatorPerDisplayEnabled(_ enabled: Bool, for mode: AppearanceLayoutMode) {
        settingsStore.setScopedPageIndicatorPerDisplayEnabled(enabled, for: mode)
    }

    func scopedPageIndicatorOverrides(for mode: AppearanceLayoutMode) -> [String: PageIndicatorOverride] {
        settingsStore.scopedPageIndicatorOverrides(for: mode)
    }

    func scopedPageIndicatorOverride(for screenID: String, mode: AppearanceLayoutMode) -> PageIndicatorOverride? {
        settingsStore.scopedPageIndicatorOverrides(for: mode)[screenID]
    }

    func setScopedPageIndicatorOverride(_ override: PageIndicatorOverride?, for screenID: String, mode: AppearanceLayoutMode) {
        if mode == settingsStore.currentAppearanceLayoutMode {
            settingsStore.setPageIndicatorOverride(override, for: screenID)
            return
        }
        settingsStore.updateScopedAppearanceSettings(for: mode) { settings in
            if let override {
                settings.pageIndicatorOverrides[screenID] = override
            } else {
                settings.pageIndicatorOverrides.removeValue(forKey: screenID)
            }
        }
    }

    func applyIndicatorDefaults(to screenID: String, mode: AppearanceLayoutMode) {
        let settings = settingsStore.dualModeAppearanceSettings[mode]
        let override = PageIndicatorOverride(offset: settings.pageIndicatorOffset,
                                             topPadding: settings.pageIndicatorTopPadding)
        setScopedPageIndicatorOverride(override, for: screenID, mode: mode)
    }

    // Icon title display
    // MARK: - Layout Mode

    var layoutStrategy: LayoutStrategy {
        switch settingsStore.layoutMode {
        case .paged: return PagedLayoutStrategy()
        case .vertical: return VerticalLayoutStrategy()
        }
    }

    // MARK: - Dock & Menu Bar

    func updateActivationPolicy() {
        if settingsStore.showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    var iconLabelFontWeightValue: Font.Weight {
        settingsStore.iconLabelFontWeight.fontWeight
    }

    // Update check related properties
    @Published var updateState: UpdateState = .idle

    private(set) lazy var updateChecker = UpdateChecker(
        delegate: self,
        localized: { [weak self] key in self?.localized(key) ?? "" }
    )


    // Experimental gesture settings consumed by LaunchpadApp gesture wiring.
    // Remove these fields together with the gesture monitor/configuration flow
    // if low-level multitouch support is no longer needed.
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
    @Published var handoffDraggingApp: AppInfo? = nil
    @Published var handoffDragScreenLocation: CGPoint? = nil
    
    // Triggers
    @Published var folderUpdateTrigger: UUID = UUID()
    @Published var gridRefreshTrigger: UUID = UUID()
    @Published var iconCacheRefreshTrigger: UUID = UUID()
    
    var modelContext: ModelContext?

    // MARK: - Auto rescan (FSEvents)

    // MARK: - Volume observers
    private var hasPerformedInitialScan: Bool = false
    private var cancellables: Set<AnyCancellable> = []
    var hasAppliedOrderFromStore: Bool = false
    private(set) lazy var persistence = OrderPersistence(delegate: self)
    private(set) lazy var scanner = AppScanner(delegate: self)
    private(set) lazy var folderManager = FolderManager(delegate: self)
    private(set) lazy var importer = AppImportService(delegate: self, localized: { [weak self] key in self?.localized(key) ?? "" })
    let settingsStore = SettingsStore()
    
    // Background refresh queue and throttle
    private let refreshQueue = DispatchQueue(label: "app.store.refresh", qos: .userInitiated)
    private var gridRefreshWorkItem: DispatchWorkItem?
    private var rescanWorkItem: DispatchWorkItem?
    private var customTitleRefreshWorkItem: DispatchWorkItem?
    private let fsEventsQueue = DispatchQueue(label: "app.store.fsevents")
    private let customIconFileURL: URL
    private let defaultAppIcon: NSImage
    private var volumeObservers: [NSObjectProtocol] = []
    private var appearanceRefreshWorkItem: DispatchWorkItem?
    private var lastAppearanceEventAt: TimeInterval = 0

    // Computed properties
    private var itemsPerPage: Int { settingsStore.gridColumnsPerPage * settingsStore.gridRowsPerPage }

    var builtinAppSourcePaths: [String] { systemApplicationSearchPaths }

    private var applicationSearchPaths: [String] {
        var seen = Set<String>()
        var result: [String] = []
        let candidates = systemApplicationSearchPaths + settingsStore.customAppSourcePaths
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
        for source in settingsStore.customAppSourcePaths {
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
        let customSources = settingsStore.customAppSourcePaths.map { normalizeApplicationPath($0) ?? standardizedFilePath($0) }
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


    init() {
        // Performance mode default
        if UserDefaults.standard.object(forKey: PerformanceMode.userDefaultsKey) == nil {
            PerformanceMode.persist(.lean)
        }

        // SettingsStore handles its own init from UserDefaults

        // Custom app icon setup
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
        settingsStore.syncActiveAppearanceProxies(from: settingsStore.currentAppearanceLayoutMode)
        settingsStore.persistLegacyAppearanceProxyValues()

        let sanitizedSources = sanitizedCustomPaths(from: settingsStore.customAppSourcePaths)
        if sanitizedSources != settingsStore.customAppSourcePaths {
            settingsStore.customAppSourcePaths = sanitizedSources
        }

        setupVolumeObservers()

        setupSearchPipeline()

        searchQuery = searchText

        if settingsStore.developmentEnableCLICode {
            installCLICommandIfNeeded()
        } else {
            uninstallCLICommandIfNeeded()
        }

        updateChecker.scheduleAutomaticUpdateCheck()

        if settingsStore.rememberLastPage,
           let savedPageIndex = UserDefaults.standard.object(forKey: Self.rememberedPageIndexKey) as? Int {
            self.currentPage = max(0, savedPageIndex)
        }


        // Wire SettingsStore sideEffects
        settingsStore.sideEffects = self

        // Forward SettingsStore objectWillChange to AppStore
        settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        syncLoginItemStatusFromSystem()
    }

    func syncLoginItemStatusFromSystem() {
        guard #available(macOS 13.0, *) else { return }
        // Access SettingsStore's internal flag via the same pattern
        // Note: SettingsStore has its own loginItemUpdateInProgress guard
        // We directly update the published value to reflect system state
        let systemEnabled = SMAppService.mainApp.status == .enabled
        if settingsStore.isStartOnLogin != systemEnabled {
            // Bypass the didSet registration logic by writing to UserDefaults directly
            // and then updating the @Published var (the didSet will no-op if value matches)
            UserDefaults.standard.set(systemEnabled, forKey: "isStartOnLogin")
            settingsStore.isStartOnLogin = systemEnabled
        }
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

    // Icon scale (relative to cell): default 0.95, recommended range 0.8~1.1
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
        guard settingsStore.isFullscreenMode else { return }

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
        if settingsStore.customAppSourcePaths.contains(where: { normalizeApplicationPath($0) == normalized }) { return false }
        settingsStore.customAppSourcePaths.append(normalized)
        return true
    }

    func removeCustomAppSource(at index: Int) {
        guard settingsStore.customAppSourcePaths.indices.contains(index) else { return }
        let removed = settingsStore.customAppSourcePaths[index]
        purgeMissingPlaceholders(forRemovedSources: [removed])
        settingsStore.customAppSourcePaths.remove(at: index)
    }

    func removeCustomAppSources(at offsets: IndexSet) {
        let removed = offsets.compactMap { offset -> String? in
            guard settingsStore.customAppSourcePaths.indices.contains(offset) else { return nil }
            return settingsStore.customAppSourcePaths[offset]
        }
        purgeMissingPlaceholders(forRemovedSources: removed)
        settingsStore.customAppSourcePaths.remove(atOffsets: offsets)
    }

    func resetCustomAppSources() {
        guard !settingsStore.customAppSourcePaths.isEmpty else { return }
        let removed = settingsStore.customAppSourcePaths
        purgeMissingPlaceholders(forRemovedSources: removed)
        settingsStore.customAppSourcePaths.removeAll()
    }

    func removeCustomAppSource(path: String) {
        guard let normalized = normalizeApplicationPath(path) else { return }
        if let index = settingsStore.customAppSourcePaths.firstIndex(where: { normalizeApplicationPath($0) == normalized }) {
            let removed = settingsStore.customAppSourcePaths[index]
            purgeMissingPlaceholders(forRemovedSources: [removed])
            settingsStore.customAppSourcePaths.remove(at: index)
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

        let relevant = settingsStore.customAppSourcePaths.contains { source in
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
        return folderManager.createFolder(with: apps, name: name, insertAt: insertIndex)
    }

    
    func addAppToFolder(_ app: AppInfo, folder: FolderInfo) {
        folderManager.addAppToFolder(app, folder: folder)
    }

    
    func removeAppFromFolder(_ app: AppInfo, folder: FolderInfo) {
        folderManager.removeAppFromFolder(app, folder: folder)
    }

    
    func renameFolder(_ folder: FolderInfo, newName: String) {
        folderManager.renameFolder(folder, newName: newName)
    }


    @discardableResult
    func dissolveFolder(_ folder: FolderInfo) -> Bool {
        return folderManager.dissolveFolder(folder)
    }

    
    // onekeyresetlayout：full renewscanapp，deleteallfolder、order/sortandemptypadding
    func resetLayout() {
        folderManager.resetLayout()
    }

    
    /// Auto-fill within single page：eachpage .empty slotmovetothepage end，maintainnon-nil/non-emptyitemmutualfororder
    func compactItemsWithinPages() {
        folderManager.compactItemsWithinPages()
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
        folderManager.moveSelectedAppsAcrossPagesWithCascade(appPathsOrdered: appPathsOrdered, to: targetIndex)
    }


    func moveItemAcrossPagesWithCascade(item: LaunchpadItem, to targetIndex: Int) {
        folderManager.moveItemAcrossPagesWithCascade(item: item, to: targetIndex)
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
        guard settingsStore.appearancePreference == .system else { return }
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
        guard settingsStore.pageIndicatorPerDisplayEnabled, let screenID,
              let override = settingsStore.pageIndicatorOverrides[screenID] else {
            return settingsStore.pageIndicatorOffset
        }
        return override.offset
    }

    func effectivePageIndicatorTopPadding(for screenID: String?) -> Double {
        guard settingsStore.pageIndicatorPerDisplayEnabled, let screenID,
              let override = settingsStore.pageIndicatorOverrides[screenID] else {
            return settingsStore.pageIndicatorTopPadding
        }
        return override.topPadding
    }

    func backgroundMaskColor(for colorScheme: ColorScheme) -> Color? {
        guard settingsStore.backgroundMaskEnabled else { return nil }
        let rgba = (colorScheme == .dark) ? settingsStore.backgroundMaskDarkColor : settingsStore.backgroundMaskLightColor
        return rgba.color
    }

    func pageIndicatorOverride(for screenID: String) -> PageIndicatorOverride? {
        settingsStore.pageIndicatorOverrides[screenID]
    }

    func setPageIndicatorOverride(_ override: PageIndicatorOverride?, for screenID: String) {
        var updated = settingsStore.pageIndicatorOverrides
        if let override {
            updated[screenID] = override
        } else {
            updated.removeValue(forKey: screenID)
        }
        settingsStore.pageIndicatorOverrides = updated
        persistPageIndicatorOverrides(updated)
    }

    func applyIndicatorDefaults(to screenID: String) {
        let override = PageIndicatorOverride(offset: settingsStore.pageIndicatorOffset,
                                             topPadding: settingsStore.pageIndicatorTopPadding)
        setPageIndicatorOverride(override, for: screenID)
    }

    func notifyFolderContentChanged(_ folder: FolderInfo) {
        folderManager.notifyFolderContentChanged(folder)
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
        clampCurrentPageWithinBounds()
        gridRefreshTrigger = UUID()
    }
    
    
    private func clampCurrentPageWithinBounds() {
        let perPage = max(itemsPerPage, 1)
        let maxPageIndex = items.isEmpty ? 0 : max(0, (items.count - 1) / perPage)
        if currentPage > maxPageIndex {
            currentPage = maxPageIndex
        }
    }

    // MARK: - drag when auto Create new page

    func createNewPageForDrag() -> Bool {
        return folderManager.createNewPageForDrag()
    }

    
    func cleanupUnusedNewPage() {
        folderManager.cleanupUnusedNewPage()
    }


    // MARK: - autodeletenil/emptyemptypage
    /// autodeletenil/emptyemptypage：deleteallallisemptypaddingpage
    func removeEmptyPages() {
        folderManager.removeEmptyPages()
    }

    // MARK: - export app order/sort feature
    /// exportapporder/sortasJSONformat
    func exportAppOrderAsJSON() -> String? {
        return folderManager.exportAppOrderAsJSON()
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
            "fullscreenMode": settingsStore.isFullscreenMode,
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
        return folderManager.saveExportFileWithDialog(content: content, filename: filename, fileExtension: fileExtension, fileType: fileType)
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
                                      columns: settingsStore.gridColumnsPerPage,
                                      rows: settingsStore.gridRowsPerPage)
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
                                      columns: settingsStore.gridColumnsPerPage,
                                      rows: settingsStore.gridRowsPerPage)
        } else {
            // cachevalid，onlyupdatechangepartial
            let changedAppPaths = apps.map { $0.url.path }
            cacheManager.preloadIcons(for: changedAppPaths)
        }
    }

    private var resolvedLanguage: AppLanguage {
        settingsStore.preferredLanguage == .system ? AppLanguage.resolveSystemDefault() : settingsStore.preferredLanguage
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
        let trimmed = settingsStore.uninstallToolAppPath.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let trimmed = settingsStore.uninstallToolAppPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && uninstallToolAppURL == nil
    }

    @discardableResult
    func setUninstallToolApplication(url: URL?) -> Bool {
        guard let url else {
            settingsStore.uninstallToolAppPath = ""
            return true
        }

        let resolved = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard resolved.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return false }
        settingsStore.uninstallToolAppPath = resolved.path
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
                                           columns: settingsStore.gridColumnsPerPage,
                                           rows: settingsStore.gridRowsPerPage)
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
        folderManager.refreshCacheAfterFolderOperation()
    }


    func setGlobalHotKey(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let normalized = modifierFlags.normalizedShortcutFlags
        let configuration = HotKeyConfiguration(keyCode: keyCode, modifierFlags: normalized)
        if settingsStore.globalHotKey != configuration {
            settingsStore.globalHotKey = configuration
        }
    }

    func clearGlobalHotKey() {
        if settingsStore.globalHotKey != nil {
            settingsStore.globalHotKey = nil
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
        guard settingsStore.rememberLastPage else { return }
        UserDefaults.standard.set(currentPage, forKey: Self.rememberedPageIndexKey)
    }

    func hotKeyDisplayText(nonePlaceholder: String) -> String {
        guard let config = settingsStore.globalHotKey else { return nonePlaceholder }
        let base = config.displayString
        if config.modifierFlags.isEmpty {
            return base + " • " + localized(.shortcutNoModifierWarning)
        }
        return base
    }

    func syncGlobalHotKeyRegistration() {
        AppDelegate.shared?.updateGlobalHotKey(configuration: settingsStore.globalHotKey)
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
        return importer.importAppOrderFromJSON(jsonData)
    }


    @discardableResult
    func applyMacOS26PresetLayout() -> Bool {
        return importer.applyMacOS26PresetLayout()
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
        return await importer.importFromNativeLaunchpad()
    }


    /// fromLegacy archive (.lmy/.zip ordirectly db)import
    func importFromLegacyLaunchpadArchive(url: URL) async -> (success: Bool, message: String) {
        return await importer.importFromLegacyLaunchpadArchive(url: url)
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
        return importer.validateImportData(jsonData)
    }


    // MARK: - Update checkfeature (routed to UpdateChecker)

    func checkForUpdates() { updateChecker.checkForUpdates() }
    func sendTestUpdateNotification() { updateChecker.sendTestUpdateNotification() }
    func launchUpdater(for release: UpdateRelease) { updateChecker.launchUpdater(for: release) }
    func openUpdaterConfigFile() { updateChecker.openUpdaterConfigFile() }
    func scheduleAutomaticUpdateCheck() { updateChecker.scheduleAutomaticUpdateCheck() }
}

// MARK: - AppStoreServiceDelegate Conformance

extension AppStore: AppStoreServiceDelegate, SettingsSideEffects {
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

    // MARK: - SettingsSideEffects Conformance

    func handleGridRefresh() {
        triggerGridRefresh()
    }

    func handleFolderUpdate() {
        triggerFolderUpdate()
    }

    func handleGridConfigurationChange() {
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
                                           columns: self.settingsStore.gridColumnsPerPage,
                                           rows: self.settingsStore.gridRowsPerPage)
            if self.settingsStore.rememberLastPage {
                UserDefaults.standard.set(self.currentPage, forKey: AppStore.rememberedPageIndexKey)
            }
            self.persistence.saveAllOrder()
        }
    }

    func handleRestartAutoRescan() {
        restartAutoRescan()
    }

    func handleScanWithOrderPreservation() {
        scanApplicationsWithOrderPreservation()
    }

    func handleRemoveEmptyPages() {
        removeEmptyPages()
    }

    func handleClearIconCachesForLayoutChange() {
        clearIconCachesForLayoutChange()
    }

    func handleUpdateWindowMode(isFullscreen: Bool) {
        DispatchQueue.main.async {
            if let appDelegate = AppDelegate.shared {
                appDelegate.updateWindowMode(isFullscreen: isFullscreen)
            }
        }
    }

    func handleRegisterStartOnLogin(_ enabled: Bool) {
        settingsStore.isStartOnLogin = enabled
    }

    func handleSetupSearchPipeline() {
        setupSearchPipeline()
    }

    func handleRefresh() {
        refresh()
    }

    func handleUpdateActivationPolicy() {
        updateActivationPolicy()
    }

    func handleSyncGlobalHotKeyRegistration() {
        syncGlobalHotKeyRegistration()
    }

    func handleSyncActiveAppearance() {
        settingsStore.syncActiveAppearanceProxies(from: settingsStore.currentAppearanceLayoutMode)
    }

    func handlePersistLegacyAppearanceProxies() {
        settingsStore.persistLegacyAppearanceProxyValues()
    }

    func handleScheduleSystemAppearanceRefresh() {
        scheduleSystemAppearanceRefresh()
    }

    func handleCompactItemsWithinPages() {
        compactItemsWithinPages()
    }

    func handleTriggerFolderUpdate() {
        triggerFolderUpdate()
    }

    func handleTriggerGridRefresh() {
        triggerGridRefresh()
    }

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
