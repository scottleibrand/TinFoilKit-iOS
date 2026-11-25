import Foundation

enum OfflineChatPhotoLimits {
    private static let maximumBytes = 32 * 1024 * 1024
    private static let maximumPixels = 100_000_000

    enum ImportError: LocalizedError {
        case invalidPhoto, tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidPhoto: "This photo could not be opened."
            case .tooLarge: "Choose a photo up to 32 MiB and 100 megapixels."
            }
        }
    }

    static func validate(file: URL) throws {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
            throw ImportError.invalidPhoto
        }
        guard size <= maximumBytes else { throw ImportError.tooLarge }
    }

    static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ImportError.invalidPhoto }
        guard width <= maximumPixels / height else { throw ImportError.tooLarge }
    }
}
