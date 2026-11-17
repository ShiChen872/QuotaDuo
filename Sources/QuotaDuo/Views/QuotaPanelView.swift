import SwiftUI
import AppKit

struct QuotaPanelView: View {
    var store: QuotaStore
    @State private var launchAtLogin = LoginItemManager.isEnabled
    @State private var loginItemMessage: String?
    @State private var cardsHeight: CGFloat = 0

    private let maximumCardsHeight: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                cards
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: CardsHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .frame(height: min(cardsHeight > 1 ? cardsHeight : 240, maximumCardsHeight))
            .onPreferenceChange(CardsHeightKey.self) { cardsHeight = $0 }

            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            launchAtLogin = LoginItemManager.isEnabled
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.visibleSlots.isEmpty {
                emptyState
            } else {
                ForEach(store.visibleSlots) { slot in
                    ProviderCard(
                        title: slot.id.displayName,
                        state: slot.state,
                        softError: slot.softError
                    )
                }
            }
            settingsRow
        }
    }

    private var header: some View {
        HStack {
            Text("QuotaDuo")
                .font(.headline)
            Spacer()
            Button {
                Task { await store.refresh(manual: true) }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("立即刷新")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("未检测到已登录的服务")
                .font(.subheadline.weight(.medium))
            Text("请先登录 Codex、Cursor、Claude Code、AGY，或在 Chrome 登录 Skywork，然后点刷新。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var settingsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("登录时启动", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    if let error = LoginItemManager.setEnabled(newValue) {
                        loginItemMessage = error
                        launchAtLogin = LoginItemManager.isEnabled
                    } else {
                        loginItemMessage = nil
                        launchAtLogin = LoginItemManager.isEnabled
                        if launchAtLogin != newValue {
                            loginItemMessage = LoginItemManager.statusDescription
                        }
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            if let loginItemMessage {
                Text(loginItemMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
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
            } else if let at = store.lastSuccessfulRefreshAt {
                Text("更新于 \(Formatters.time.string(from: at))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.lastAttemptAt != nil {
                Text("尚未成功刷新")
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
    var softError: String?

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

            if let softError, case .loaded = state {
                Label(softError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .hidden:
            EmptyView()

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
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !usage.lines.isEmpty {
                    if let sections = sectionGroups(usage.lines) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(sections) { section in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(section.title)
                                        .font(.caption.weight(.semibold))
                                    if let note = section.note {
                                        Text(note)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    HStack(alignment: .top, spacing: 10) {
                                        ForEach(section.lines) { line in
                                            ringColumn(line, size: 46)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(usage.lines) { line in
                                ringColumn(line, size: 58)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct SectionGroup: Identifiable {
        let title: String
        let note: String?
        let lines: [UsageLine]
        var id: String { title }
    }

    private func sectionGroups(_ lines: [UsageLine]) -> [SectionGroup]? {
        guard lines.contains(where: { $0.section != nil }) else { return nil }
        var order: [String] = []
        var grouped: [String: [UsageLine]] = [:]
        var notes: [String: String] = [:]
        for line in lines {
            let title = line.section ?? ""
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(line)
            if notes[title] == nil, let note = line.sectionNote, !note.isEmpty {
                notes[title] = note
            }
        }
        return order.map { SectionGroup(title: $0, note: notes[$0], lines: grouped[$0] ?? []) }
    }

    private func ringColumn(_ line: UsageLine, size: CGFloat) -> some View {
        VStack(spacing: 6) {
            QuotaRing(remainingPercent: line.remainingPercent, size: size, lineWidth: 6)
            Text(line.label)
                .font(.caption2.weight(.medium))
            if let subtitle = line.subtitle {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let resetsAt = line.resetsAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(resetCaption(line, resetsAt: resetsAt, now: context.date))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func resetCaption(_ line: UsageLine, resetsAt: Date, now: Date) -> String {
        if line.section != nil, resetsAt <= now {
            return "再写入一次"
        }
        return Formatters.resetDescription(resetsAt, now: now)
    }
}

private struct CardsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum Formatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func resetDescription(_ date: Date, now: Date = .now) -> String {
        let remaining = date.timeIntervalSince(now)
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
