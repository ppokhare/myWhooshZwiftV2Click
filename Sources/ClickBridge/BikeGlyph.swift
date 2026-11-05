import SwiftUI

struct BikeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 2, y: 8, width: 10, height: 10))
        path.addEllipse(in: CGRect(x: 20, y: 8, width: 10, height: 10))
        path.addLines([
            CGPoint(x: 7, y: 13), CGPoint(x: 12, y: 5),
            CGPoint(x: 22, y: 6), CGPoint(x: 15, y: 13),
        ])
        path.closeSubpath()
        path.move(to: CGPoint(x: 15, y: 13))
        path.addLine(to: CGPoint(x: 11, y: 3))
        path.move(to: CGPoint(x: 8.5, y: 3))
        path.addLine(to: CGPoint(x: 13.5, y: 3))
        path.addLines([CGPoint(x: 25, y: 13), CGPoint(x: 21, y: 2), CGPoint(x: 26, y: 2)])

        let scale = min(rect.width / 32, rect.height / 20)
        return path.applying(CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: rect.midX - 16 * scale, ty: rect.midY - 10 * scale
        ))
    }
}
