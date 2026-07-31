import Foundation
import Observation

@MainActor
@Observable
final class QuotaStore {
    var codex: ProviderLoadState = .idle
    var cursor: ProviderLoadState = .idle
    /// Soft error while previous loaded data is still shown.
    var codexError: String?
    var cursorError: String?
    var isRefreshing = false
    /// Last time at least one provider refreshed successfully.
    var lastSuccessfulRefreshAt: Date?
    var lastAttemptAt: Date?

    private let codexClient = CodexClient()
    private let cursorClient = CursorClient()
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 5 * 60

    /// Compact menu-bar text, e.g. "C81·X79" or "81%".
    var menuBarText: String? {
        var parts: [String] = []
        if case .loaded(let usage) = codex, let value = usage.primaryRemainingPercent {
            parts.append("C\(Int(value.rounded()))")
        }
        if case .loaded(let usage) = cursor, let value = usage.primaryRemainingPercent {
            parts.append("X\(Int(value.rounded()))")
        }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 {
            return "\(parts[0].dropFirst())%"
        }
        return parts.joined(separator: "·")
    }

    var menuBarLowestPrimary: Double? {
        let values = [codex, cursor].compactMap { state -> Double? in
            if case .loaded(let usage) = state {
                return usage.primaryRemainingPercent
            }
            return nil
        }
        return values.min()
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.refreshInterval))
                guard !Task.isCancelled else { break }
                await self.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        if case .idle = codex { codex = .loading }
        if case .idle = cursor { cursor = .loading }

        async let codexResult: Result<ProviderUsage, Error> = {
            do { return .success(try await self.codexClient.fetch()) }
            catch { return .failure(error) }
        }()

        async let cursorResult: Result<ProviderUsage, Error> = {
            do { return .success(try await self.cursorClient.fetch()) }
            catch { return .failure(error) }
        }()

        let (codexOutcome, cursorOutcome) = await (codexResult, cursorResult)
        lastAttemptAt = Date.now
        var anySuccess = false

        switch codexOutcome {
        case .success(let usage):
            codex = .loaded(usage)
            codexError = nil
            anySuccess = true
        case .failure(let error):
            if case .loaded = codex {
                codexError = error.localizedDescription
            } else {
                codex = .unavailable(error.localizedDescription)
                codexError = nil
            }
        }

        switch cursorOutcome {
        case .success(let usage):
            cursor = .loaded(usage)
            cursorError = nil
            anySuccess = true
        case .failure(let error):
            if case .loaded = cursor {
                cursorError = error.localizedDescription
            } else {
                cursor = .unavailable(error.localizedDescription)
                cursorError = nil
            }
        }

        if anySuccess {
            lastSuccessfulRefreshAt = Date.now
        }
    }
}
