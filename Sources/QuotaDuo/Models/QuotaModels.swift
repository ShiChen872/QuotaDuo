import Foundation

enum ProviderID: String, Sendable, CaseIterable, Identifiable {
    case codex
    case cursor
    case claude
    case skywork
    case agy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .claude: return "Claude"
        case .skywork: return "Skywork"
        case .agy: return "AGY"
        }
    }

    /// Compact prefix for the menu bar (C / X / A / S / G).
    var menuBarPrefix: String {
        switch self {
        case .codex: return "C"
        case .cursor: return "X"
        case .claude: return "A"
        case .skywork: return "S"
        case .agy: return "G"
        }
    }

    /// Labels that drive the menu-bar percentage for this provider.
    var primaryLabels: Set<String> {
        switch self {
        case .codex: return ["Session", "Weekly"]
        case .cursor: return ["Plan"]
        case .claude: return ["Session", "Weekly"]
        case .skywork: return ["会员", "充值"]
        case .agy: return []
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
    /// When set, menu bar uses this instead of the lowest primary line.
    /// Skywork menu bar is the spendable total capped at the 10,000 membership face value.
    let menuBarRemainingPercent: Double?
    /// Whether this provider should contribute a compact badge to the top menu bar.
    let includeInMenuBar: Bool

    init(
        providerId: ProviderID,
        plan: String?,
        lines: [UsageLine],
        fetchedAt: Date,
        detail: String?,
        menuBarRemainingPercent: Double? = nil,
        includeInMenuBar: Bool = true
    ) {
        self.providerId = providerId
        self.plan = plan
        self.lines = lines
        self.fetchedAt = fetchedAt
        self.detail = detail
        self.menuBarRemainingPercent = menuBarRemainingPercent
        self.includeInMenuBar = includeInMenuBar
    }

    /// Lowest remaining among primary lines; falls back to all lines.
    var primaryRemainingPercent: Double? {
        guard includeInMenuBar else { return nil }
        if let menuBarRemainingPercent {
            return menuBarRemainingPercent.clampedPercent
        }
        let primary = lines.filter { providerId.primaryLabels.contains($0.label) }
        let pool = primary.isEmpty ? lines : primary
        return pool.map(\.remainingPercent).min()
    }

    var lowestRemainingPercent: Double? {
        lines.map(\.remainingPercent).min()
    }
}

enum ProviderLoadState: Sendable, Equatable {
    /// No local credentials — do not reserve UI space.
    case hidden
    case idle
    case loading
    case loaded(ProviderUsage)
    case unavailable(String)
}

struct ProviderSlot: Identifiable, Sendable, Equatable {
    let id: ProviderID
    var state: ProviderLoadState
    var softError: String?

    var isVisible: Bool {
        if case .hidden = state { return false }
        return true
    }
}

enum AuthErrorDetector {
    static func isAuthUnavailable(_ error: Error) -> Bool {
        if let error = error as? CodexError, case .authUnavailable = error { return true }
        if let error = error as? CursorError, case .authUnavailable = error { return true }
        if let error = error as? ClaudeError, case .authUnavailable = error { return true }
        if let error = error as? SkyworkError, case .authUnavailable = error { return true }
        if let error = error as? AGYError, case .authUnavailable = error { return true }
        return false
    }
}

extension Double {
    var clampedPercent: Double { max(0, min(100, self)) }
}
