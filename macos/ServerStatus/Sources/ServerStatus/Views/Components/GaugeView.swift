import SwiftUI

struct GaugeView: View {
    let percent: Double
    let bigText: String
    let smallText: String

    private var clamped: Double {
        max(0, min(100, percent)) / 100.0
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 10)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    AngularGradient(
                        colors: [.teal, .cyan, .blue],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: percent)

            VStack(spacing: 2) {
                Text(bigText)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(smallText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 110, height: 110)
    }
}
