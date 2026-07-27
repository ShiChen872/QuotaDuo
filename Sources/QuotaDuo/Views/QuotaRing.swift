import SwiftUI

struct QuotaRing: View {
    let remainingPercent: Double
    var size: CGFloat = 56
    var lineWidth: CGFloat = 6

    private var progress: Double {
        max(0, min(1, remainingPercent / 100))
    }

    private var color: Color {
        if remainingPercent > 50 {
            return Color(red: 0.22, green: 0.55, blue: 0.95)
        } else if remainingPercent > 10 {
            return Color(red: 0.95, green: 0.65, blue: 0.15)
        } else {
            return Color(red: 0.95, green: 0.35, blue: 0.35)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: remainingPercent)

            Text("\(Int(remainingPercent.rounded()))%")
                .font(.system(size: size * 0.22, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityLabel("剩余 \(Int(remainingPercent.rounded())) 百分比")
    }
}

#Preview {
    HStack(spacing: 20) {
        QuotaRing(remainingPercent: 82)
        QuotaRing(remainingPercent: 35)
        QuotaRing(remainingPercent: 8)
    }
    .padding()
}
