import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A screenshot prepared for the Messages API: downscaled and base64-encoded.
///
/// 1568px on the long edge is Anthropic's guidance -- larger images are scaled down
/// server-side anyway, so sending more costs upload time and tokens for nothing.
struct ImagePayload {
    let base64: String
    let mediaType: String
    let pixelSize: CGSize

    enum Failure: Error, LocalizedError {
        case unreadable(URL)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadable(let url):
                return "Couldn't read the capture at \(url.lastPathComponent)."
            case .encodingFailed:
                return "Couldn't prepare the screenshot for upload."
            }
        }
    }

    static let maxLongEdge: CGFloat = 1568
    /// Comfortably inside the API's per-image ceiling; past this, re-encode as JPEG.
    private static let pngBudgetBytes = 3_500_000

    static func make(from url: URL) throws -> ImagePayload {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.unreadable(url)
        }

        // Thumbnail generation does the decode and the scale in one step, so a full
        // 6K screenshot is never materialised at full size.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable(url)
        }
        let size = CGSize(width: image.width, height: image.height)

        // PNG first: screenshots are mostly flat colour and text, which PNG keeps sharp
        // and compresses well. JPEG is the fallback only when PNG comes out too big,
        // because blurring small error text is exactly what we don't want.
        if let png = encode(image, as: .png), png.count <= pngBudgetBytes {
            return ImagePayload(
                base64: png.base64EncodedString(),
                mediaType: "image/png",
                pixelSize: size
            )
        }
        guard let jpeg = encode(image, as: .jpeg, quality: 0.9) else {
            throw Failure.encodingFailed
        }
        return ImagePayload(
            base64: jpeg.base64EncodedString(),
            mediaType: "image/jpeg",
            pixelSize: size
        )
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: CGFloat? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else { return nil }

        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
