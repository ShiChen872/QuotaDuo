import SwiftUI

struct MenuBarLabel: View {
    let store: QuotaStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.lefthalf.filled")
                .symbolRenderingMode(.hierarchical)

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
        if remaining > 10 { return Color(red: 0.85, green: 0.55, blue: 0.1) }
        return Color(red: 0.9, green: 0.3, blue: 0.3)
    }

    private var accessibilityText: String {
        if let text = store.menuBarText {
            return "用量 \(text)"
        }
        return "用量未知"
    }
}
