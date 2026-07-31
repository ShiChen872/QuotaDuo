import Foundation

enum ProviderID: String, Sendable, CaseIterable {
    case codex
    case cursor

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// Labels that drive the menu-bar percentage for this provider.
    var primaryLabels: Set<String> {
        switch self {
        case .codex: return ["Session", "Weekly"]
        case .cursor: return ["Plan"]
        }
    }
}

struct UsageLine: Identifiable, Sendable, Equatable {
    var id: String { label }
    let label: String
    /// Used percentage in 0...100
    let usedPercent: Double
    let resetsAt: Date?
    let subtitle: String?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct ProviderUsage: Identifiable, Sendable, Equatable {
    var id: String { providerId.rawValue }
    let providerId: ProviderID
    let plan: String?
    let lines: [UsageLine]
    let fetchedAt: Date
    let detail: String?

    /// Lowest remaining among primary lines; falls back to all lines.
    var primaryRemainingPercent: Double? {
        let primary = lines.filter { providerId.primaryLabels.contains($0.label) }
        let pool = primary.isEmpty ? lines : primary
        return pool.map(\.remainingPercent).min()
    }

    var lowestRemainingPercent: Double? {
        lines.map(\.remainingPercent).min()
    }
}

enum ProviderLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded(ProviderUsage)
    case unavailable(String)
}

extension Double {
    var clampedPercent: Double { max(0, min(100, self)) }
}
