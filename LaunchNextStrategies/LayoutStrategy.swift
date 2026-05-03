import LaunchNextCore
import Foundation

// MARK: - Layout Strategy Protocol

public protocol LayoutStrategy {
    var identifier: String { get }
    var displayName: String { get }
    var isPagingEnabled: Bool { get }
    var isVertical: Bool { get }

    func itemsPerPage(columns: Int, rows: Int) -> Int
    func pageCount(totalItems: Int, columns: Int, rows: Int) -> Int
    func pageForItem(at globalIndex: Int, columns: Int, rows: Int) -> Int
}

// MARK: - Layout Mode Enum

public enum LayoutMode: String, CaseIterable, Identifiable {
    case paged
    case vertical

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .paged: return "Paged"
        case .vertical: return "Vertical Scroll"
        }
    }
}

// MARK: - Paged Layout Strategy

public struct PagedLayoutStrategy: LayoutStrategy {
    public let identifier = "paged"
    public let displayName = "Paged"
    public let isPagingEnabled = true
    public let isVertical = false

    public init() {}

    public func itemsPerPage(columns: Int, rows: Int) -> Int {
        columns * rows
    }

    public func pageCount(totalItems: Int, columns: Int, rows: Int) -> Int {
        let perPage = itemsPerPage(columns: columns, rows: rows)
        return max(1, (totalItems + perPage - 1) / perPage)
    }

    public func pageForItem(at globalIndex: Int, columns: Int, rows: Int) -> Int {
        globalIndex / itemsPerPage(columns: columns, rows: rows)
    }
}

// MARK: - Vertical Layout Strategy

public struct VerticalLayoutStrategy: LayoutStrategy {
    public let identifier = "vertical"
    public let displayName = "Vertical Scroll"
    public let isPagingEnabled = false
    public let isVertical = true

    public init() {}

    public func itemsPerPage(columns: Int, rows: Int) -> Int {
        // In vertical mode, all items are on one "page"
        Int.max
    }

    public func pageCount(totalItems: Int, columns: Int, rows: Int) -> Int {
        max(1, totalItems > 0 ? 1 : 0)
    }

    public func pageForItem(at globalIndex: Int, columns: Int, rows: Int) -> Int {
        0
    }
}
