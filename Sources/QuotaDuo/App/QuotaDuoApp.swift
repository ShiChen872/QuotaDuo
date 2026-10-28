import SwiftUI

@main
enum QuotaDuoMain {
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            SmokeTest.run()
            return
        }
        if CommandLine.arguments.contains("--skywork-detail-once") {
            SkyworkDetailOnce.run()
            return
        }

        QuotaDuoApp.main()
    }
}

struct QuotaDuoApp: App {
    @State private var store = QuotaStore()

    var body: some Scene {
        MenuBarExtra {
            QuotaPanelView(store: store)
        } label: {
            MenuBarLabel(store: store)
                .task {
                    store.start()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

enum SkyworkDetailOnce {
    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            let sessionURL = SkyworkClient.sessionFileURL()
            let existed = FileManager.default.fileExists(atPath: sessionURL.path)
            do {
                let usage = try await SkyworkClient().fetch(includeDetail: true)
                print("detailRequests=\(SkyworkClient.detailRequestCount())")
                print("sessionFileExisted=\(existed)")
                print("sessionFileRemains=\(FileManager.default.fileExists(atPath: sessionURL.path))")
                print("plan=\(usage.plan ?? "-")")
                print("detail=\(usage.detail ?? "-")")
                print("menu=\(usage.menuBarRemainingPercent.map { String(Int($0.rounded())) } ?? "-")")
                for line in usage.lines {
                    let reset = line.resetsAt.map { Formatters.resetDescription($0) } ?? "-"
                    let subtitle = line.subtitle.map { " (\($0))" } ?? ""
                    print("  - \(line.label)\(subtitle): remaining \(Int(line.remainingPercent.rounded()))% reset=\(reset)")
                }
            } catch {
                print("detailRequests=\(SkyworkClient.detailRequestCount())")
                print("sessionFileExisted=\(existed)")
                print("sessionFileRemains=\(FileManager.default.fileExists(atPath: sessionURL.path))")
                print("FAIL: \(error.localizedDescription)")
            }
        }
        _ = semaphore.wait(timeout: .now() + 45)
    }
}

enum SmokeTest {
    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            print("QuotaDuo smoke test")
            print("-------------------")

            await probe(name: "Codex", configured: CodexClient().isConfigured()) {
                try await CodexClient().fetch()
            }
            await probe(name: "Cursor", configured: CursorClient().isConfigured()) {
                try await CursorClient().fetch()
            }
            await probe(name: "Claude", configured: ClaudeClient().isConfigured()) {
                try await ClaudeClient().fetch()
            }
            await probe(name: "Skywork", configured: SkyworkClient().isConfigured()) {
                try await SkyworkClient().fetch()
            }
            await probe(name: "AGY", configured: AGYClient().isConfigured()) {
                try await AGYClient().fetch()
            }
        }
        _ = semaphore.wait(timeout: .now() + 45)
    }

    private static func probe(
        name: String,
        configured: Bool,
        fetch: () async throws -> ProviderUsage
    ) async {
        if !configured {
            print("[\(name)] HIDDEN (未检测到本地登录态)")
            return
        }
        do {
            let usage = try await fetch()
            print("[\(name)] OK plan=\(usage.plan ?? "-") detail=\(usage.detail ?? "-")")
            for line in usage.lines {
                let reset = line.resetsAt.map { Formatters.resetDescription($0) } ?? "-"
                let subtitle = line.subtitle.map { " (\($0))" } ?? ""
                print(
                    "  - \(line.label)\(subtitle): remaining \(Int(line.remainingPercent.rounded()))% used \(Int(line.usedPercent.rounded()))% reset=\(reset)"
                )
            }
        } catch {
            print("[\(name)] FAIL: \(error.localizedDescription)")
        }
    }
}
