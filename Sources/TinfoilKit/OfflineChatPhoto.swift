import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct OfflineChatPhoto: Transferable {
    let image: CGImage
    let preview: CGImage

    private static let maximumInputEdge = 2_048
    private static let maximumPreviewEdge = 320
    typealias ImportError = OfflineChatPhotoLimits.ImportError

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image, shouldAttemptToOpenInPlace: true) { received in
            try read(received.file)
        }
    }

    static func read(_ file: URL) throws -> Self {
        try OfflineChatPhotoLimits.validate(file: file)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw ImportError.invalidPhoto
        }
        try OfflineChatPhotoLimits.validate(width: width, height: height)
        let image = try thumbnail(source, maximumEdge: maximumInputEdge)
        try Task.checkCancellation()
        let preview = max(image.width, image.height) <= maximumPreviewEdge
            ? image : try thumbnail(source, maximumEdge: maximumPreviewEdge)
        try Task.checkCancellation()
        return Self(image: image, preview: preview)
    }

    private static func thumbnail(_ source: CGImageSource, maximumEdge: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.invalidPhoto
        }
        return image
    }
}
