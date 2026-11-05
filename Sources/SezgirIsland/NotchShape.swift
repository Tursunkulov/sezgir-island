import SwiftUI

/// Notch silhouette: concave "flares" at the top that melt into the menu bar,
/// rounded corners at the bottom. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, rect.width / 4)
        let br = min(bottomRadius, (rect.height - tr), (rect.width - tr * 2) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addArc(tangent1End: CGPoint(x: rect.minX + tr, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX + tr + br, y: rect.maxY), radius: br)
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX - tr, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - tr, y: rect.maxY - br), radius: br)
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
