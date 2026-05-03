import LaunchNextCore
import Foundation

@MainActor
final class AppImportService {
    weak var delegate: AppStoreServiceDelegate?

    init(delegate: AppStoreServiceDelegate) {
        self.delegate = delegate
    }

    // MARK: - JSON Import

    func importAppOrderFromJSON(_ jsonData: Data) -> Bool {
        do {
            let importData = try JSONSerialization.jsonObject(with: jsonData, options: [])
            return processImportedData(importData)
        } catch {
            return false
        }
    }

    func validateImportData(_ jsonData: Data) -> (isValid: Bool, message: String) {
        do {
            let importData = try JSONSerialization.jsonObject(with: jsonData, options: [])
            guard let data = importData as? [String: Any] else {
                return (false, "Invalid JSON structure")
            }
            guard let pagesData = data["pages"] as? [[String: Any]] else {
                return (false, "Missing pages data")
            }
            let totalPages = data["totalPages"] as? Int ?? 0
            let totalItems = data["totalItems"] as? Int ?? 0
            return (true, "Found \(pagesData.count) pages, \(totalItems) items (header: \(totalPages) pages)")
        } catch {
            return (false, "JSON parse error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func processImportedData(_ importData: Any) -> Bool {
        guard let delegate,
              let data = importData as? [String: Any],
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
                if let folderAppPaths = pageData["folderAppPaths"] as? [String] {
                    let folderAppsList = folderAppPaths.compactMap { appPath -> AppInfo? in
                        if let app = apps.first(where: { $0.url.path == appPath }) {
                            return app
                        }
                        return nil
                    }

                    if !folderAppsList.isEmpty {
                        let existingFolder = delegate.currentFolders.first { existingFolder in
                            existingFolder.name == name &&
                            existingFolder.apps.count == folderAppsList.count &&
                            existingFolder.apps.allSatisfy { app in
                                folderAppsList.contains { $0.id == app.id }
                            }
                        }

                        if let existing = existingFolder {
                            importedFolders.append(existing)
                            newItems.append(.folder(existing))
                        } else {
                            let folder = FolderInfo(name: name, apps: folderAppsList)
                            importedFolders.append(folder)
                            newItems.append(.folder(folder))
                        }
                    } else {
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else if let folderApps = pageData["folderApps"] as? [String] {
                    let folderAppsList = folderApps.compactMap { appName in
                        apps.first { $0.name == appName }
                    }

                    if !folderAppsList.isEmpty {
                        let existingFolder = delegate.currentFolders.first { existingFolder in
                            existingFolder.name == name &&
                            existingFolder.apps.count == folderAppsList.count &&
                            existingFolder.apps.allSatisfy { app in
                                folderAppsList.contains { $0.id == app.id }
                            }
                        }

                        if let existing = existingFolder {
                            importedFolders.append(existing)
                            newItems.append(.folder(existing))
                        } else {
                            let folder = FolderInfo(name: name, apps: folderAppsList)
                            importedFolders.append(folder)
                            newItems.append(.folder(folder))
                        }
                    } else {
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    newItems.append(.empty(UUID().uuidString))
                }

            case "empty slot":
                newItems.append(.empty(UUID().uuidString))

            default:
                newItems.append(.empty(UUID().uuidString))
            }
        }

        // Handle extra apps (place on last page)
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

            while newItems.count < lastPageStart + itemsPerPage {
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
        }

        let filteredItems = delegate.filteredItemsRemovingHidden(from: newItems)
        let sanitizedFolders = delegate.sanitizedFolders(importedFolders)
        delegate.applyFolderChanges(sanitizedFolders, items: filteredItems)
        delegate.compactItemsWithinPages()
        delegate.persistenceSaveAllOrder()

        return true
    }
}
