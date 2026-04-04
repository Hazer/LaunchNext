import Foundation

// MARK: - Layout Strategy Protocol

protocol LayoutStrategy {
    var identifier: String { get }
    var displayName: String { get }
    var isPagingEnabled: Bool { get }
    var isVertical: Bool { get }

    func itemsPerPage(columns: Int, rows: Int) -> Int
    func pageCount(totalItems: Int, columns: Int, rows: Int) -> Int
    func pageForItem(at globalIndex: Int, columns: Int, rows: Int) -> Int
}

// MARK: - Layout Mode Enum

enum LayoutMode: String, CaseIterable, Identifiable {
    case paged
    case vertical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paged: return "Paged"
        case .vertical: return "Vertical Scroll"
        }
    }
}

// MARK: - Paged Layout Strategy

struct PagedLayoutStrategy: LayoutStrategy {
    let identifier = "paged"
    let displayName = "Paged"
    let isPagingEnabled = true
    let isVertical = false

    func itemsPerPage(columns: Int, rows: Int) -> Int {
        columns * rows
    }

    func pageCount(totalItems: Int, columns: Int, rows: Int) -> Int {
        let perPage = itemsPerPage(columns: columns, rows: rows)
        return max(1, (totalItems + perPage - 1) / perPage)
    }

    func pageForItem(at globalIndex: Int, columns: Int, rows: Int) -> Int {
        globalIndex / itemsPerPage(columns: columns, rows: rows)
    }
}

// MARK: - Vertical Layout Strategy

struct VerticalLayoutStrategy: LayoutStrategy {
    let identifier = "vertical"
    let displayName = "Vertical Scroll"
    let isPagingEnabled = false
    let isVertical = true

    func itemsPerPage(columns: Int, rows: Int) -> Int {
        // In vertical mode, all items are on one "page"
        Int.max
    }

    func pageCount(totalItems: Int, columns: Int, rows: Int) -> Int {
        max(1, totalItems > 0 ? 1 : 0)
    }

    func pageForItem(at globalIndex: Int, columns: Int, rows: Int) -> Int {
        0
    }
}
