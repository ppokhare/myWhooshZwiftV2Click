import AppKit
import SwiftUI

struct BridgeIndicator: View {
    var clickReady: Bool
    var clientConnected: Bool

    var body: some View {
        let (badge, description): (String?, String) = switch (clickReady, clientConnected) {
        case (false, false): ("ellipsis", "Waiting for Click V2 and MyWhoosh")
        case (false, true): ("link", "MyWhoosh connected. Waiting for Click V2")
        case (true, false): ("dot.radiowaves.left.and.right", "Click V2 connected. Waiting for MyWhoosh")
        case (true, true): (nil, "Click V2 and MyWhoosh connected")
        }

        // Render the bike and optional badge into the single menu bar image.
        let renderer = ImageRenderer(content: HStack(spacing: 3) {
            BikeGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 15)
            if let badge {
                Image(systemName: badge)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 13)
            }
        }
        .foregroundStyle(Color.gray)
        .frame(width: 38, height: 18))
        renderer.scale = 2
        let icon = renderer.nsImage ?? NSImage()
        icon.isTemplate = badge == nil

        return Image(nsImage: icon)
            .renderingMode(badge == nil ? .template : .original)
            .accessibilityLabel("Click Bridge. \(description)")
    }
}
