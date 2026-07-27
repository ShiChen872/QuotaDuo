import SwiftUI
import AppKit

struct QuotaPanelView: View {
    var store: QuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ProviderCard(title: "Codex", state: store.codex)
            ProviderCard(title: "Cursor", state: store.cursor)

            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("QuotaBar")
                .font(.headline)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("立即刷新")
        }
    }

    private var footer: some View {
        HStack {
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("刷新中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let at = store.lastRefreshedAt {
                Text("更新于 \(Formatters.time.string(from: at))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

private struct ProviderCard: View {
    let title: String
    let state: ProviderLoadState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if case .loaded(let usage) = state, let plan = usage.plan {
                    Text(plan)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                Spacer()
            }

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("加载中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)

        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)

        case .loaded(let usage):
            VStack(alignment: .leading, spacing: 10) {
                if let detail = usage.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 14) {
                    ForEach(usage.lines) { line in
                        VStack(spacing: 6) {
                            QuotaRing(remainingPercent: line.remainingPercent, size: 58, lineWidth: 6)
                            Text(line.label)
                                .font(.caption2.weight(.medium))
                            if let subtitle = line.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let resetsAt = line.resetsAt {
                                Text(Formatters.resetDescription(resetsAt))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

enum Formatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func resetDescription(_ date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 {
            return "已重置"
        }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours >= 48 {
            let days = hours / 24
            let remHours = hours % 24
            return "\(days)天\(remHours)时后"
        }
        if hours >= 1 {
            return "\(hours)时\(minutes)分后"
        }
        return "\(max(minutes, 1))分后"
    }
}
