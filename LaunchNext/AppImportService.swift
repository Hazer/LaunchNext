import Foundation
import SwiftData
import LaunchNextCore
import LaunchNextUtilities

@MainActor
final class AppImportService {
    weak var delegate: (any AppStoreServiceDelegate)?
    private let localized: (LocalizationKey) -> String

    init(delegate: any AppStoreServiceDelegate, localized: @escaping (LocalizationKey) -> String) {
        self.delegate = delegate
        self.localized = localized
    }

    // MARK: - JSON Import

    /// Import app order from JSON data and rebuild the layout.
    func importAppOrderFromJSON(_ jsonData: Data) -> Bool {
        do {
            let importData = try JSONSerialization.jsonObject(with: jsonData, options: [])
            return processImportedData(importData)
        } catch {
            return false
        }
    }

    /// Validate import JSON data without applying changes.
    func validateImportData(_ jsonData: Data) -> (isValid: Bool, message: String) {
        do {
            let importData = try JSONSerialization.jsonObject(with: jsonData, options: [])
            guard let data = importData as? [String: Any] else {
                return (false, "Data format invalid")
            }

            guard let pagesData = data["pages"] as? [[String: Any]] else {
                return (false, "Missing page data")
            }

            let totalPages = data["totalPages"] as? Int ?? 0
            let totalItems = data["totalItems"] as? Int ?? 0

            if pagesData.isEmpty {
                return (false, "No app data found")
            }

            return (true, "Data validation passed — \(totalPages) pages, \(totalItems) items")
        } catch {
            return (false, "JSON parse failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Native Launchpad Import

    /// Import layout from the native macOS Launchpad database.
    func importFromNativeLaunchpad() async -> (success: Bool, message: String) {
        guard let delegate,
              let modelContext = delegate.currentModelContext else {
            return (false, "Data store not yet initialized")
        }

        do {
            let importer = NativeLaunchpadImporter(modelContext: modelContext)
            let result = try importer.importFromNativeLaunchpad()

            delegate.persistenceLoadAllOrder()
            delegate.triggerGridRefresh()

            return (true, result.summary)
        } catch {
            return (false, "Import failed: \(error.localizedDescription)")
        }
    }

    /// Import layout from a legacy Launchpad archive file (.lmy/.zip).
    func importFromLegacyLaunchpadArchive(url: URL) async -> (success: Bool, message: String) {
        guard let delegate,
              let modelContext = delegate.currentModelContext else {
            return (false, "Data store not yet initialized")
        }

        do {
            let importer = NativeLaunchpadImporter(modelContext: modelContext)
            let result = try importer.importFromLegacyArchive(at: url)

            delegate.persistenceLoadAllOrder()
            delegate.triggerGridRefresh()

            return (true, result.summary)
        } catch {
            return (false, "Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Preset Layout

    /// Apply the macOS 26 default preset layout to arrange apps.
    @discardableResult
    func applyMacOS26PresetLayout() -> Bool {
        guard let delegate else { return false }
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
                    unusedPaths.remove(delegate.standardizedFilePath(app.url.path))
                }

                let folder = FolderInfo(
                    name: localized(.layoutPresetOtherFolderTitle),
                    apps: folderApps
                )
                rebuiltFolders.append(folder)
                rebuiltItems.append(.folder(folder))
            }
        }

        let remainingApps = candidates
            .filter { unusedPaths.contains($0.path) }
            .map(\.app)
        rebuiltItems.append(contentsOf: remainingApps.map { .app($0) })

        guard !rebuiltItems.isEmpty else { return false }

        let allApps = candidates.map(\.app)
        delegate.pruneHiddenAppsFromAppList()
        let sanitizedFolders = delegate.sanitizedFolders(rebuiltFolders)
        let filteredItems = delegate.filteredItemsRemovingHidden(from: rebuiltItems)

        delegate.applyScanResults(allApps, missing: [:], hidden: delegate.currentHiddenAppPaths)
        delegate.applyOrderedItems(filteredItems, folders: sanitizedFolders)
        delegate.compactItemsWithinPages()
        _ = delegate.removeEmptyPagesReturning()
        delegate.refreshMissingPlaceholders()
        delegate.triggerFolderUpdate()
        delegate.triggerGridRefresh()
        delegate.updateCacheAfterChanges()
        delegate.persistenceSaveAllOrder()

        return true
    }

    // MARK: - Process Imported Data

    /// Process imported data dictionary and rebuild the app layout.
    private func processImportedData(_ importData: Any) -> Bool {
        guard let delegate else { return false }
        guard let data = importData as? [String: Any],
              let pagesData = data["pages"] as? [[String: Any]] else {
            return false
        }

        let apps = delegate.currentApps

        let appPathMap = Dictionary(uniqueKeysWithValues: apps.map { ($0.url.path, $0) })

        var newItems: [LaunchpadItem] = []
        var importedFolders: [FolderInfo] = []
        for pageData in pagesData {
            guard let kind = pageData["kind"] as? String,
                  let name = pageData["name"] as? String else { continue }

            switch kind {
            case "app":
                if let path = pageData["path"] as? String,
                   let app = appPathMap[path] {
                    newItems.append(.app(app))
                } else {
                    newItems.append(.empty(UUID().uuidString))
                }

            case "folder":
                let resolvedApps: [AppInfo]
                if let folderAppPaths = pageData["folderAppPaths"] as? [String],
                   let folderAppNames = pageData["folderApps"] as? [String] {
                    resolvedApps = resolveFolderApps(paths: folderAppPaths, names: folderAppNames, allApps: apps)
                } else if let folderAppNames = pageData["folderApps"] as? [String] {
                    // Legacy format: only app names, no path info
                    resolvedApps = folderAppNames.compactMap { name in apps.first { $0.name == name } }
                } else {
                    resolvedApps = []
                }

                if resolvedApps.isEmpty {
                    newItems.append(.empty(UUID().uuidString))
                } else if let matched = findMatchingExistingFolder(name: name, apps: resolvedApps, in: delegate.currentFolders) {
                    importedFolders.append(matched)
                    newItems.append(.folder(matched))
                } else {
                    let folder = FolderInfo(name: name, apps: resolvedApps)
                    importedFolders.append(folder)
                    newItems.append(.folder(folder))
                }

            case "empty slot":
                newItems.append(.empty(UUID().uuidString))

            default:
                newItems.append(.empty(UUID().uuidString))
            }
        }

        // Place unused apps on the last page
        let usedApps = Set(newItems.compactMap { item in
            if case let .app(app) = item { return app }
            return nil
        })

        let usedAppsInFolders = Set(importedFolders.flatMap { $0.apps })
        let allUsedApps = usedApps.union(usedAppsInFolders)

        let unusedApps = apps.filter { !allUsedApps.contains($0) }

        if !unusedApps.isEmpty {
            let itemsPerPage = delegate.currentItemsPerPage
            let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
            let lastPageStart = currentPages * itemsPerPage
            let lastPageEnd = lastPageStart + itemsPerPage

            while newItems.count < lastPageEnd {
                newItems.append(.empty(UUID().uuidString))
            }

            for (index, app) in unusedApps.enumerated() {
                let insertIndex = lastPageStart + index
                if insertIndex < newItems.count {
                    newItems[insertIndex] = .app(app)
                } else {
                    newItems.append(.app(app))
                }
            }

            let finalPageCount = newItems.count
            let finalPages = (finalPageCount + itemsPerPage - 1) / itemsPerPage
            let finalLastPageStart = (finalPages - 1) * itemsPerPage
            let finalLastPageEnd = finalLastPageStart + itemsPerPage

            while newItems.count < finalLastPageEnd {
                newItems.append(.empty(UUID().uuidString))
            }
        }

        // Apply imported layout
        let sanitizedFolders = delegate.sanitizedFolders(importedFolders)
        let filteredItems = delegate.filteredItemsRemovingHidden(from: newItems)
        delegate.applyOrderedItems(filteredItems, folders: sanitizedFolders)

        delegate.triggerFolderUpdate()
        delegate.triggerGridRefresh()
        delegate.persistenceSaveAllOrder()

        return true
    }

    // MARK: - Preset Layout Helpers

    private struct PresetAppCandidate {
        let app: AppInfo
        let path: String
        let bundleIdentifier: String?
        let normalizedNames: Set<String>
    }

    private func presetCandidateAppsInCurrentOrder() -> [PresetAppCandidate] {
        guard let delegate else { return [] }
        let items = delegate.currentItems
        let apps = delegate.currentApps
        let folders = delegate.currentFolders
        let hiddenPaths = delegate.currentHiddenAppPaths

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
            let path = delegate.standardizedFilePath(app.url.path)
            guard !seenPaths.contains(path) else { continue }
            guard !hiddenPaths.contains(path) && !hiddenPaths.contains(app.url.path) else { continue }
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
        guard let delegate else { return false }
        let normalizedPath = delegate.standardizedFilePath(path)
        for root in LayoutPresetCatalog.utilityRootPaths {
            if normalizedPath == root || normalizedPath.hasPrefix(root + "/") {
                return true
            }
        }
        return false
    }

    // MARK: - Import Folder Helpers

    /// Resolve folder apps by matching paths first, falling back to name match.
    private func resolveFolderApps(paths: [String], names: [String], allApps: [AppInfo]) -> [AppInfo] {
        paths.compactMap { appPath in
            if let app = allApps.first(where: { $0.url.path == appPath }) {
                return app
            }
            if let appName = names.first,
               let app = allApps.first(where: { $0.name == appName }) {
                return app
            }
            return nil
        }
    }

    /// Find an existing folder matching the imported name and app set (preserves folder IDs).
    private func findMatchingExistingFolder(name: String, apps folderApps: [AppInfo], in folders: [FolderInfo]) -> FolderInfo? {
        folders.first { existing in
            existing.name == name &&
            existing.apps.count == folderApps.count &&
            existing.apps.allSatisfy { app in
                folderApps.contains { $0.id == app.id }
            }
        }
    }
}
