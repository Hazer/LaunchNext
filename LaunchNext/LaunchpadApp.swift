import LaunchNextCLI
import LaunchNextInput
import LaunchNextCore
import SwiftUI
import AppKit
import SwiftData
import Combine
import QuartzCore
import Carbon
import Carbon.HIToolbox
import CoreServices

extension Notification.Name {
    static let launchpadWindowShown = Notification.Name("LaunchpadWindowShown")
    static let launchpadWindowHidden = Notification.Name("LaunchpadWindowHidden")
}

class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@main
struct LaunchpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings {} }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSGestureRecognizerDelegate {
    static var shared: AppDelegate?

    // let authStore = FileAuthStore()
    private var window: NSWindow?
    private let minimumContentSize = NSSize(width: 800, height: 600)
    private var lastShowAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?
    private var f4HotKeyRef: EventHotKeyRef?
    // private var aiHotKeyRef: EventHotKeyRef?
    private let launchpadHotKeySignature = fourCharCode("LNXK")
    private let f4HotKeySignature = fourCharCode("F4KY")
    // private let aiOverlayHotKeySignature = fourCharCode("AIOV")
    
    let appStore = AppStore()
    var modelContainer: ModelContainer?
    private var cliIPCServer: LaunchNextCLIIPCServer?
    private var didConfigureModelContext = false
    private var isTerminating = false
    private var windowIsVisible = false
    private var isAnimatingWindow = false
    private var pendingShow = false
    private var pendingHide = false
    private var isHeadlessCLIRuntime = false
    private var isHeadlessTUIRuntime = false
    private var isPerformingExternalSystemDrag = false
    private var cliEndpointSocketPath: String?
    private var cliEndpointMonitorTimer: DispatchSourceTimer?
    private var hotCornerMonitor: HotCornerMonitor?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    // Gesture monitor (now uses unified HID-level event tap).
    private var gestureMonitor: GestureMonitor?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        if runHeadlessModeIfRequested() { return }
        guard !isTerminating else { return }

        Self.shared = self
        // let copilotProvider = CopilotProvider(authStore: authStore)
        // LLMProviderRegistry.shared.register(provider: copilotProvider)

        appStore.syncGlobalHotKeyRegistration()
        appStore.updateActivationPolicy()
        setupMenuBarItem()
        registerF4HotKey()
        // appStore.syncAIOverlayHotKeyRegistration()

        SoundManager.shared.bind(appStore: appStore)
        VoiceManager.shared.bind(appStore: appStore)

        let launchedAtLogin = wasLaunchedAsLoginItem()
        let shouldSilentlyLaunch = launchedAtLogin && appStore.settingsStore.isStartOnLogin

        setupWindow(showImmediately: !shouldSilentlyLaunch)
        appStore.performInitialScanIfNeeded()
        appStore.startAutoRescan()
        appStore.startFallbackScanTimer()

        bindAppearancePreference()
        bindControllerPreference()
        bindControllerMenuToggle()
        bindSystemUIVisibility()
        bindMenuBarVisibility()
        bindCLICodePreference()
        bindHotCornerPreference()
        // Experimental gesture wiring entry point.
        // Remove this call if the gesture feature is removed later.
        bindGesturePreference()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyAppearancePreference(self.appStore.settingsStore.appearancePreference)
            self.updateSystemUIVisibility()
        }

        if appStore.settingsStore.isFullscreenMode { updateWindowMode(isFullscreen: true) }
    }

    private func runHeadlessModeIfRequested() -> Bool {
        let parsed = LaunchNextCLIArguments.parse()
        guard parsed.mode != .gui else { return false }

        let needsEndpoint = requiresCLIEndpoint(parsed)
        if needsEndpoint && !appStore.settingsStore.developmentEnableCLICode {
            fputs("Command line interface is disabled.\n", stderr)
            fputs("Make sure \"Command line interface\" is ON in General settings.\n", stderr)
            isTerminating = true
            NSApp.terminate(nil)
            return true
        }

        let context: LaunchNextCLIContext
        var socketPathForEndpoint: String?
        if needsEndpoint {
            guard let socketPath = LaunchNextCLIIPCConfig.socketPath() else {
                fputs("Failed to resolve LaunchNext CLI socket path.\n", stderr)
                isTerminating = true
                NSApp.terminate(nil)
                return true
            }
            socketPathForEndpoint = socketPath
            context = LaunchNextCLIContext(executeRemoteCommand: { request in
                LaunchNextCLIIPCClient.execute(request: request, socketPath: socketPath)
            })
        } else {
            context = LaunchNextCLIContext()
        }

        isHeadlessCLIRuntime = true

        if parsed.mode == .tui {
            isHeadlessTUIRuntime = true
            cliEndpointSocketPath = socketPathForEndpoint
            startCLIEndpointMonitorIfNeeded()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = LaunchNextCLI.run(parsed: parsed, context: context)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.stopCLIEndpointMonitor()
                    self.isTerminating = true
                    NSApp.terminate(nil)
                }
            }
            return true
        }

        _ = LaunchNextCLI.run(parsed: parsed, context: context)
        isTerminating = true
        NSApp.terminate(nil)
        return true
    }

    private func startCLIEndpointMonitorIfNeeded() {
        guard isHeadlessTUIRuntime else { return }
        guard let socketPath = cliEndpointSocketPath else { return }

        stopCLIEndpointMonitor()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.roversx.launchnext.cli.endpoint-monitor"))
        var failureCount = 0
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isHeadlessTUIRuntime, !self.isTerminating else { return }

            let pingResult = LaunchNextCLIIPCClient.execute(
                request: LaunchNextCLIRequest(command: "ping"),
                socketPath: socketPath
            )

            switch pingResult {
            case .success:
                failureCount = 0
            case .failure:
                failureCount += 1
            }

            if failureCount >= 2 {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.isHeadlessTUIRuntime, !self.isTerminating else { return }
                    fputs("LaunchNext GUI disconnected. Exiting TUI process.\n", stderr)
                    self.isTerminating = true
                    NSApp.terminate(nil)
                }
            }
        }
        cliEndpointMonitorTimer = timer
        timer.resume()
    }

    private func stopCLIEndpointMonitor() {
        cliEndpointMonitorTimer?.cancel()
        cliEndpointMonitorTimer = nil
    }

    private func requiresCLIEndpoint(_ parsed: LaunchNextCLIArguments) -> Bool {
        if parsed.mode == .tui {
            return true
        }
        if parsed.mode == .cli {
            return parsed.command == "list" || parsed.command == "snapshot" || parsed.command == "search" || parsed.command == "create-folder" || parsed.command == "move"
        }
        return false
    }

    private func buildCLISnapshotJSON() -> String? {
        let columns = max(appStore.settingsStore.gridColumnsPerPage, 1)
        let rows = max(appStore.settingsStore.gridRowsPerPage, 1)
        let itemsPerPage = max(columns * rows, 1)
        let totalItems = appStore.items.count
        let totalPages = max(1, (totalItems + itemsPerPage - 1) / itemsPerPage)

        var itemEntries: [[String: Any]] = []
        itemEntries.reserveCapacity(totalItems)

        for (index, item) in appStore.items.enumerated() {
            var payload: [String: Any] = [
                "globalIndex": index,
                "pageIndex": index / itemsPerPage,
                "position": index % itemsPerPage
            ]

            switch item {
            case .app(let app):
                payload["kind"] = "app"
                payload["name"] = app.name
                payload["path"] = app.url.path
            case .folder(let folder):
                payload["kind"] = "folder"
                payload["id"] = folder.id
                payload["name"] = folder.name
                payload["apps"] = folder.apps.enumerated().map { (appIndex, app) in
                    [
                        "index": appIndex,
                        "name": app.name,
                        "path": app.url.path
                    ]
                }
            case .empty(let token):
                payload["kind"] = "empty"
                payload["token"] = token
            case .missingApp(let placeholder):
                payload["kind"] = "missingApp"
                payload["name"] = placeholder.displayName
                payload["path"] = placeholder.bundlePath
                if let source = placeholder.removableSource {
                    payload["removableSource"] = source
                }
            }

            itemEntries.append(payload)
        }

        let root: [String: Any] = [
            "snapshotType": "launchNext.layout",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "layout": [
                "columnsPerPage": columns,
                "rowsPerPage": rows,
                "itemsPerPage": itemsPerPage,
                "currentPage": appStore.currentPage,
                "totalItems": totalItems,
                "totalPages": totalPages,
                "fullscreenMode": appStore.settingsStore.isFullscreenMode
            ],
            "hiddenAppPaths": appStore.hiddenAppPaths.sorted(),
            "items": itemEntries
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func configureModelLayerIfNeeded() {
        if modelContainer == nil {
            modelContainer = makePreferredModelContainer() ?? makeFallbackModelContainer()
        }

        guard !didConfigureModelContext, let container = modelContainer else { return }
        appStore.configure(modelContext: container.mainContext)
        didConfigureModelContext = true
    }

    private func makePreferredModelContainer() -> ModelContainer? {
        do {
            let fm = FileManager.default
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let storeDir = appSupport.appendingPathComponent("LaunchNext", isDirectory: true)
            if !fm.fileExists(atPath: storeDir.path) {
                try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
            }
            let storeURL = storeDir.appendingPathComponent("Data.store")
            let configuration = ModelConfiguration(url: storeURL)
            return try ModelContainer(for: TopItemData.self, PageEntryData.self, configurations: configuration)
        } catch {
            return nil
        }
    }

    private func makeFallbackModelContainer() -> ModelContainer? {
        try? ModelContainer(for: TopItemData.self, PageEntryData.self)
    }

    private func bindCLICodePreference() {
        appStore.settingsStore.$developmentEnableCLICode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.updateCLIIPCServer(enabled: enabled)
            }
            .store(in: &cancellables)
    }

    private func bindHotCornerPreference() {
        Publishers.CombineLatest4(
            appStore.settingsStore.$hotCornerEnabled.removeDuplicates(),
            appStore.settingsStore.$hotCornerPosition.removeDuplicates(),
            appStore.settingsStore.$hotCornerTriggerDelay.removeDuplicates(),
            appStore.settingsStore.$hotCornerHitboxSize.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] enabled, position, delay, hitboxSize in
            self?.updateHotCornerMonitor(
                enabled: enabled,
                position: position,
                triggerDelay: delay,
                hitboxSize: hitboxSize
            )
        }
        .store(in: &cancellables)
    }

    private func bindGesturePreference() {
        // Experimental gesture settings are funneled through one Combine pipeline
        // so the monitor can be rebuilt from a single source of truth.
        // If gesture support is removed later, delete this binder together with
        // updateGestureMonitor()/handleGestureTrigger() and the Gesture folder.
        Publishers.CombineLatest3(
            appStore.settingsStore.$gestureEnabled.removeDuplicates(),
            appStore.settingsStore.$gestureCloseOnPinchOut.removeDuplicates(),
            appStore.settingsStore.$gestureTapAction.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] enabled, closeOnPinchOut, tapAction in
            self?.updateGestureMonitor(
                enabled: enabled,
                closeOnPinchOut: closeOnPinchOut,
                tapAction: tapAction
            )
        }
        .store(in: &cancellables)
    }

    private func updateHotCornerMonitor(enabled: Bool,
                                        position: AppStore.HotCornerPosition,
                                        triggerDelay: Double,
                                        hitboxSize: Double) {
        let configuration = HotCornerMonitor.Configuration(
            isEnabled: enabled,
            position: position,
            triggerDelay: triggerDelay,
            hitboxSize: CGFloat(hitboxSize)
        )

        if hotCornerMonitor == nil {
            hotCornerMonitor = HotCornerMonitor(configuration: configuration) { [weak self] in
                DispatchQueue.main.async {
                    self?.handleHotCornerTrigger()
                }
            }
        }

        hotCornerMonitor?.update(configuration: configuration)
    }

    private func handleHotCornerTrigger() {
        guard !isTerminating else { return }
        guard !appStore.isSetting else { return }
        guard !isPerformingExternalSystemDrag else { return }
        guard !isAnimatingWindow else { return }

        if windowIsVisible {
            guard appStore.settingsStore.hotCornerToggleWhenOpen else { return }
            hideWindow()
            return
        }

        showWindow()
    }

    // Bridges Settings state into the gesture monitor.
    private func updateGestureMonitor(enabled: Bool,
                                      closeOnPinchOut: Bool,
                                      tapAction: AppStore.GestureTapAction) {
        let configuration = GestureMonitor.Configuration(
            isEnabled: enabled || tapAction != .off,
            closeOnPinchOutEnabled: closeOnPinchOut,
            tapEnabled: tapAction != .off,
            tapTogglesWindow: tapAction == .toggle
        )

        if gestureMonitor == nil {
            gestureMonitor = GestureMonitor(configuration: configuration) { [weak self] action in
                DispatchQueue.main.async {
                    self?.handleGestureTrigger(action: action)
                }
            }
        }

        gestureMonitor?.update(configuration: configuration)
    }

    // Maps recognized gesture actions onto the existing window flow.
    // Keeping the behavior translation here avoids spreading experimental gesture
    // branches into showWindow()/hideWindow() and makes later rollback simple:
    // remove this handler and the gesture monitor callback wiring.
    private func handleGestureTrigger(action: GestureTriggerAction) {
        guard !isTerminating else { return }
        guard !isPerformingExternalSystemDrag else { return }
        guard !isAnimatingWindow else { return }

        switch action {
        case .open:
            guard !windowIsVisible else { return }
            showWindow()
        case .close:
            guard windowIsVisible else { return }
            hideWindow()
        case .toggle:
            if windowIsVisible {
                hideWindow()
            } else {
                showWindow()
            }
        }
    }

    private func updateCLIIPCServer(enabled: Bool) {
        if !enabled {
            cliIPCServer?.stop()
            return
        }
        guard let socketPath = LaunchNextCLIIPCConfig.socketPath() else { return }

        if cliIPCServer == nil {
            cliIPCServer = LaunchNextCLIIPCServer(socketPath: socketPath) { [weak self] command, arguments in
                guard let self else { return .failure("LaunchNext GUI is unavailable.") }
                return self.handleCLIIPCCommand(command, arguments: arguments)
            }
        }

        do {
            try cliIPCServer?.start()
        } catch {
            NSLog("LaunchNext: Failed to start CLI IPC server: \(error.localizedDescription)")
        }
    }

    private func handleCLIIPCCommand(_ command: String, arguments: [String: String]) -> LaunchNextCLICommandResult {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return runOnMainSync {
            switch normalized {
            case "ping":
                return .success("ok")
            case "list":
                return .success(self.buildCLIListOutput())
            case "snapshot":
                guard let snapshot = self.buildCLISnapshotJSON() else {
                    return .failure("Layout snapshot is unavailable.")
                }
                return .success(snapshot)
            case "search":
                return self.handleCLISearch(arguments)
            case "create-folder":
                return self.handleCLICreateFolder(arguments)
            case "move":
                return self.handleCLIMove(arguments)
            default:
                return .failure("Unsupported CLI command: \(command)")
            }
        }
    }

    private func handleCLISearch(_ arguments: [String: String]) -> LaunchNextCLICommandResult {
        let rawQuery = arguments["query"] ?? ""
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .failure("Missing search query. Use --query <text>.")
        }

        let format = arguments["format"]?.lowercased() ?? "text"
        let wantsJSON = format == "json"
        let requestedLimit = Int(arguments["limit"] ?? "")
        let maxResults = min(max(requestedLimit ?? 50, 1), 500)

        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        }

        let normalizedQuery = normalized(query)
        func matches(_ value: String) -> Bool {
            normalized(value).contains(normalizedQuery)
        }

        var rows: [[String: String]] = []
        rows.reserveCapacity(min(maxResults, 64))

        func appendRow(_ row: [String: String]) -> Bool {
            rows.append(row)
            return rows.count >= maxResults
        }

        searchLoop: for (globalIndex, item) in appStore.items.enumerated() {
            switch item {
            case .app(let app):
                if matches(app.name) || matches(app.url.path) {
                    let shouldStop = appendRow([
                        "kind": "app",
                        "name": app.name,
                        "path": app.url.path,
                        "location": "top-level",
                        "index": String(globalIndex)
                    ])
                    if shouldStop { break searchLoop }
                }
            case .folder(let folder):
                if matches(folder.name) {
                    let shouldStop = appendRow([
                        "kind": "folder",
                        "name": folder.name,
                        "folderID": folder.id,
                        "location": "top-level",
                        "index": String(globalIndex)
                    ])
                    if shouldStop { break searchLoop }
                }

                for (folderIndex, app) in folder.apps.enumerated() {
                    if matches(app.name) || matches(app.url.path) {
                        let shouldStop = appendRow([
                            "kind": "app",
                            "name": app.name,
                            "path": app.url.path,
                            "location": "folder",
                            "folderName": folder.name,
                            "folderID": folder.id,
                            "folderIndex": String(folderIndex)
                        ])
                        if shouldStop { break searchLoop }
                    }
                }
            case .missingApp(let placeholder):
                if matches(placeholder.displayName) || matches(placeholder.bundlePath) {
                    let shouldStop = appendRow([
                        "kind": "missingApp",
                        "name": placeholder.displayName,
                        "path": placeholder.bundlePath,
                        "location": "top-level",
                        "index": String(globalIndex)
                    ])
                    if shouldStop { break searchLoop }
                }
            case .empty:
                continue
            }
        }

        if wantsJSON {
            let payload: [String: Any] = [
                "query": query,
                "returned": rows.count,
                "limit": maxResults,
                "results": rows
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                  let output = String(data: data, encoding: .utf8) else {
                return .failure("Failed to build search JSON output.")
            }
            return .success(output)
        }

        guard !rows.isEmpty else {
            return .success("No matches for \"\(query)\".")
        }

        var lines: [String] = []
        lines.reserveCapacity(rows.count * 4 + 2)
        lines.append("Search query: \"\(query)\"")
        lines.append("Returned \(rows.count) result(s).")
        for (offset, row) in rows.enumerated() {
            let kind = row["kind"] ?? "item"
            let name = row["name"] ?? "(unnamed)"
            lines.append("\(offset + 1). [\(kind)] \(name)")

            if let path = row["path"], !path.isEmpty {
                lines.append("   Path: \(path)")
            }

            if row["location"] == "folder" {
                let folderName = row["folderName"] ?? "(folder)"
                let folderID = row["folderID"] ?? "-"
                let folderIndex = row["folderIndex"] ?? "-"
                lines.append("   Location: folder \"\(folderName)\" (id: \(folderID), index: \(folderIndex))")
            } else {
                let index = row["index"] ?? "-"
                lines.append("   Location: top-level index \(index)")
            }
        }
        return .success(lines.joined(separator: "\n"))
    }

    private func handleCLICreateFolder(_ arguments: [String: String]) -> LaunchNextCLICommandResult {
        if appStore.settingsStore.isLayoutLocked {
            return .failure("Layout is locked. Disable layout lock before using create-folder.")
        }

        guard let rawPathsJSON = arguments["appPathsJSON"], !rawPathsJSON.isEmpty else {
            return .failure("Missing app paths. Use --path multiple times.")
        }
        guard let pathsData = rawPathsJSON.data(using: .utf8),
              let rawPaths = try? JSONDecoder().decode([String].self, from: pathsData) else {
            return .failure("Invalid appPathsJSON payload.")
        }

        var normalizedPaths: [String] = []
        normalizedPaths.reserveCapacity(rawPaths.count)
        var seenPaths = Set<String>()
        for rawPath in rawPaths {
            let normalized = normalizedCLIPath(rawPath)
            if seenPaths.insert(normalized).inserted {
                normalizedPaths.append(normalized)
            }
        }
        if normalizedPaths.count < 2 {
            return .failure("create-folder needs at least two unique app paths.")
        }

        let dryRun = arguments["dryRun"] == "true"
        let destinationIndex: Int? = {
            guard let raw = arguments["destinationIndex"], !raw.isEmpty else { return nil }
            return Int(raw)
        }()
        if arguments["destinationIndex"] != nil, destinationIndex == nil {
            return .failure("Invalid destinationIndex.")
        }
        if let destinationIndex, destinationIndex < 0 {
            return .failure("destinationIndex must be non-negative.")
        }

        let folderName: String? = {
            guard let raw = arguments["folderName"] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        var selectedApps: [AppInfo] = []
        var selectedItems: [[String: Any]] = []
        selectedApps.reserveCapacity(normalizedPaths.count)
        selectedItems.reserveCapacity(normalizedPaths.count)

        for path in normalizedPaths {
            if let topRef = topLevelAppReference(path: path) {
                selectedApps.append(topRef.app)
                selectedItems.append([
                    "name": topRef.app.name,
                    "path": path,
                    "index": topRef.index
                ])
                continue
            }

            if let folderRef = anyFolderAppReference(path: path) {
                return .failure("create-folder only supports top-level apps right now. App is inside folderID \(folderRef.folderID): \(path)")
            }

            return .failure("App is not found at top level: \(path)")
        }

        if dryRun {
            var extra: [String: Any] = [
                "folderName": folderName ?? "Untitled",
                "appCount": selectedApps.count,
                "apps": selectedItems
            ]
            if let destinationIndex {
                extra["destinationIndex"] = destinationIndex
            }
            return .success(buildCLICreateFolderJSON(
                ok: true,
                applied: false,
                dryRun: true,
                summary: "Dry run: create-folder",
                extra: extra
            ))
        }

        let createdFolder = appStore.createFolder(with: selectedApps, name: folderName ?? "Untitled", insertAt: destinationIndex)
        var extra: [String: Any] = [
            "folderID": createdFolder.id,
            "folderName": createdFolder.name,
            "appCount": selectedApps.count,
            "apps": selectedItems
        ]
        if let destinationIndex {
            extra["destinationIndex"] = destinationIndex
        }
        return .success(buildCLICreateFolderJSON(
            ok: true,
            applied: true,
            dryRun: false,
            summary: "Created folder from top-level apps.",
            extra: extra
        ))
    }

    private func handleCLIMove(_ arguments: [String: String]) -> LaunchNextCLICommandResult {
        if appStore.settingsStore.isLayoutLocked {
            return .failure("Layout is locked. Disable layout lock before using move.")
        }

        guard let requestedSourceType = arguments["sourceType"],
              let destinationType = arguments["destinationType"] else {
            return .failure("Invalid move request: missing sourceType or destinationType.")
        }
        guard requestedSourceType == "normal-app" || requestedSourceType == "folder-app" else {
            return .failure("Unsupported sourceType: \(requestedSourceType)")
        }

        let dryRun = arguments["dryRun"] == "true"
        var resolvedArguments = arguments

        // Resolve app source location from path so callers do not need to know whether it is top-level or inside a folder.
        if let rawPath = arguments["sourcePath"] {
            let normalizedPath = normalizedCLIPath(rawPath)
            resolvedArguments["sourcePath"] = normalizedPath

            if let source = topLevelAppReference(path: normalizedPath) {
                if requestedSourceType == "folder-app",
                   let expectedFolderID = arguments["sourceFolderID"],
                   !expectedFolderID.isEmpty {
                    return .failure("sourcePath does not belong to sourceFolderID \(expectedFolderID).")
                }
                resolvedArguments["sourceType"] = "normal-app"
                resolvedArguments.removeValue(forKey: "sourceFolderID")
                resolvedArguments["resolvedSourceIndex"] = String(source.index)
            } else if let source = anyFolderAppReference(path: normalizedPath) {
                if requestedSourceType == "folder-app",
                   let expectedFolderID = arguments["sourceFolderID"],
                   !expectedFolderID.isEmpty,
                   expectedFolderID != source.folderID {
                    return .failure("sourcePath belongs to folderID \(source.folderID), not \(expectedFolderID).")
                }
                resolvedArguments["sourceType"] = "folder-app"
                resolvedArguments["sourceFolderID"] = source.folderID
                resolvedArguments["resolvedSourceIndex"] = String(source.index)
            } else {
                return .failure("Source app is not found: \(normalizedPath)")
            }
        }

        guard let sourceType = resolvedArguments["sourceType"] else {
            return .failure("Invalid move request: sourceType resolution failed.")
        }

        switch (sourceType, destinationType) {
        case ("normal-app", "normal-index"):
            return moveNormalAppToNormalIndex(resolvedArguments, dryRun: dryRun)
        case ("folder-app", "normal-index"):
            return moveFolderAppToNormalIndex(resolvedArguments, dryRun: dryRun)
        case ("normal-app", "folder-append"):
            return moveNormalAppToFolderAppend(resolvedArguments, dryRun: dryRun)
        case ("folder-app", "folder-append"):
            return moveFolderAppToFolderAppend(resolvedArguments, dryRun: dryRun)
        case ("folder-app", "folder-index"):
            return moveFolderAppToFolderIndex(resolvedArguments, dryRun: dryRun)
        default:
            return .failure("Unsupported move combination: \(sourceType) -> \(destinationType)")
        }
    }

    private func moveNormalAppToNormalIndex(_ arguments: [String: String], dryRun: Bool) -> LaunchNextCLICommandResult {
        guard let sourcePathRaw = arguments["sourcePath"] else {
            return .failure("Missing sourcePath.")
        }
        guard let rawDestination = arguments["destinationIndex"], let destinationIndex = Int(rawDestination), destinationIndex >= 0 else {
            return .failure("Invalid destinationIndex.")
        }

        let sourcePath = normalizedCLIPath(sourcePathRaw)
        guard let source = topLevelAppReference(path: sourcePath) else {
            return .failure("Source normal-app is not found at top level.")
        }

        if dryRun {
            return .success(buildCLIMoveJSON(
                ok: true,
                applied: false,
                dryRun: true,
                summary: "Dry run: normal-app -> normal-index",
                extra: [
                    "sourceType": "normal-app",
                    "sourcePath": sourcePath,
                    "sourceIndex": source.index,
                    "destinationType": "normal-index",
                    "destinationIndex": destinationIndex
                ]
            ))
        }

        appStore.moveItemAcrossPagesWithCascade(item: .app(source.app), to: destinationIndex)
        return .success(buildCLIMoveJSON(
            ok: true,
            applied: true,
            dryRun: false,
            summary: "Moved normal-app to normal-index.",
            extra: [
                "sourceType": "normal-app",
                "sourcePath": sourcePath,
                "destinationType": "normal-index",
                "destinationIndex": destinationIndex
            ]
        ))
    }

    private func moveFolderAppToNormalIndex(_ arguments: [String: String], dryRun: Bool) -> LaunchNextCLICommandResult {
        guard let sourceFolderID = arguments["sourceFolderID"], !sourceFolderID.isEmpty else {
            return .failure("Missing sourceFolderID.")
        }
        guard let sourcePathRaw = arguments["sourcePath"] else {
            return .failure("Missing sourcePath.")
        }
        guard let rawDestination = arguments["destinationIndex"], let destinationIndex = Int(rawDestination), destinationIndex >= 0 else {
            return .failure("Invalid destinationIndex.")
        }

        let sourcePath = normalizedCLIPath(sourcePathRaw)
        guard let folderRef = folderReference(id: sourceFolderID) else {
            return .failure("Source folder is not found.")
        }
        guard let folderAppRef = folderAppReference(folder: folderRef.folder, path: sourcePath) else {
            return .failure("Source folder-app is not found.")
        }

        if dryRun {
            return .success(buildCLIMoveJSON(
                ok: true,
                applied: false,
                dryRun: true,
                summary: "Dry run: folder-app -> normal-index",
                extra: [
                    "sourceType": "folder-app",
                    "sourcePath": sourcePath,
                    "sourceFolderID": sourceFolderID,
                    "sourceFolderIndex": folderAppRef.index,
                    "destinationType": "normal-index",
                    "destinationIndex": destinationIndex
                ]
            ))
        }

        appStore.removeAppFromFolder(folderAppRef.app, folder: folderRef.folder)
        guard let topRef = topLevelAppReference(path: sourcePath) else {
            return .failure("Move failed: app did not appear at top level after folder removal.")
        }
        appStore.moveItemAcrossPagesWithCascade(item: .app(topRef.app), to: destinationIndex)

        return .success(buildCLIMoveJSON(
            ok: true,
            applied: true,
            dryRun: false,
            summary: "Moved folder-app to normal-index.",
            extra: [
                "sourceType": "folder-app",
                "sourcePath": sourcePath,
                "sourceFolderID": sourceFolderID,
                "destinationType": "normal-index",
                "destinationIndex": destinationIndex
            ]
        ))
    }

    private func moveNormalAppToFolderAppend(_ arguments: [String: String], dryRun: Bool) -> LaunchNextCLICommandResult {
        guard let sourcePathRaw = arguments["sourcePath"] else {
            return .failure("Missing sourcePath.")
        }
        guard let destinationFolderID = arguments["destinationFolderID"], !destinationFolderID.isEmpty else {
            return .failure("Missing destinationFolderID.")
        }

        let sourcePath = normalizedCLIPath(sourcePathRaw)
        guard let source = topLevelAppReference(path: sourcePath) else {
            return .failure("Source normal-app is not found at top level.")
        }
        guard let destinationFolder = folderReference(id: destinationFolderID)?.folder else {
            return .failure("Destination folder is not found.")
        }

        if dryRun {
            return .success(buildCLIMoveJSON(
                ok: true,
                applied: false,
                dryRun: true,
                summary: "Dry run: normal-app -> folder-append",
                extra: [
                    "sourceType": "normal-app",
                    "sourcePath": sourcePath,
                    "sourceIndex": source.index,
                    "destinationType": "folder-append",
                    "destinationFolderID": destinationFolderID,
                    "destinationFolderAppCount": destinationFolder.apps.count
                ]
            ))
        }

        appStore.addAppToFolder(source.app, folder: destinationFolder)
        return .success(buildCLIMoveJSON(
            ok: true,
            applied: true,
            dryRun: false,
            summary: "Moved normal-app into folder (append).",
            extra: [
                "sourceType": "normal-app",
                "sourcePath": sourcePath,
                "destinationType": "folder-append",
                "destinationFolderID": destinationFolderID
            ]
        ))
    }

    private func moveFolderAppToFolderAppend(_ arguments: [String: String], dryRun: Bool) -> LaunchNextCLICommandResult {
        guard let sourceFolderID = arguments["sourceFolderID"], !sourceFolderID.isEmpty else {
            return .failure("Missing sourceFolderID.")
        }
        guard let sourcePathRaw = arguments["sourcePath"] else {
            return .failure("Missing sourcePath.")
        }
        guard let destinationFolderID = arguments["destinationFolderID"], !destinationFolderID.isEmpty else {
            return .failure("Missing destinationFolderID.")
        }

        let sourcePath = normalizedCLIPath(sourcePathRaw)
        guard let sourceFolder = folderReference(id: sourceFolderID)?.folder else {
            return .failure("Source folder is not found.")
        }
        guard let sourceApp = folderAppReference(folder: sourceFolder, path: sourcePath)?.app else {
            return .failure("Source folder-app is not found.")
        }
        guard let destinationFolder = folderReference(id: destinationFolderID)?.folder else {
            return .failure("Destination folder is not found.")
        }

        if dryRun {
            return .success(buildCLIMoveJSON(
                ok: true,
                applied: false,
                dryRun: true,
                summary: "Dry run: folder-app -> folder-append",
                extra: [
                    "sourceType": "folder-app",
                    "sourcePath": sourcePath,
                    "sourceFolderID": sourceFolderID,
                    "destinationType": "folder-append",
                    "destinationFolderID": destinationFolderID
                ]
            ))
        }

        if sourceFolderID == destinationFolderID {
            let targetIndex = max(sourceFolder.apps.count - 1, 0)
            let reordered = reorderFolderApp(folderID: sourceFolderID, appPath: sourcePath, toIndex: targetIndex)
            if !reordered {
                return .failure("Move failed: unable to reorder folder app.")
            }
        } else {
            appStore.removeAppFromFolder(sourceApp, folder: sourceFolder)
            appStore.addAppToFolder(sourceApp, folder: destinationFolder)
        }

        return .success(buildCLIMoveJSON(
            ok: true,
            applied: true,
            dryRun: false,
            summary: "Moved folder-app into destination folder (append).",
            extra: [
                "sourceType": "folder-app",
                "sourcePath": sourcePath,
                "sourceFolderID": sourceFolderID,
                "destinationType": "folder-append",
                "destinationFolderID": destinationFolderID
            ]
        ))
    }

    private func moveFolderAppToFolderIndex(_ arguments: [String: String], dryRun: Bool) -> LaunchNextCLICommandResult {
        guard let sourceFolderID = arguments["sourceFolderID"], !sourceFolderID.isEmpty else {
            return .failure("Missing sourceFolderID.")
        }
        guard let sourcePathRaw = arguments["sourcePath"] else {
            return .failure("Missing sourcePath.")
        }
        guard let destinationFolderID = arguments["destinationFolderID"], !destinationFolderID.isEmpty else {
            return .failure("Missing destinationFolderID.")
        }
        guard let rawDestination = arguments["destinationIndex"], let destinationIndex = Int(rawDestination), destinationIndex >= 0 else {
            return .failure("Invalid destinationIndex.")
        }

        let sourcePath = normalizedCLIPath(sourcePathRaw)
        guard let sourceFolder = folderReference(id: sourceFolderID)?.folder else {
            return .failure("Source folder is not found.")
        }
        guard let sourceAppRef = folderAppReference(folder: sourceFolder, path: sourcePath) else {
            return .failure("Source folder-app is not found.")
        }
        guard let destinationFolder = folderReference(id: destinationFolderID)?.folder else {
            return .failure("Destination folder is not found.")
        }

        if dryRun {
            return .success(buildCLIMoveJSON(
                ok: true,
                applied: false,
                dryRun: true,
                summary: "Dry run: folder-app -> folder-index",
                extra: [
                    "sourceType": "folder-app",
                    "sourcePath": sourcePath,
                    "sourceFolderID": sourceFolderID,
                    "sourceFolderIndex": sourceAppRef.index,
                    "destinationType": "folder-index",
                    "destinationFolderID": destinationFolderID,
                    "destinationIndex": destinationIndex
                ]
            ))
        }

        if sourceFolderID == destinationFolderID {
            let reordered = reorderFolderApp(folderID: sourceFolderID, appPath: sourcePath, toIndex: destinationIndex)
            if !reordered {
                return .failure("Move failed: unable to reorder folder app.")
            }
        } else {
            appStore.removeAppFromFolder(sourceAppRef.app, folder: sourceFolder)
            appStore.addAppToFolder(sourceAppRef.app, folder: destinationFolder)

            let reordered = reorderFolderApp(folderID: destinationFolderID, appPath: sourcePath, toIndex: destinationIndex)
            if !reordered {
                return .failure("Move failed: unable to place app in destination folder index.")
            }
        }

        return .success(buildCLIMoveJSON(
            ok: true,
            applied: true,
            dryRun: false,
            summary: "Moved folder-app to folder-index.",
            extra: [
                "sourceType": "folder-app",
                "sourcePath": sourcePath,
                "sourceFolderID": sourceFolderID,
                "destinationType": "folder-index",
                "destinationFolderID": destinationFolderID,
                "destinationIndex": destinationIndex
            ]
        ))
    }

    private func normalizedCLIPath(_ raw: String) -> String {
        URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func topLevelAppReference(path normalizedPath: String) -> (index: Int, app: AppInfo)? {
        for (index, item) in appStore.items.enumerated() {
            guard case .app(let app) = item else { continue }
            if normalizedCLIPath(app.url.path) == normalizedPath {
                return (index, app)
            }
        }
        return nil
    }

    private func folderReference(id: String) -> (index: Int, folder: FolderInfo)? {
        guard let index = appStore.folders.firstIndex(where: { $0.id == id }) else { return nil }
        return (index, appStore.folders[index])
    }

    private func folderAppReference(folder: FolderInfo, path normalizedPath: String) -> (index: Int, app: AppInfo)? {
        for (index, app) in folder.apps.enumerated() {
            if normalizedCLIPath(app.url.path) == normalizedPath {
                return (index, app)
            }
        }
        return nil
    }

    private func anyFolderAppReference(path normalizedPath: String) -> (folderID: String, index: Int, app: AppInfo)? {
        for folder in appStore.folders {
            if let ref = folderAppReference(folder: folder, path: normalizedPath) {
                return (folder.id, ref.index, ref.app)
            }
        }
        return nil
    }

    private func reorderFolderApp(folderID: String, appPath normalizedPath: String, toIndex: Int) -> Bool {
        guard let folderIndex = appStore.folders.firstIndex(where: { $0.id == folderID }) else { return false }

        var folder = appStore.folders[folderIndex]
        guard let currentIndex = folder.apps.firstIndex(where: { normalizedCLIPath($0.url.path) == normalizedPath }) else {
            return false
        }
        let app = folder.apps.remove(at: currentIndex)
        let clamped = min(max(0, toIndex), folder.apps.count)
        folder.apps.insert(app, at: clamped)

        appStore.folders[folderIndex] = folder
        if appStore.openFolder?.id == folder.id {
            appStore.openFolder = folder
        }
        appStore.notifyFolderContentChanged(folder)
        return true
    }

    private func buildCLIMoveJSON(ok: Bool, applied: Bool, dryRun: Bool, summary: String, extra: [String: Any]) -> String {
        var payload: [String: Any] = [
            "ok": ok,
            "command": "move",
            "applied": applied,
            "dryRun": dryRun,
            "summary": summary
        ]
        payload["layout"] = [
            "totalItems": appStore.items.count,
            "totalFolders": appStore.folders.count,
            "currentPage": appStore.currentPage
        ]
        for (key, value) in extra {
            payload[key] = value
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":\(ok),\"command\":\"move\",\"summary\":\"\(summary)\"}"
        }
        return text
    }

    private func buildCLICreateFolderJSON(ok: Bool, applied: Bool, dryRun: Bool, summary: String, extra: [String: Any]) -> String {
        var payload: [String: Any] = [
            "ok": ok,
            "command": "create-folder",
            "applied": applied,
            "dryRun": dryRun,
            "summary": summary
        ]
        payload["layout"] = [
            "totalItems": appStore.items.count,
            "totalFolders": appStore.folders.count,
            "currentPage": appStore.currentPage
        ]
        for (key, value) in extra {
            payload[key] = value
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":\(ok),\"command\":\"create-folder\",\"summary\":\"\(summary)\"}"
        }
        return text
    }

    private func buildCLIListOutput() -> String {
        guard !appStore.apps.isEmpty else { return "No apps found." }

        var lines: [String] = []
        lines.reserveCapacity(appStore.apps.count * 2 + 1)
        for (index, app) in appStore.apps.enumerated() {
            lines.append("\(index + 1). \(app.name)")
            lines.append("   \(app.url.path)")
        }
        lines.append("Total: \(appStore.apps.count)")
        return lines.joined(separator: "\n")
    }

    private func runOnMainSync<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    // MARK: - Global Hotkey

    func updateGlobalHotKey(configuration: AppStore.HotKeyConfiguration?) {
        unregisterGlobalHotKey()
        guard let configuration else { return }
        registerGlobalHotKey(configuration)
    }

    // func updateAIOverlayHotKey(configuration: AppStore.HotKeyConfiguration?) {
    //     unregisterAIOverlayHotKey()
    //     guard let configuration, appStore.isAIEnabled else { return }
    //     registerAIOverlayHotKey(configuration)
    // }

    private func registerGlobalHotKey(_ configuration: AppStore.HotKeyConfiguration) {
        ensureHotKeyEventHandler()
        let hotKeyID = EventHotKeyID(signature: launchpadHotKeySignature, id: 1)
        let status = RegisterEventHotKey(configuration.keyCodeUInt32,
                                         configuration.carbonModifierFlags,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &hotKeyRef)
        if status != noErr {
            NSLog("LaunchNext: Failed to register launchpad hotkey (status %d)", status)
            hotKeyRef = nil
        }
    }

    // private func registerAIOverlayHotKey(_ configuration: AppStore.HotKeyConfiguration) {
    //     ensureHotKeyEventHandler()
    //     var hotKeyID = EventHotKeyID(signature: aiOverlayHotKeySignature, id: 1)
    //     let status = RegisterEventHotKey(configuration.keyCodeUInt32,
    //                                      configuration.carbonModifierFlags,
    //                                      hotKeyID,
    //                                      GetEventDispatcherTarget(),
    //                                      0,
    //                                      &aiHotKeyRef)
    //     if status != noErr {
    //         NSLog("LaunchNext: Failed to register AI overlay hotkey (status %d)", status)
    //         aiHotKeyRef = nil
    //     }
    // }

    private func unregisterGlobalHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        cleanUpHotKeyEventHandlerIfNeeded()
    }

    // private func unregisterAIOverlayHotKey() {
    //     if let aiHotKeyRef {
    //         UnregisterEventHotKey(aiHotKeyRef)
    //         self.aiHotKeyRef = nil
    //     }
    //     cleanUpHotKeyEventHandlerIfNeeded()
    // }

    private func cleanUpHotKeyEventHandlerIfNeeded() {
        // if hotKeyRef == nil && aiHotKeyRef == nil && f4HotKeyRef == nil, let handler = hotKeyEventHandler {
        if hotKeyRef == nil && f4HotKeyRef == nil, let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
            hotKeyEventHandler = nil
        }
    }

    // MARK: - F4 / Launchpad Key Interception

    /// Finds the system Launchpad symbolic hot key (typically F4) using HIServices.
    private func findLaunchpadSymbolicHotKey() -> (keyCode: UInt32, modifiers: UInt32)? {
        var hotKeys: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&hotKeys)
        guard status == noErr, let cfArray = hotKeys?.takeRetainedValue() else { return nil }
        let array = cfArray as NSArray
        for i in 0..<array.count {
            guard let dict = array[i] as? [String: Any] else { continue }
            guard dict[kHISymbolicHotKeyEnabled as String] as? Bool == true else { continue }
            guard let code = dict[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = dict[kHISymbolicHotKeyModifiers as String] as? Int else { continue }
            // F4 key code is 118 on ANSI keyboards — the standard Launchpad key
            if code == 118 && mods == 0 {
                return (UInt32(code), UInt32(mods))
            }
        }
        return nil
    }

    private func registerF4HotKey() {
        ensureHotKeyEventHandler()
        guard let f4Info = findLaunchpadSymbolicHotKey() else {
            NSLog("LaunchNext: F4/Launchpad symbolic hot key not found")
            return
        }
        let hotKeyID = EventHotKeyID(signature: f4HotKeySignature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            f4Info.keyCode,
            f4Info.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status != noErr {
            NSLog("LaunchNext: Failed to register F4 hotkey (status %d)", status)
        } else {
            f4HotKeyRef = ref
        }
    }

    private func unregisterF4HotKey() {
        if let ref = f4HotKeyRef {
            UnregisterEventHotKey(ref)
            f4HotKeyRef = nil
        }
        cleanUpHotKeyEventHandlerIfNeeded()
    }

    private func ensureHotKeyEventHandler() {
        guard hotKeyEventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), hotKeyEventCallback, 1, &eventType, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &hotKeyEventHandler)
        if status != noErr {
            NSLog("LaunchNext: Failed to install hotkey handler (status %d)", status)
        }
    }

    fileprivate func handleHotKeyEvent(signature: OSType, id: UInt32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch (signature, id) {
            case (self.launchpadHotKeySignature, 1):
                self.toggleWindow()
            case (self.f4HotKeySignature, 1):
                self.toggleWindow()
            // case (self.aiOverlayHotKeySignature, 1):
            //     self.appStore.toggleAIOverlayPreview()
            default:
                break
            }
        }
    }

    private func setupWindow(showImmediately: Bool = true) {
        guard let screen = NSScreen.main else { return }
        let rect = calculateContentRect(for: screen)
        
        window = BorderlessWindow(contentRect: rect, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        window?.delegate = self
        window?.isMovable = false
        window?.level = .floating
        window?.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.hasShadow = true
        window?.contentAspectRatio = NSSize(width: 4, height: 3)
        window?.contentMinSize = minimumContentSize
        window?.minSize = window?.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size ?? minimumContentSize
        
        configureModelLayerIfNeeded()
        if let container = modelContainer {
            window?.contentView = NSHostingView(rootView: LaunchpadView(appStore: appStore).modelContainer(container))
        } else {
            window?.contentView = NSHostingView(rootView: LaunchpadView(appStore: appStore))
        }
        
        applyCornerRadius()
        window?.alphaValue = 0
        window?.contentView?.alphaValue = 0
        windowIsVisible = false

        // Execute first fade-in after initialization
        if showImmediately {
            showWindow()
        }

        // Background click-to-close logic changed to SwiftUI internal implementation, avoiding conflicts with input controls
    }

    private func bindAppearancePreference() {
        appStore.settingsStore.$appearancePreference
            .receive(on: RunLoop.main)
            .sink { [weak self] preference in
                DispatchQueue.main.async {
                    self?.applyAppearancePreference(preference)
                }
            }
            .store(in: &cancellables)
    }

    

    private func bindControllerPreference() {
        appStore.settingsStore.$gameControllerEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { enabled in
                if enabled {
                    ControllerInputManager.shared.start()
                } else {
                    ControllerInputManager.shared.stop()
                }
            }
            .store(in: &cancellables)
    }

    private func bindControllerMenuToggle() {
        ControllerInputManager.shared.commands
            .receive(on: RunLoop.main)
            .sink { [weak self] command in
                guard let self else { return }
                guard case .menu = command else { return }
                guard self.appStore.settingsStore.gameControllerEnabled else { return }

                if self.appStore.settingsStore.gameControllerMenuTogglesLaunchpad {
                    self.toggleWindow()
                } else if self.windowIsVisible {
                    self.hideWindow()
                }
            }
            .store(in: &cancellables)
    }

    private func bindSystemUIVisibility() {
        // fullscreen mode is included because updateWindowLevelForSystemUI()
        // needs to cover the menu bar when both hideMenuBar && isFullscreenMode
        Publishers.CombineLatest3(
            appStore.settingsStore.$hideDock.removeDuplicates(),
            appStore.settingsStore.$hideMenuBar.removeDuplicates(),
            appStore.settingsStore.$isFullscreenMode.removeDuplicates()
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateSystemUIVisibility()
            }
            .store(in: &cancellables)
    }

    private func bindMenuBarVisibility() {
        appStore.settingsStore.$showInMenuBar
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuBarItemVisibility()
            }
            .store(in: &cancellables)
    }

    func updateSystemUIVisibility() {
        let shouldHideDock = appStore.settingsStore.hideDock && windowIsVisible
        let shouldHideMenuBar = appStore.settingsStore.hideMenuBar && windowIsVisible
        var options: NSApplication.PresentationOptions = []
        if shouldHideDock { options.insert(.autoHideDock) }
        if shouldHideMenuBar { options.insert(.autoHideMenuBar) }
        if options != NSApp.presentationOptions {
            NSApp.presentationOptions = options
        }
        updateWindowLevelForSystemUI()
    }

    private func updateWindowLevelForSystemUI() {
        guard let window else { return }
        let shouldCoverMenuBar = appStore.settingsStore.hideMenuBar && appStore.settingsStore.isFullscreenMode && windowIsVisible
        let targetLevel: NSWindow.Level = shouldCoverMenuBar
            ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            : .floating
        if window.level != targetLevel {
            window.level = targetLevel
        }
    }

    // MARK: - Menu Bar Status Item

    func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            if let img = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "LaunchNext") {
                button.image = img.withSymbolConfiguration(config)
            }
            button.action = #selector(menuBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        // Build the menu but do NOT attach it — attaching overrides left click
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Show LaunchNext",
            action: #selector(menuBarShowClicked),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(menuBarSettingsClicked),
            keyEquivalent: ","
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit LaunchNext",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusMenu = menu

        updateMenuBarItemVisibility()
    }

    func updateMenuBarItemVisibility() {
        statusItem?.isVisible = appStore.settingsStore.showInMenuBar
    }

    @objc func menuBarClicked(_ sender: Any) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .leftMouseUp:
            if windowIsVisible {
                hideWindow()
            } else {
                showWindow()
            }
        case .rightMouseUp:
            // Temporarily attach menu, trigger display, then detach
            statusItem?.menu = statusMenu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        default:
            break
        }
    }

    @objc func menuBarShowClicked() {
        showWindow()
    }

    @objc func menuBarSettingsClicked() {
        appStore.isSetting = true
        if !windowIsVisible { showWindow() }
    }

    private func wasLaunchedAsLoginItem() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        guard event.eventID == kAEOpenApplication else { return false }
        guard let descriptor = event.paramDescriptor(forKeyword: keyAEPropData) else { return false }
        return descriptor.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func applyAppearancePreference(_ preference: AppearancePreference) {
        let appearance = preference.nsAppearance.flatMap { NSAppearance(named: $0) }
        window?.appearance = appearance
        NSApp.appearance = appearance
    }

    func presentLaunchError(_ error: Error, for url: URL) { }
    
    func showWindow() {
        pendingShow = true
        pendingHide = false
        startPendingWindowTransition()
    }
    
    func hideWindow() {
        pendingHide = true
        pendingShow = false
        startPendingWindowTransition()
    }

    func beginExternalSystemDragSession() {
        isPerformingExternalSystemDrag = true
    }

    func endExternalSystemDragSession() {
        guard isPerformingExternalSystemDrag else { return }
        isPerformingExternalSystemDrag = false
        guard windowIsVisible, !appStore.isSetting, let window else { return }
        guard !window.isKeyWindow && !window.isMainWindow else { return }
        hideWindow()
    }

    func toggleWindow() {
        if windowIsVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    // MARK: - Quit with fade
    func quitWithFade() {
        guard !isTerminating else { NSApp.terminate(nil); return }
        isTerminating = true
        if let window = window {
            pendingShow = false
            pendingHide = false
            animateWindow(to: 0, resumePending: false) {
                window.orderOut(nil)
                window.alphaValue = 1
                window.contentView?.alphaValue = 1
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        quitWithFade()
        return .terminateLater
    }

    deinit {
        stopCLIEndpointMonitor()
        cliIPCServer?.stop()
        unregisterGlobalHotKey()
    }
    
    func updateWindowMode(isFullscreen: Bool) {
        guard let window = window else { return }
        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        window.setFrame(isFullscreen ? screen.frame : calculateContentRect(for: screen), display: true)
        window.hasShadow = !isFullscreen
        window.contentAspectRatio = isFullscreen ? NSSize(width: 0, height: 0) : NSSize(width: 4, height: 3)
        applyCornerRadius()
    }
    
    private func applyCornerRadius() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = appStore.settingsStore.isFullscreenMode ? 0 : 30
        contentView.layer?.masksToBounds = true
    }
    
    private func calculateContentRect(for screen: NSScreen) -> NSRect {
        let frame = screen.visibleFrame
        let width = max(frame.width * 0.4, minimumContentSize.width, minimumContentSize.height * 4/3)
        let height = width * 3/4
        return NSRect(x: frame.midX - width/2, y: frame.midY - height/2, width: width, height: height)
    }
    
    private func getCurrentActiveScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    // MARK: - Window animation helpers

    private func startPendingWindowTransition() {
        guard !isAnimatingWindow else { return }
        if pendingShow {
            performShowWindow()
        } else if pendingHide {
            performHideWindow()
        }
    }

    private func performShowWindow() {
        pendingShow = false
        guard let window = window else { return }

        if windowIsVisible && !isAnimatingWindow && window.alphaValue >= 0.99 {
            return
        }

        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        let rect = appStore.settingsStore.isFullscreenMode ? screen.frame : calculateContentRect(for: screen)
        window.setFrame(rect, display: true)
        applyCornerRadius()

        if window.alphaValue <= 0.01 || !windowIsVisible {
            window.alphaValue = 0
            window.contentView?.alphaValue = 0
        }

        window.makeKeyAndOrderFront(nil)
        window.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window.orderFrontRegardless()
        
        // Force window to become key and main window for proper focus
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        window.makeMain()

        lastShowAt = Date()
        windowIsVisible = true
        updateSystemUIVisibility()
        SoundManager.shared.play(.launchpadOpen)
        NotificationCenter.default.post(name: .launchpadWindowShown, object: nil)

        let finalizeShow: () -> Void = {
            self.windowIsVisible = true
            self.updateSystemUIVisibility()
            // Ensure focus after animation completes
            DispatchQueue.main.async {
                self.window?.makeKey()
                self.window?.makeMain()
            }
        }

        if appStore.settingsStore.enableWindowOpenAnimation {
            animateWindow(to: 1) {
                finalizeShow()
            }
        } else {
            window.alphaValue = 1
            window.contentView?.alphaValue = 1
            finalizeShow()
        }
    }

    private func performHideWindow() {
        pendingHide = false
        guard let window = window else { return }

        let shouldPlaySound = windowIsVisible && !isTerminating

        // Release system UI immediately so menu bar/dock come back without waiting for animation
        if windowIsVisible {
            windowIsVisible = false
            updateSystemUIVisibility()
        }

        let finalize: () -> Void = {
            window.orderOut(nil)
            window.alphaValue = 1
            window.contentView?.alphaValue = 1
            self.appStore.isSetting = false
            if self.appStore.settingsStore.rememberLastPage {
                self.appStore.persistCurrentPageIfNeeded()
            } else {
                self.appStore.currentPage = 0
            }
            self.appStore.searchText = ""
            self.appStore.openFolder = nil
            self.appStore.persistence.saveAllOrder()
            NotificationCenter.default.post(name: .launchpadWindowHidden, object: nil)
        }

        if (!windowIsVisible && window.alphaValue <= 0.01) || isTerminating {
            if shouldPlaySound {
                SoundManager.shared.play(.launchpadClose)
            }
            finalize()
            return
        }

        if shouldPlaySound {
            SoundManager.shared.play(.launchpadClose)
        }

        if appStore.settingsStore.enableWindowOpenAnimation {
            animateWindow(to: 0) {
                finalize()
            }
        } else {
            finalize()
        }
    }

    private func animateWindow(to targetAlpha: CGFloat, resumePending: Bool = true, completion: (() -> Void)? = nil) {
        guard let window = window else {
            completion?()
            return
        }

        isAnimatingWindow = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = targetAlpha
            window.contentView?.animator().alphaValue = targetAlpha
        }, completionHandler: {
            window.alphaValue = targetAlpha
            window.contentView?.alphaValue = targetAlpha
            self.isAnimatingWindow = false
            completion?()
            if resumePending {
                self.startPendingWindowTransition()
            }
        })
    }
    
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minSize = minimumContentSize
        let contentSize = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let clamped = NSSize(width: max(contentSize.width, minSize.width), height: max(contentSize.height, minSize.height))
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: clamped)).size
    }
    
    func windowDidResignKey(_ notification: Notification) { autoHideIfNeeded() }
    func windowDidResignMain(_ notification: Notification) { autoHideIfNeeded() }
    private func autoHideIfNeeded() {
        guard !isPerformingExternalSystemDrag else { return }
        guard !appStore.isSetting else { return }
        hideWindow()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isHeadlessCLIRuntime {
            // TUI/CLI helper process should not absorb Dock reopen events.
            isTerminating = true
            NSApp.terminate(nil)
            return true
        }
        if window?.isVisible == true {
            hideWindow()
        } else {
            showWindow()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCLIEndpointMonitor()
        unregisterF4HotKey()
        ControllerInputManager.shared.stop()
    }
    
    private func isInteractiveView(_ view: NSView?) -> Bool {
        var v = view
        while let cur = v {
            if cur is NSControl || cur is NSTextView || cur is NSScrollView || cur is NSVisualEffectView { return true }
            v = cur.superview
        }
        return false
    }

    @objc private func handleBackgroundClick(_ sender: NSClickGestureRecognizer) {
        guard appStore.openFolder == nil && !appStore.isFolderNameEditing else { return }
        guard let view = sender.view else { return }
        let p = sender.location(in: view)
        if let hit = view.hitTest(p), isInteractiveView(hit) { return }
        hideWindow()
    }

    // MARK: - NSGestureRecognizerDelegate
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let contentView = window?.contentView else { return true }
        let point = contentView.convert(event.locationInWindow, from: nil)
        if let hit = contentView.hitTest(point), isInteractiveView(hit) {
            return false
        }
        return true
    }
}

private func hotKeyEventCallback(eventHandlerCallRef: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData, let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    if status != noErr {
        return status
    }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    delegate.handleHotKeyEvent(signature: hotKeyID.signature, id: hotKeyID.id)
    return noErr
}

private func fourCharCode(_ string: String) -> FourCharCode {
    var result: UInt32 = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) | (scalar.value & 0xFF)
    }
    return result
}
