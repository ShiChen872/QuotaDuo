import Foundation
import Observation

@MainActor
@Observable
final class QuotaStore {
    var codex: ProviderLoadState = .idle
    var cursor: ProviderLoadState = .idle
    var isRefreshing = false
    var lastRefreshedAt: Date?

    private let codexClient = CodexClient()
    private let cursorClient = CursorClient()
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 5 * 60

    var lowestRemainingPercent: Double? {
        let values = [codex, cursor].compactMap { state -> Double? in
            if case .loaded(let usage) = state {
                return usage.lowestRemainingPercent
            }
            return nil
        }
        return values.min()
    }

    var hasAnyData: Bool {
        if case .loaded = codex { return true }
        if case .loaded = cursor { return true }
        return false
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
        // Keep previous loaded data visible while refreshing.

        async let codexResult: Result<ProviderUsage, Error> = {
            do { return .success(try await self.codexClient.fetch()) }
            catch { return .failure(error) }
        }()

        async let cursorResult: Result<ProviderUsage, Error> = {
            do { return .success(try await self.cursorClient.fetch()) }
            catch { return .failure(error) }
        }()

        let (codexOutcome, cursorOutcome) = await (codexResult, cursorResult)

        switch codexOutcome {
        case .success(let usage):
            codex = .loaded(usage)
        case .failure(let error):
            codex = .unavailable(error.localizedDescription)
        }

        switch cursorOutcome {
        case .success(let usage):
            cursor = .loaded(usage)
        case .failure(let error):
            cursor = .unavailable(error.localizedDescription)
        }

        lastRefreshedAt = Date.now
    }
}
