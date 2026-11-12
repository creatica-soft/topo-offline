import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Small image helpers built on ImageIO/CoreGraphics so they work off the main thread.
enum TileImage {
    static func isImage(_ data: Data) -> Bool {
        guard data.count > 8 else { return false }
        let b = [UInt8](data.prefix(4))
        let png = b == [0x89, 0x50, 0x4E, 0x47]
        let jpeg = b[0] == 0xFF && b[1] == 0xD8
        return png || jpeg
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double = 0.8) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Re-encodes a tile as JPEG on a white background. Returns nil if that would not save space.
    static func jpeg(from data: Data, quality: Double = 0.8) -> Data? {
        guard let image = decode(data),
              let ctx = context(width: image.width, height: image.height) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = ctx.makeImage(), let out = encode(flat, type: .jpeg, quality: quality) else { return nil }
        return out.count < data.count ? out : nil
    }

    /// Cuts the quarter/sixteenth/... of a lower-zoom tile that covers a higher-zoom tile and scales it up,
    /// so the map keeps showing something when zoomed in past what the server provides.
    static func overzoom(parent data: Data, levels dz: Int, offsetX dx: Int, offsetY dy: Int, size: Int = 256) -> Data? {
        guard dz > 0, let image = decode(data) else { return nil }
        let part = Double(image.width) / Double(1 << dz)
        let rect = CGRect(x: Double(dx) * part, y: Double(dy) * part, width: part, height: part).integral
        guard let cropped = image.cropping(to: rect),
              let ctx = context(width: size, height: size) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = ctx.makeImage() else { return nil }
        return encode(scaled, type: .png)
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
