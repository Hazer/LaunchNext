import Foundation

public enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(latest: String)
    case updateAvailable(UpdateRelease)
    case failed(String)
}

public struct UpdateRelease: Equatable {
    public let version: String
    public let url: URL
    public let notes: String?

    public init(version: String, url: URL, notes: String?) {
        self.version = version
        self.url = url
        self.notes = notes
    }
}
