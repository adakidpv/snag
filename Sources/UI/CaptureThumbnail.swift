import AppKit
import SwiftUI

/// Small cached thumbnails for the menu bar list.
///
/// Thumbnails are decoded at the size they're drawn at rather than loading full
/// screenshots (several megabytes each) into memory for a 44-point row.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: NSImage] = [:]

    func thumbnail(for url: URL, maxPixel: CGFloat = 96) -> NSImage? {
        let key = "\(url.path)#\(Int(maxPixel))"
        if let hit = cache[key] { return hit }
        guard let image = Self.downsample(url: url, maxPixel: maxPixel) else { return nil }
        cache[key] = image
        return image
    }

    func forget(url: URL) {
        cache = cache.filter { !$0.key.hasPrefix(url.path + "#") }
    }

    private static func downsample(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel * 2,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Thumbnail for a capture, falling back to a glyph for recordings (which get no AI
/// frame extraction in v0) and for files that have gone missing.
struct CaptureThumbnail: View {
    let url: URL
    let mediaType: SnagRecord.MediaType
    var width: CGFloat = 52
    var height: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))

            if mediaType == .image, let image = ThumbnailCache.shared.thumbnail(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: mediaType == .video ? "video.fill" : "photo")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}
