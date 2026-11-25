import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TinfoilKit

final class OfflineChatPhotoTests: XCTestCase {
    func testReadsOrientedModelImageAndSmallerPreview() throws {
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2_400, height: 400, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 400))
        let image = try XCTUnwrap(context.makeImage())
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        let prepared = try OfflineChatPhoto.read(file)
        XCTAssertGreaterThan(prepared.image.height, prepared.image.width)
        XCTAssertEqual(prepared.image.height, 2_048)
        XCTAssertGreaterThan(prepared.preview.height, prepared.preview.width)
        XCTAssertEqual(prepared.preview.height, 320)
    }

    func testRejectsInvalidPhotoBytes() throws {
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([0]).write(to: file)
        XCTAssertThrowsError(try OfflineChatPhoto.read(file)) {
            XCTAssertEqual($0 as? OfflineChatPhoto.ImportError, .invalidPhoto)
        }
    }
}
