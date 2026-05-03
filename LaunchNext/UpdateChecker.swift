import LaunchNextCore
import Foundation
import AppKit
@preconcurrency import UserNotifications

final class UpdateChecker {
    private weak var delegate: AppStoreServiceDelegate?

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: URL
        let body: String?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body
        }
    }

    private struct SemanticVersion: Comparable, Equatable {
        private let components: [Int]
        init?(_ rawValue: String) {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            let withoutPrefix = lower.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
            let sanitized = withoutPrefix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first ?? withoutPrefix[...]
            let parts = sanitized.split(separator: ".").map { Int($0) ?? 0 }
            guard !parts.isEmpty else { return nil }
            components = parts
        }
        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            let count = max(lhs.components.count, rhs.components.count)
            for index in 0..<count {
                let left = index < lhs.components.count ? lhs.components[index] : 0
                let right = index < rhs.components.count ? rhs.components[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }

    enum UpdaterLaunchError: Error {
        case missingBinary
        case notExecutable
        case spawnFailed(Error)
    }

    private var autoCheckTimer: DispatchSourceTimer?
    private var autoCheckWorkItem: DispatchWorkItem?
    private var isChecking = false
    private var hasConfiguredUpdateNotifications = false
    private let notificationDelegate: UpdateNotificationDelegate
    private let localized: (LocalizationKey) -> String

    static let updateNotificationCategoryIdentifier = "launchnext.update.category"
    static let updateNotificationDownloadActionIdentifier = "launchnext.update.download"
    private static let lastUpdateCheckKey = "lastUpdateCheckTimestamp"
    private static let automaticUpdateInterval: TimeInterval = 60 * 60 * 24

    private var lastUpdateCheck: Date? {
        get {
            if let timestamp = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? TimeInterval {
                return Date(timeIntervalSince1970: timestamp)
            }
            return nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastUpdateCheckKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastUpdateCheckKey)
            }
        }
    }

    private var autoCheckForUpdates: Bool {
        UserDefaults.standard.object(forKey: "autoCheckForUpdates") as? Bool ?? true
    }

    init(delegate: AppStoreServiceDelegate, localized: @escaping (LocalizationKey) -> String) {
        self.delegate = delegate
        self.localized = localized
        self.notificationDelegate = UpdateNotificationDelegate { url in
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Public Methods

    func checkForUpdates() {
        guard !isChecking else { return }

        lastUpdateCheck = Date()
        isChecking = true
        delegate?.applyUpdateState(.checking)

        Task {
            do {
                let currentVersion = getCurrentVersion()
                let latestRelease = try await fetchLatestRelease()

                await MainActor.run {
                    if let current = SemanticVersion(currentVersion),
                       let latest = SemanticVersion(latestRelease.tagName) {
                        if latest > current {
                            let release = UpdateRelease(
                                version: latestRelease.tagName,
                                url: latestRelease.htmlUrl,
                                notes: latestRelease.body
                            )
                            delegate?.applyUpdateState(.updateAvailable(release))
                            presentUpdateAlert(for: release)
                        } else {
                            delegate?.applyUpdateState(.upToDate(latest: latestRelease.tagName))
                        }
                    } else {
                        delegate?.applyUpdateState(.failed(localized(.versionParseError)))
                        presentUpdateFailureAlert(localized(.versionParseError))
                    }
                    isChecking = false
                }
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    delegate?.applyUpdateState(.failed(message))
                    presentUpdateFailureAlert(message)
                    isChecking = false
                }
            }
        }
    }

    func sendTestUpdateNotification() {
        enqueueUpdateNotification(
            title: localized(.updateAvailable),
            body: "\(localized(.newVersion)) 9.9.9-test",
            releaseURL: URL(string: "https://closex.org/launchnext/")
        )
    }

    func launchUpdater(for release: UpdateRelease) {
        let alert = NSAlert()
        alert.messageText = localized(.updaterConfirmTitle)
        alert.informativeText = localized(.updaterConfirmMessage)
        alert.alertStyle = .informational
        alert.addButton(withTitle: localized(.downloadUpdate))
        alert.addButton(withTitle: localized(.cancel))

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try startUpdaterProcess(tag: release.version)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                AppDelegate.shared?.quitWithFade()
            }
        } catch {
            presentUpdaterLaunchFailure(error)
        }
    }

    func openUpdaterConfigFile() {
        let fm = FileManager.default
        let baseDirectory = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("LaunchNext")
            .appendingPathComponent("updates", isDirectory: true)
        let configURL = baseDirectory.appendingPathComponent("config.json", isDirectory: false)
        let supportedLanguages = ["de", "en", "es", "fr", "it", "hi", "ja", "ko", "ru", "vi", "zh"]
        let defaultConfig: [String: Any] = [
            "language": "en",
            "supported_languages": supportedLanguages
        ]

        do {
            if !fm.fileExists(atPath: baseDirectory.path) {
                try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: configURL.path) {
                let data = try JSONSerialization.data(withJSONObject: defaultConfig, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: configURL)
            } else {
                let attributes = try fm.attributesOfItem(atPath: configURL.path)
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                if size == 0 {
                    let data = try JSONSerialization.data(withJSONObject: defaultConfig, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: configURL)
                }
            }
            NSWorkspace.shared.open(configURL)
        } catch {
            presentUpdateFailureAlert(error.localizedDescription)
        }
    }

    func scheduleAutomaticUpdateCheck() {
        autoCheckTimer?.cancel()
        autoCheckTimer = nil
        autoCheckWorkItem?.cancel()
        autoCheckWorkItem = nil

        guard autoCheckForUpdates else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.performAutomaticUpdateCheckIfNeeded()
        }
        autoCheckWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + Self.automaticUpdateInterval,
                       repeating: Self.automaticUpdateInterval)
        timer.setEventHandler { [weak self] in
            self?.performAutomaticUpdateCheckIfNeeded()
        }
        timer.activate()
        autoCheckTimer = timer
    }

    func cancelAutoCheck() {
        autoCheckTimer?.cancel()
        autoCheckTimer = nil
        autoCheckWorkItem?.cancel()
        autoCheckWorkItem = nil
    }

    // MARK: - Private Methods

    private func performAutomaticUpdateCheckIfNeeded() {
        guard autoCheckForUpdates else { return }
        let now = Date()
        if let last = lastUpdateCheck, now.timeIntervalSince(last) < Self.automaticUpdateInterval {
            return
        }
        checkForUpdates()
    }

    private func getCurrentVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/RoversX/LaunchNext/releases/latest")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    @MainActor
    private func presentUpdateAlert(for release: UpdateRelease) {
        enqueueUpdateNotification(
            title: localized(.updateAvailable),
            body: "\(localized(.newVersion)) \(release.version)",
            releaseURL: release.url
        )
    }

    @MainActor
    private func presentUpdateFailureAlert(_ message: String) {
        enqueueUpdateNotification(
            title: localized(.updateCheckFailed),
            body: message,
            releaseURL: nil
        )
    }

    @MainActor
    private func ensureUpdateNotificationSetup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate

        guard !hasConfiguredUpdateNotifications else { return }

        let downloadAction = UNNotificationAction(
            identifier: Self.updateNotificationDownloadActionIdentifier,
            title: localized(.downloadUpdate),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.updateNotificationCategoryIdentifier,
            actions: [downloadAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        hasConfiguredUpdateNotifications = true
    }

    @MainActor
    private func enqueueUpdateNotification(title: String, body: String, releaseURL: URL?) {
        ensureUpdateNotificationSetup()

        let releaseURLString = releaseURL?.absoluteString
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let deliverNotification = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                if let releaseURLString {
                    content.categoryIdentifier = Self.updateNotificationCategoryIdentifier
                    content.userInfo = ["releaseURL": releaseURLString]
                }

                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(request) { _ in }
            }

            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    guard granted else { return }
                    deliverNotification()
                }
            case .authorized, .provisional, .ephemeral:
                deliverNotification()
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func startUpdaterProcess(tag: String) throws {
        guard let updaterURL = Bundle.main.url(
            forResource: "SwiftUpdater",
            withExtension: nil,
            subdirectory: "Updater"
        ) else {
            throw UpdaterLaunchError.missingBinary
        }

        guard FileManager.default.isExecutableFile(atPath: updaterURL.path) else {
            throw UpdaterLaunchError.notExecutable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        let assetPattern = "LaunchNext.*\\.zip"
        let bundlePath = Bundle.main.bundlePath

        var arguments: [String] = ["-na", "Terminal", "--args", updaterURL.path]

        if !tag.isEmpty {
            arguments.append(contentsOf: ["--tag", tag])
        }

        arguments.append(contentsOf: [
            "--asset-pattern", assetPattern,
            "--install-dir", bundlePath,
            "--hold-window"
        ])

        process.arguments = arguments

        do {
            try process.run()
        } catch {
            throw UpdaterLaunchError.spawnFailed(error)
        }
    }

    @MainActor
    private func presentUpdaterLaunchFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = localized(.updateCheckFailed)
        alert.alertStyle = .warning

        let detail: String
        if let launchError = error as? UpdaterLaunchError {
            switch launchError {
            case .missingBinary:
                detail = localized(.updaterMissingBinary)
            case .notExecutable:
                detail = localized(.updaterNotExecutable)
            case .spawnFailed(let underlying):
                detail = underlying.localizedDescription
            }
        } else {
            detail = error.localizedDescription
        }

        alert.informativeText = String(format: localized(.updaterLaunchFailed), detail)
        alert.addButton(withTitle: localized(.okButton))
        alert.runModal()
    }
}

// MARK: - UpdateNotificationDelegate

private final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let openHandler: (URL) -> Void
    init(openHandler: @escaping (URL) -> Void) {
        self.openHandler = openHandler
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == UpdateChecker.updateNotificationDownloadActionIdentifier,
              let urlString = response.notification.request.content.userInfo["releaseURL"] as? String,
              let url = URL(string: urlString) else { return }
        openHandler(url)
    }
}
