import SwiftUI

// Compiled into both the app and the widget extension (see project.yml).

/// Minimal line for cards and widgets. A full Chart is reserved for the game detail screen.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let path = Self.path(values: values, in: proxy.size)
            path.stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    static func path(values: [Double], in size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1, let minValue = values.min(), let maxValue = values.max() else { return path }
        let range = max(maxValue - minValue, 1)
        let stepX = size.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: CGFloat(index) * stepX,
                                y: size.height - CGFloat((value - minValue) / range) * size.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
