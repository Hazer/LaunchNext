import Foundation
import AppKit
import SwiftData
import SQLite3

/// Import layout directly from macOS native Launchpad database
class NativeLaunchpadImporter {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    static func nativeLaunchpadDatabasePath() throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        task.arguments = ["DARWIN_USER_DIR"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw ImportError.systemError("Failed to get user directory path")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let userDir = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return "/private\(userDir)com.apple.dock.launchpad/db/db"
    }

    static func hasNativeLaunchpadDatabase() -> Bool {
        guard let path = try? nativeLaunchpadDatabasePath() else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    static func hasImportableNativeLaunchpadDatabase() -> Bool {
        guard let path = try? nativeLaunchpadDatabasePath(),
              FileManager.default.fileExists(atPath: path) else { return false }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_close(db) }

        return schemaTableExists(in: db, name: "apps")
            && schemaTableExists(in: db, name: "groups")
            && schemaTableExists(in: db, name: "items")
    }

    private static func schemaTableExists(in db: OpaquePointer?, name: String) -> Bool {
        let query = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        name.withCString { cstr in
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = sqlite3_bind_text(stmt, 1, cstr, -1, SQLITE_TRANSIENT)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) > 0
        }
        return false
    }

    /// fromnative Launchpad database
    func importFromNativeLaunchpad() throws -> ImportResult {
        let nativeLaunchpadDB = try getNativeLaunchpadDatabasePath()

        // Check if database exists and is accessible
        guard FileManager.default.fileExists(atPath: nativeLaunchpadDB) else {
            throw ImportError.databaseNotFound("Native Launchpad database not found")
        }

        // Parse database
        let launchpadData = try parseLaunchpadDatabase(at: nativeLaunchpadDB)

        // Convert and save to LaunchNext format
        let result = try convertAndSave(launchpadData: launchpadData)

        return result
    }

    /// fromImport from specified database path (adapt for legacy apps/groups/items architecture)
    func importFromDatabasePath(_ dbPath: String) throws -> ImportResult {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound("Database not found: \(dbPath)")
        }
        let data = try parseLaunchpadDatabase(at: dbPath)
        return try convertAndSave(launchpadData: data)
    }

    /// fromLegacy archive (.lmy/.zip)import: archive contains SQLite file named db
    func importFromLegacyArchive(at url: URL) throws -> ImportResult {
        let fm = FileManager.default
        let ext = url.pathExtension.lowercased()

        // If directly given a SQLite file
        if ext == "db" {
            return try importFromDatabasePath(url.path)
        }

        // Only supports .lmy/.zip
        guard ext == "lmy" || ext == "zip" else {
            throw ImportError.systemError("Unsupported file type: .\(ext)")
        }

        let tmpDir = fm.temporaryDirectory.appendingPathComponent("LNImport_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // Extract using system unzip
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-o", url.path, "-d", tmpDir.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw ImportError.systemError("Unzip failed")
        }

        let dbPath = tmpDir.appendingPathComponent("db").path
        guard fm.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound("db file not found in archive")
        }

        return try importFromDatabasePath(dbPath)
    }

    // MARK: - Private methods

    /// Getnative Launchpad datadatabase path
    private func getNativeLaunchpadDatabasePath() throws -> String {
        try Self.nativeLaunchpadDatabasePath()
    }

    private func parseLaunchpadDatabase(at dbPath: String) throws -> LaunchpadData {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ImportError.databaseError("Failed to open native Launchpad database")
        }
        defer { sqlite3_close(db) }

        // Print tables in database，For compatibility across macOS versions
        logAllTables(in: db)

        // Quick self-check: verify our three required tables exist
        let hasLegacySchema =
            tableExists(in: db, name: "apps") &&
            tableExists(in: db, name: "groups") &&
            tableExists(in: db, name: "items")
        guard hasLegacySchema else {
            // Currently only legacy schema supported; provide table list to adapt Z*-based schema
            throw ImportError.databaseError("Non-legacy schema detected. Please provide table list for adaptation.")
        }

        // Parse apps
        let apps = try parseApps(from: db)
        print("📱 Found \(apps.count) apps")

        // Parse folders
        let groups = try parseGroups(from: db)
        print("📁 Found \(groups.count) folders")

        // Parse hierarchy structure
        let items = try parseItems(from: db)
        print("🗂 Found \(items.count) layout items")

        return LaunchpadData(apps: apps, groups: groups, items: items)
    }

    // MARK: - Database structure detection
    private func logAllTables(in db: OpaquePointer?) {
        let query = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            var names: [String] = []
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cName = sqlite3_column_text(stmt, 0) {
                    names.append(String(cString: cName))
                }
            }
            print("🧩 Tables in native DB: \(names.joined(separator: ", "))")
        }
    }

    private func tableExists(in db: OpaquePointer?, name: String) -> Bool {
        let query = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        name.withCString { cstr in
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = sqlite3_bind_text(stmt, 1, cstr, -1, SQLITE_TRANSIENT)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_int(stmt, 0)
            return count > 0
        }
        return false
    }

    private func parseApps(from db: OpaquePointer?) throws -> [String: LaunchpadDBApp] {
        var apps: [String: LaunchpadDBApp] = [:]
        let query = "SELECT item_id, title, bundleid, storeid FROM apps"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError.databaseError("Failed to query apps table")
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemId = String(sqlite3_column_int(stmt, 0))

            // Safely get string, handle NULL values
            let title = sqlite3_column_text(stmt, 1) != nil
                ? String(cString: sqlite3_column_text(stmt, 1))
                : "Unknown App"

            let bundleId = sqlite3_column_text(stmt, 2) != nil
                ? String(cString: sqlite3_column_text(stmt, 2))
                : ""

            if bundleId == "com.apple.Maps" || bundleId == "com.apple.Music" {
                print("[Importer][Debug] bundleId=\(bundleId) title=\(title)")
            }

            apps[itemId] = LaunchpadDBApp(
                itemId: itemId,
                title: title,
                bundleId: bundleId
            )
        }

        return apps
    }

    private func parseGroups(from db: OpaquePointer?) throws -> [String: LaunchpadGroup] {
        var groups: [String: LaunchpadGroup] = [:]
        let query = "SELECT item_id, title FROM groups"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError.databaseError("Failed to query groups table")
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemId = String(sqlite3_column_int(stmt, 0))
            let title = sqlite3_column_text(stmt, 1) != nil
                ? String(cString: sqlite3_column_text(stmt, 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : "Untitled"

            groups[itemId] = LaunchpadGroup(
                itemId: itemId,
                title: title.isEmpty ? "Untitled" : title
            )
        }

        return groups
    }

    private func parseItems(from db: OpaquePointer?) throws -> [LaunchpadDBItem] {
        var items: [LaunchpadDBItem] = []
        let query = """
            SELECT rowid, uuid, flags, type, parent_id, ordering
            FROM items
            ORDER BY parent_id, ordering
        """
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError.databaseError("Failed to query items table")
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = String(sqlite3_column_int(stmt, 0))
            let type = sqlite3_column_int(stmt, 3)
            let parentId = sqlite3_column_int(stmt, 4)
            let ordering = sqlite3_column_int(stmt, 5)

            items.append(LaunchpadDBItem(
                rowId: rowId,
                type: Int(type),
                parentId: Int(parentId),
                ordering: Int(ordering)
            ))
        }

        return items
    }

    private func convertAndSave(launchpadData: LaunchpadData) throws -> ImportResult {
        print("🔄 Start converting data...")

        // Build parent-child index first for easier lookup
        var childrenByParent: [Int: [LaunchpadDBItem]] = [:]
        for item in launchpadData.items { childrenByParent[item.parentId, default: []].append(item) }
        for key in childrenByParent.keys { childrenByParent[key]?.sort { $0.ordering < $1.ordering } }

        // 1) Top-level containers (top-level page groups)：parent_id = 1, type = 3
        let topContainers = launchpadData.items
            .filter { $0.type == 3 && $0.parentId == 1 }
            .sorted { $0.ordering < $1.ordering }

        #if DEBUG
        print("🧭 top-layercontainerorder: \(topContainers.map{ $0.rowId }.joined(separator: ", "))")
        #endif

        // Clear existing data
        try clearExistingData()
        print("🗑 Clearing existing layout data")

        var convertedApps = 0
        var convertedFolders = 0
        var failedApps: [String] = []

        // 2) Build page for each top-level container
        for (pageIndex, container) in topContainers.enumerated() {
            let containerId = Int(container.rowId) ?? 0
            let direct = (childrenByParent[containerId] ?? [])
            let directApps = direct.filter { $0.type == 4 }
            let folderPages = direct.filter { $0.type == 2 }

            // Max position for this page = max ordering value of both entry types
            let maxPos = max(directApps.map{ $0.ordering }.max() ?? -1,
                             folderPages.map{ $0.ordering }.max() ?? -1)

            print("📄 Page #\(pageIndex + 1): apps=\(directApps.count), folderPages=\(folderPages.count), maxPos=\(maxPos)")

            var occupied = Set<Int>()

            // 2.1) Place direct apps
            for appItem in directApps {
                if let app = launchpadData.apps[appItem.rowId],
                   let appInfo = findLocalApp(bundleId: app.bundleId, title: app.title) {
                    try saveAppToPosition(appInfo: appInfo, pageIndex: pageIndex, position: appItem.ordering)
                    occupied.insert(appItem.ordering)
                    convertedApps += 1
                } else {
                    try saveEmptySlot(pageIndex: pageIndex, position: appItem.ordering)
                    occupied.insert(appItem.ordering)
                    failedApps.append(launchpadData.apps[appItem.rowId]?.title ?? appItem.rowId)
                }
            }

            // 2.2) Place folders (represented by sub-pages type=2 )
            for page in folderPages {
                let folderNameRaw = (launchpadData.groups[page.rowId]?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let pageId = Int(page.rowId) ?? 0
                let slotContainers = (childrenByParent[pageId] ?? []).filter { $0.type == 3 }
                var folderAppInfos: [AppInfo] = []
                for sc in slotContainers {
                    let scId = Int(sc.rowId) ?? 0
                    for child in (childrenByParent[scId] ?? []) where child.type == 4 {
                        if let app = launchpadData.apps[child.rowId],
                           let info = findLocalApp(bundleId: app.bundleId, title: app.title) {
                            folderAppInfos.append(info)
                        }
                    }
                }

                let finalName: String
                if isPlaceholderFolderTitle(folderNameRaw) {
                    // use DB insideapptitleGenerate
                    var names: [String] = []
                    for sc in slotContainers {
                        let scId = Int(sc.rowId) ?? 0
                        for child in (childrenByParent[scId] ?? []) where child.type == 4 {
                            if let app = launchpadData.apps[child.rowId] {
                                let t = app.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !t.isEmpty { names.append(t) }
                            }
                        }
                    }
                    let top = Array(names.prefix(3))
                    if top.isEmpty { finalName = "Untitled" }
                    else if top.count == 1 { finalName = top[0] }
                    else if top.count == 2 { finalName = top[0] + " + " + top[1] }
                    else { finalName = top[0] + " + " + top[1] + " + …" }
                } else {
                    finalName = folderNameRaw
                }

                try saveFolderToPosition(name: finalName, apps: folderAppInfos, pageIndex: pageIndex, position: page.ordering)
                occupied.insert(page.ordering)
                convertedFolders += 1
            }

            // 2.3) 补齐nil/empty位
            if maxPos >= 0 {
                for pos in 0...maxPos where !occupied.contains(pos) {
                    try saveEmptySlot(pageIndex: pageIndex, position: pos)
                }
            }
        }

        try modelContext.save()
        print("💾 Save completed")

        let result = ImportResult(convertedApps: convertedApps, convertedFolders: convertedFolders, failedApps: failedApps)
        print("✅ Import finished: \(convertedApps) apps, \(convertedFolders) folders")
        if !failedApps.isEmpty { print("⚠️ \(failedApps.count) apps not found: \(failedApps.prefix(5).joined(separator: ", "))") }
        return result
    }

    private func buildHierarchy(from data: LaunchpadData) -> LaunchpadHierarchy {
        // Description（old版 schema structure)：
        // hierarchyrelationas Root(type=1) → TopContainers(type=3) → Pages(type=2) → Slots(type=3) → Apps(type=4)
        // pageorder应当by：TopContainers  ordering，re-byeach TopContainer  Pages  ordering 依time(s)expand。
        // slotorder：by Page directlychilditem Slots(type=3)  ordering。

        // build parent -> children index，for快速find
        var childrenByParent: [Int: [LaunchpadDBItem]] = [:]
        for item in data.items {
            childrenByParent[item.parentId, default: []].append(item)
        }
        for key in childrenByParent.keys {
            childrenByParent[key]?.sort { $0.ordering < $1.ordering }
        }

        // 寻找 Root sectiondot（may存in多 type=1，only取作parent级那些)
        let roots = data.items.filter { $0.type == 1 }
        let rootIds: [Int]
        if roots.isEmpty {
            rootIds = [1] // 兜底：典型old库in root as 1
        } else {
            // by ordering order/sort（若无意义，then自然order)
            rootIds = roots.sorted { $0.ordering < $1.ordering }.map { intValue($0.rowId) }
        }

        // Top-level container（directly隶属于 Root  type=3)
        var topContainers: [(rootIndex: Int, container: LaunchpadDBItem)] = []
        for (idx, rootId) in rootIds.enumerated() {
            let containers = (childrenByParent[rootId] ?? []).filter { $0.type == 3 }
            for c in containers { topContainers.append((rootIndex: idx, container: c)) }
        }
        // only保留“真正承载page”container（itsdirectlychilditeminclude type=2)
        topContainers = topContainers.filter { entry in
            let pid = intValue(entry.container.rowId)
            return (childrenByParent[pid] ?? []).contains(where: { $0.type == 2 })
        }
        // 以 (rootIndex, container.ordering) order/sort，maintaineach Root inside部order
        topContainers.sort { lhs, rhs in
            if lhs.rootIndex == rhs.rootIndex { return lhs.container.ordering < rhs.container.ordering }
            return lhs.rootIndex < rhs.rootIndex
        }
        #if DEBUG
        let tcIds = topContainers.map { $0.container.rowId }
        print("🧭 top-layercontainerorder: \(tcIds.joined(separator: ", "))")
        #endif

        // calculatepageorder：each topContainer  pages(type=2) 依time(s)追加
        var orderedPages: [LaunchpadDBItem] = []
        for entry in topContainers {
            let parentId = intValue(entry.container.rowId)
            let pagesUnder = (childrenByParent[parentId] ?? []).filter { $0.type == 2 }
            orderedPages.append(contentsOf: pagesUnder)
        }
        #if DEBUG
        let pageIds = orderedPages.map { $0.rowId }
        print("🧭 pageorder: \(pageIds.joined(separator: ", "))")
        #endif

        // slot（each页directlychilditem type=3)
        var pages: [LaunchpadPage] = []
        for page in orderedPages {
            let pid = intValue(page.rowId)
            let slots = (childrenByParent[pid] ?? []).filter { $0.type == 3 }
            pages.append(LaunchpadPage(items: slots))
        }

        // folder映射：任意 containerId(type=3) → itschildapp(type=4)
        var slotIdToApps: [String: [LaunchpadDBItem]] = [:]
        for item in data.items where item.type == 4 {
            slotIdToApps[String(item.parentId), default: []].append(item)
        }
        for key in slotIdToApps.keys {
            slotIdToApps[key]?.sort { $0.ordering < $1.ordering }
        }

        return LaunchpadHierarchy(pages: pages, folderItems: slotIdToApps)
    }

    private func intValue(_ s: String) -> Int {
        return Int(s) ?? 0
    }

    private func findLocalApp(bundleId: String, title: String) -> AppInfo? {
        // 优先use NSWorkspace find
        if let appPath = NSWorkspace.shared.absolutePathForApplication(withBundleIdentifier: bundleId) {
            return AppInfo.from(url: URL(fileURLWithPath: appPath),
                                preferredName: title,
                                loadIcon: PerformanceMode.current == .full)
        }

        // 备use方案：in常见pathinsearch
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/Applications/Utilities"
        ]

        for searchPath in searchPaths {
            if let app = searchAppInDirectory(searchPath, bundleId: bundleId, title: title) {
                return app
            }
        }

        return nil
    }

    private func searchAppInDirectory(_ path: String, bundleId: String, title: String) -> AppInfo? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path),
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
            return nil
        }

        for case let url as URL in enumerator {
            if url.pathExtension == "app" {
                if let bundle = Bundle(url: url) {
                    // 精确match bundle ID
                    if bundle.bundleIdentifier == bundleId {
                        return AppInfo.from(url: url,
                                            preferredName: title,
                                            loadIcon: PerformanceMode.current == .full)
                    }
                    // 备use：namematch
                    if let appName = bundle.infoDictionary?["CFBundleName"] as? String,
                       appName == title {
                        return AppInfo.from(url: url,
                                            preferredName: title,
                                            loadIcon: PerformanceMode.current == .full)
                    }
                }
            }
        }

        return nil
    }

    private func findFolderApps(groupId: String, hierarchy: LaunchpadHierarchy, launchpadData: LaunchpadData) -> [AppInfo] {
        let folderItems = hierarchy.folderItems[groupId] ?? []
        var apps: [AppInfo] = []

        for item in folderItems {
            if item.type == 4, // app
               let app = launchpadData.apps[item.rowId],
               let appInfo = findLocalApp(bundleId: app.bundleId, title: app.title) {
                apps.append(appInfo)
            }
        }

        return apps
    }

    private func findSingleApp(inContainerId containerId: String, launchpadData: LaunchpadData, hierarchy: LaunchpadHierarchy) -> AppInfo? {
        // old版 schema：单appstop-layeritem通常是一 type=3 container，
        // its挂着一 type=4 appitem。这in取No.一 app childitem。
        if let items = hierarchy.folderItems[containerId] {
            if let appItem = items.first, let app = launchpadData.apps[appItem.rowId] {
                return findLocalApp(bundleId: app.bundleId, title: app.title)
            }
        }
        return nil
    }

    private func computeFolderName(from apps: [AppInfo]) -> String {
        let names = apps.prefix(3).map { $0.name }
        switch names.count {
        case 0: return "Untitled"
        case 1: return names[0]
        case 2: return names[0] + " + " + names[1]
        default: return names[0] + " + " + names[1] + " + …"
        }
    }

    private func isPlaceholderFolderTitle(_ s: String) -> Bool {
        if s.isEmpty { return true }
        let lower = s.lowercased()
        let placeholders: Set<String> = [
            "untitled",
            "untitled folder",
            "folder",
            "new folder",
            "not yet命name",
            "not yet命namefolder"
        ]
        return placeholders.contains(lower)
    }

    private func computeFolderNameFromDB(groupId: String, launchpadData: LaunchpadData, hierarchy: LaunchpadHierarchy) -> String {
        let items = hierarchy.folderItems[groupId] ?? []
        let titles: [String] = items.compactMap { (child: LaunchpadDBItem) -> String? in
            guard child.type == 4, let app = launchpadData.apps[child.rowId] else { return nil }
            let t = app.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let top = Array(titles.prefix(3))
        if top.isEmpty { return "" }
        if top.count == 1 { return top[0] }
        if top.count == 2 { return top[0] + " + " + top[1] }
        return top[0] + " + " + top[1] + " + …"
    }

    private func clearExistingData() throws {
        let descriptor = FetchDescriptor<PageEntryData>()
        let existingEntries = try modelContext.fetch(descriptor)
        for entry in existingEntries {
            modelContext.delete(entry)
        }
    }

    private func saveAppToPosition(appInfo: AppInfo, pageIndex: Int, position: Int) throws {
        let slotId = "page-\(pageIndex)-pos-\(position)"
        let entry = PageEntryData(
            slotId: slotId,
            pageIndex: pageIndex,
            position: position,
            kind: "app",
            appPath: appInfo.url.path
        )
        modelContext.insert(entry)
    }

    private func saveFolderToPosition(name: String, apps: [AppInfo], pageIndex: Int, position: Int) throws {
        let slotId = "page-\(pageIndex)-pos-\(position)"
        let folderId = UUID().uuidString
        let appPaths = apps.map { $0.url.path }

        let entry = PageEntryData(
            slotId: slotId,
            pageIndex: pageIndex,
            position: position,
            kind: "folder",
            folderId: folderId,
            folderName: name,
            appPaths: appPaths
        )
        modelContext.insert(entry)
    }

    private func saveEmptySlot(pageIndex: Int, position: Int) throws {
        let slotId = "page-\(pageIndex)-pos-\(position)"
        let entry = PageEntryData(
            slotId: slotId,
            pageIndex: pageIndex,
            position: position,
            kind: "empty"
        )
        modelContext.insert(entry)
    }
}

// MARK: - datamodel (reusebefore)

struct LaunchpadData {
    let apps: [String: LaunchpadDBApp]
    let groups: [String: LaunchpadGroup]
    let items: [LaunchpadDBItem]
}

struct LaunchpadDBApp {
    let itemId: String
    let title: String
    let bundleId: String
}

struct LaunchpadGroup {
    let itemId: String
    let title: String
}

struct LaunchpadDBItem {
    let rowId: String
    let type: Int  // 1=root, 2=page, 3=folder, 4=app
    let parentId: Int
    let ordering: Int
}

struct LaunchpadHierarchy {
    let pages: [LaunchpadPage]
    let folderItems: [String: [LaunchpadDBItem]]
}

struct LaunchpadPage {
    let items: [LaunchpadDBItem]
}

struct ImportResult {
    let convertedApps: Int
    let convertedFolders: Int
    let failedApps: [String]

    var summary: String {
        var lines = [
            "✅ Import Completed!",
            "📱 Apps: \(convertedApps)",
            "📁 Folders: \(convertedFolders)"
        ]

        if !failedApps.isEmpty {
            lines.append("⚠️ Not found: \(failedApps.count)")
        }
        
        return lines.joined(separator: "\n")
    }
}

enum ImportError: LocalizedError {
    case databaseNotFound(String)
    case databaseError(String)
    case systemError(String)
    case conversionError(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotFound(let msg):
            return "Database not found: \(msg)"
        case .databaseError(let msg):
            return "Database error: \(msg)"
        case .systemError(let msg):
            return "System error: \(msg)"
        case .conversionError(let msg):
            return "Conversion error: \(msg)"
        }
    }
}

// MARK: - extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
