import SwiftUI

struct KeywordTrendSparklineView: View {
    let points: [Int]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard points.count > 1, size.width > 0, size.height > 0 else { return }

            let lowerBound = CGFloat(rankScaleLowerBound)
            let span = CGFloat(rankScaleUpperBound) - lowerBound
            let plotPoints = points.enumerated().map { index, rank in
                CGPoint(
                    x: CGFloat(index) / CGFloat(points.count - 1) * size.width,
                    y: (CGFloat(rank) - lowerBound) / span * size.height
                )
            }
            let line = Self.cardinalPath(through: plotPoints)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()

            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [
                        color.opacity(isFlatTrend ? 0.08 : 0.28),
                        color.opacity(isFlatTrend ? 0.02 : 0.06),
                        color.opacity(0)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(
                line,
                with: .color(color.opacity(isFlatTrend ? 0.44 : 1)),
                style: StrokeStyle(
                    lineWidth: isFlatTrend ? 1.5 : 3,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank trend")
    }

    private static func cardinalPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let before = points[max(0, index - 2)]
            let after = points[min(points.count - 1, index + 1)]
            path.addCurve(
                to: current,
                control1: CGPoint(
                    x: previous.x + (current.x - before.x) / 6,
                    y: previous.y + (current.y - before.y) / 6
                ),
                control2: CGPoint(
                    x: current.x - (after.x - previous.x) / 6,
                    y: current.y - (after.y - previous.y) / 6
                )
            )
        }
        return path
    }

    private var isFlatTrend: Bool {
        guard let firstPoint = points.first else { return false }
        return points.allSatisfy { $0 == firstPoint }
    }

    private var rankScaleLowerBound: Int {
        guard let minRank = points.min() else {
            return 1
        }

        if isFlatTrend {
            return max(0, minRank - 1)
        }

        return minRank
    }

    private var rankScaleUpperBound: Int {
        guard let maxRank = points.max() else {
            return 2
        }

        return isFlatTrend ? maxRank + 1 : maxRank
    }
}

#Preview("Keyword Trend Sparkline") {
    VStack(alignment: .leading, spacing: 14) {
        previewRow(title: "Trending Up", points: [24, 23, 23, 22, 20, 16, 11], color: .green)
        previewRow(title: "Trending Down", points: [8, 9, 11, 12, 15, 18, 23], color: .red)
        previewRow(title: "Unchanged", points: [14, 14, 14, 14, 14, 14, 14], color: .secondary)
        previewRow(title: "Volatile Up", points: [35, 29, 31, 24, 26, 20, 12], color: .green)
        previewRow(title: "No Data", points: [], color: .secondary)
    }
    .padding(20)
    .frame(width: 260)
}

private func previewRow(title: String, points: [Int], color: Color) -> some View {
    HStack(spacing: 12) {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 86, alignment: .leading)

        KeywordTrendSparklineView(points: points, color: color)
            .frame(width: 120, height: 34)
    }
}
