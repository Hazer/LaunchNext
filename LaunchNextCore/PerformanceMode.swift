import Foundation

public enum PerformanceMode: String, CaseIterable, Identifiable {
    case full
    case lean

    public var id: String { rawValue }

    public static let userDefaultsKey = "performanceMode"

    private static let activeMode: PerformanceMode = {
        if let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
           let mode = PerformanceMode(rawValue: raw) {
            return mode
        }
        return .lean
    }()

    public static var current: PerformanceMode { activeMode }

    public static func persist(_ mode: PerformanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: userDefaultsKey)
    }
}
