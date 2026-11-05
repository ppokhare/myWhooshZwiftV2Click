import AppKit
import SwiftUI

@main
struct RenderAppIcon {
    @MainActor
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let tile = RoundedRectangle(cornerRadius: 190)
        let icon = ZStack {
            tile.fill(LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.34, blue: 0.26),
                    Color(red: 0.04, green: 0.14, blue: 0.11),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            tile.strokeBorder(.white.opacity(0.13), lineWidth: 5)
            BikeGlyph()
                .stroke(.white, style: StrokeStyle(lineWidth: 34, lineCap: .round, lineJoin: .round))
                .frame(width: 620, height: 400)
        }
        .frame(width: 832, height: 832)
        .frame(width: 1024, height: 1024)

        let renderer = ImageRenderer(content: icon)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                renderer.scale = CGFloat(size * scale) / 1024
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                else { throw CocoaError(.fileWriteUnknown) }

                let suffix = scale == 2 ? "@2x" : ""
                try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
    }
}
