import SwiftUI

/// Twin interlocking arcs — matches the hand-drawn AppIcon.
struct MenuBarQuotaGlyph: View {
    let remainingPercent: Double?

    private var progress: Double {
        guard let remainingPercent else { return 0.72 }
        return max(0, min(1, remainingPercent / 100))
    }

    private var mint: Color { Color(red: 0.18, green: 0.95, blue: 0.72) }
    private var amber: Color { Color(red: 1.0, green: 0.58, blue: 0.14) }

    private var primary: Color {
        guard let remainingPercent else { return mint }
        if remainingPercent > 50 { return mint }
        if remainingPercent > 10 { return amber }
        return Color(red: 0.95, green: 0.35, blue: 0.35)
    }

    var body: some View {
        ZStack {
            // Left track + arc
            Circle()
                .stroke(Color.primary.opacity(0.18), lineWidth: 1.45)
                .frame(width: 11, height: 11)
                .offset(x: -1.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(primary, style: StrokeStyle(lineWidth: 1.45, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 11, height: 11)
                .offset(x: -1.5)

            // Right track + arc (opposite phase)
            Circle()
                .stroke(Color.primary.opacity(0.18), lineWidth: 1.45)
                .frame(width: 11, height: 11)
                .offset(x: 1.5)
            Circle()
                .trim(from: 0, to: max(0.22, progress * 0.85))
                .stroke(amber.opacity(0.95), style: StrokeStyle(lineWidth: 1.45, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: 11, height: 11)
                .offset(x: 1.5)
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

struct MenuBarLabel: View {
    let store: QuotaStore

    var body: some View {
        HStack(spacing: 4) {
            MenuBarQuotaGlyph(remainingPercent: store.menuBarLowestPrimary)

            if let text = store.menuBarText {
                Text(text)
                    .monospacedDigit()
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color(for: store.menuBarLowestPrimary))
            } else if store.isRefreshing {
                Text("…")
                    .font(.system(size: 12, weight: .medium))
            } else {
                Text("--")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private func color(for remaining: Double?) -> Color {
        guard let remaining else { return .primary }
        if remaining > 50 { return .primary }
        if remaining > 10 { return Color(red: 1.0, green: 0.58, blue: 0.14) }
        return Color(red: 0.95, green: 0.35, blue: 0.35)
    }

    private var accessibilityText: String {
        if let text = store.menuBarText {
            return "用量 \(text)"
        }
        return "用量未知"
    }
}
