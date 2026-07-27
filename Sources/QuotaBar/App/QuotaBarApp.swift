import SwiftUI

@main
enum QuotaBarMain {
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            SmokeTest.run()
            return
        }

        QuotaBarApp.main()
    }
}

struct QuotaBarApp: App {
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

enum SmokeTest {
    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            print("QuotaBar smoke test")
            print("-------------------")

            do {
                let usage = try await CodexClient().fetch()
                print("[Codex] OK plan=\(usage.plan ?? "-")")
                for line in usage.lines {
                    let reset = line.resetsAt.map { Formatters.resetDescription($0) } ?? "-"
                    print(
                        "  - \(line.label): remaining \(Int(line.remainingPercent.rounded()))% used \(Int(line.usedPercent.rounded()))% reset=\(reset)"
                    )
                }
            } catch {
                print("[Codex] FAIL: \(error.localizedDescription)")
            }

            do {
                let usage = try await CursorClient().fetch()
                print("[Cursor] OK plan=\(usage.plan ?? "-") detail=\(usage.detail ?? "-")")
                for line in usage.lines {
                    let reset = line.resetsAt.map { Formatters.resetDescription($0) } ?? "-"
                    let subtitle = line.subtitle.map { " (\($0))" } ?? ""
                    print(
                        "  - \(line.label)\(subtitle): remaining \(Int(line.remainingPercent.rounded()))% used \(Int(line.usedPercent.rounded()))% reset=\(reset)"
                    )
                }
            } catch {
                print("[Cursor] FAIL: \(error.localizedDescription)")
            }
        }
        _ = semaphore.wait(timeout: .now() + 30)
    }
}
