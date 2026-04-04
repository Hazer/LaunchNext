import Combine
import Foundation

// MARK: - Search Strategy Protocol

protocol SearchStrategy {
    var identifier: String { get }
    var displayName: String { get }
    func apply<T: Publisher>(to publisher: T) -> AnyPublisher<T.Output, T.Failure>
}

// MARK: - Strategy Implementations

struct DebounceStrategy: SearchStrategy {
    let milliseconds: Int
    let identifier = "debounce"
    var displayName: String { "Debounce (\(milliseconds)ms)" }

    func apply<T: Publisher>(to publisher: T) -> AnyPublisher<T.Output, T.Failure> {
        publisher
            .debounce(for: .milliseconds(milliseconds), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}

struct ThrottleStrategy: SearchStrategy {
    let milliseconds: Int
    let emitLatest: Bool
    let identifier = "throttle"
    var displayName: String { "Throttle (\(milliseconds)ms)" }

    func apply<T: Publisher>(to publisher: T) -> AnyPublisher<T.Output, T.Failure> {
        publisher
            .throttle(for: .milliseconds(milliseconds), scheduler: DispatchQueue.main, latest: emitLatest)
            .eraseToAnyPublisher()
    }
}

struct InstantStrategy: SearchStrategy {
    let identifier = "instant"
    let displayName = "Instant"

    func apply<T: Publisher>(to publisher: T) -> AnyPublisher<T.Output, T.Failure> {
        publisher.eraseToAnyPublisher()
    }
}

// MARK: - Strategy Type Enum

enum SearchStrategyType: String, CaseIterable, Identifiable {
    case debounce
    case throttle
    case instant

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .debounce: return "Debounce"
        case .throttle: return "Throttle"
        case .instant: return "Instant"
        }
    }
}
