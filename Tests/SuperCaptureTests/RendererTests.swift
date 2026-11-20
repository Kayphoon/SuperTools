import AppKit
import Testing
@testable import SuperCapture

struct RendererTests {
    private func image(width: Int = 32, height: Int = 32, checker: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor((checker && (x + y) % 2 == 0 ? NSColor.white : NSColor.black).cgColor)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try #require(context.makeImage())
    }

    @Test func testMosaicRemovesOriginalCheckerboardPixels() throws {
        let source = try image(checker: true)
        let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let result = try AnnotationRenderer.render(frames: [DisplayFrame(frame: rect, image: source)],
                                                   selection: rect,
                                                   annotations: [CaptureAnnotation(kind: .mosaic, rect: rect,
                                                                                   color: .red, lineWidth: 2)])
        let bytes = try #require(result.dataProvider?.data)
        let pointer = try #require(CFDataGetBytePtr(bytes))
        // 16x16 pixelation cells must be flat; the source alternates every pixel.
        #expect(pointer[0] == pointer[4])
        #expect(pointer[0] == pointer[15 * 4])
        #expect(result.width == 32)
    }

    @Test func testMixedScaleDisplaysComposeAtHighestScale() throws {
        let first = DisplayFrame(frame: CGRect(x: -16, y: 0, width: 16, height: 16),
                                 image: try image(width: 32, height: 32))
        let second = DisplayFrame(frame: CGRect(x: 0, y: 0, width: 16, height: 16),
                                  image: try image(width: 16, height: 16))
        let result = try AnnotationRenderer.render(frames: [first, second],
                                                   selection: CGRect(x: -8, y: 0, width: 16, height: 16),
                                                   annotations: [])
        #expect(result.width == 32)
        #expect(result.height == 32)
    }

    @Test func testEmptySelectionIsRejected() {
        #expect(throws: (any Error).self) {
            try AnnotationRenderer.render(frames: [], selection: .null, annotations: [])
        }
    }
}
