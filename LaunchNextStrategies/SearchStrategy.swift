import LaunchNextCore
import Combine
import Foundation

// MARK: - Search Strategy Protocol

public protocol SearchStrategy {
    var identifier: String { get }
    var displayName: String { get }
    func apply<T: Publisher>(to publisher: T) -> AnyPublisher<T.Output, T.Failure>
}

// MARK: - Strategy Implementations

public struct DebounceStrategy: SearchStrategy {
    public let milliseconds: Int
    public let identifier = "debounce"
    public var displayName: String { "Debounce (\(milliseconds)ms)" }

    public init(milliseconds: Int) {
        self.milliseconds = milliseconds
    }

    public func apply<T: Publisher>(to publisher: T) -> AnyPublisher<T.Output, T.Failure> {
        publisher
            .debounce(for: .milliseconds(milliseconds), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}

public struct ThrottleStrategy: SearchStrategy {
    public let milliseconds: Int
    public let emitLatest: Bool
    public let identifier = "throttle"
    public var displayName: String { "Throttle (\(milliseconds)ms)" }

    public init(milliseconds: Int, emitLatest: Bool) {
        self.milliseconds = milliseconds
        self.emitLatest = emitLatest
    }

    public func apply<T: Publisher>(to publisher: T) -> AnyPublisher<T.Output, T.Failure> {
        publisher
            .throttle(for: .milliseconds(milliseconds), scheduler: DispatchQueue.main, latest: emitLatest)
            .eraseToAnyPublisher()
    }
}

public struct InstantStrategy: SearchStrategy {
    public let identifier = "instant"
    public let displayName = "Instant"

    public init() {}

    public func apply<T: Publisher>(to publisher: T) -> AnyPublisher<T.Output, T.Failure> {
        publisher.eraseToAnyPublisher()
    }
}

// MARK: - Strategy Type Enum

public enum SearchStrategyType: String, CaseIterable, Identifiable {
    case debounce
    case throttle
    case instant

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .debounce: return "Debounce"
        case .throttle: return "Throttle"
        case .instant: return "Instant"
        }
    }
}
