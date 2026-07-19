import SwiftUI

/// Eight-rayed starburst with rounded tips — the app's mark.
struct Starburst: Shape {
    var rays = 8
    /// Inner radius as a fraction of outer; higher = chunkier rays.
    var waist = 0.42

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * waist
        var path = Path()
        let step = .pi * 2 / Double(rays)
        for i in 0..<rays {
            let angle = step * Double(i) - .pi / 2
            let tip = point(center, outer, angle)
            let leftBase = point(center, inner, angle - step * 0.32)
            let rightBase = point(center, inner, angle + step * 0.32)
            if i == 0 {
                path.move(to: leftBase)
            } else {
                path.addQuadCurve(to: leftBase, control: point(center, inner * 0.82, angle - step * 0.5))
            }
            // Rounded tip: curve out to the ray point and back.
            path.addQuadCurve(to: tip, control: point(center, outer * 1.02, angle - step * 0.12))
            path.addQuadCurve(to: rightBase, control: point(center, outer * 1.02, angle + step * 0.12))
        }
        path.closeSubpath()
        return path
    }

    private func point(_ c: CGPoint, _ r: Double, _ angle: Double) -> CGPoint {
        CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
    }
}

/// The banner mascot: pops in with overshoot and squash, then idles with a
/// slow lean — "timing has personality, motion has weight."
struct StarburstMascot: View {
    @State private var landed = false
    @State private var leaning = false

    var body: some View {
        Starburst()
            .fill(Color(red: 0.85, green: 0.47, blue: 0.34))
            .frame(width: 40, height: 40)
            .scaleEffect(x: landed ? 1 : 0.3, y: landed ? 1 : 0.45)
            .rotationEffect(.degrees(leaning ? 8 : -8))
            .animation(.spring(response: 0.45, dampingFraction: 0.55), value: landed)
            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: leaning)
            .onAppear {
                landed = true
                leaning = true
            }
    }
}
