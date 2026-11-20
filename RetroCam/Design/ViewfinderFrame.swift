import SwiftUI

/// Cornice del mirino: quattro angoli sottili in metallo champagne, come i segni di taglio di un vetro smerigliato.
/// Segue l'area sicura, così non finisce nelle curve dello schermo né sotto il Dynamic Island.
struct ViewfinderFrame: View {
    var inset: CGFloat = 6
    var length: CGFloat = 14

    var body: some View {
        FrameCorners(length: length)
            .stroke(Brand.metal, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .opacity(0.7)
            .padding(inset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct FrameCorners: Shape {
    var length: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
        }
        return p
    }
}
