import AppKit
import SwiftUI

/// Optional user-supplied mascot at ~/.cachewatch/icon.png. Licensed art stays
/// local — the repo ships only the drawn Starburst fallback. The loader keys out
/// the background color sampled at the top-left corner, so flat-background
/// sprites (pixel art sheets) drop in without editing.
enum MascotIcon {
    static let image: NSImage? = load()

    /// MenuBarExtra renders nothing for oversized bitmaps — it needs an image
    /// actually rasterized at status-item size, not one with a small `size` set.
    static let menuBar: NSImage? = image.map { source in
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .none  // crisp pixel art
            source.draw(in: rect)
            return true
        }
    }

    private static func load() -> NSImage? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".cachewatch/icon.png")
        guard let source = NSImage(contentsOfFile: path) else { return nil }
        return chromaKeyed(source) ?? source
    }

    private static func chromaKeyed(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        let keyR = Int(pixels[0]), keyG = Int(pixels[1]), keyB = Int(pixels[2])
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let distance = abs(Int(pixels[i]) - keyR) + abs(Int(pixels[i + 1]) - keyG) + abs(Int(pixels[i + 2]) - keyB)
            if distance < 60 {
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
            }
        }
        guard let keyed = ctx.makeImage() else { return nil }
        return NSImage(cgImage: keyed, size: NSSize(width: width, height: height))
    }
}

/// Banner mascot: the user's icon when present, the drawn starburst otherwise.
/// Same entrance and idle motion either way.
struct BannerMascot: View {
    @State private var landed = false
    @State private var leaning = false

    var body: some View {
        Group {
            if let icon = MascotIcon.image {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.none)  // keep pixel art crisp
                    .scaledToFit()
                    .frame(width: 48, height: 48)
            } else {
                Starburst()
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.34))
                    .frame(width: 40, height: 40)
            }
        }
        .scaleEffect(x: landed ? 1 : 0.3, y: landed ? 1 : 0.45)
        .rotationEffect(.degrees(leaning ? 6 : -6))
        .animation(.spring(response: 0.45, dampingFraction: 0.55), value: landed)
        .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: leaning)
        .onAppear {
            landed = true
            leaning = true
        }
    }
}
