import Foundation
import Testing
@testable import SuperCapture

struct ScrollStitcherTests {
    /// Deterministic pseudo-random page content: every row is generated from
    /// its own LCG seed, so a row matches another row only at the true offset.
    private func content(width: Int, height: Int, seedBase: UInt32 = 0) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            var state = (UInt32(row) &+ seedBase) &* 2_654_435_761 &+ 2_246_822_519
            for col in 0..<width {
                state = state &* 1_664_525 &+ 1_013_904_223
                pixels[row * width + col] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        return pixels
    }

    private func frame(from content: [UInt8], width: Int, height: Int, startRow: Int) -> GrayFrame {
        let slice = Array(content[(startRow * width)..<((startRow + height) * width)])
        return GrayFrame(width: width, height: height, pixels: slice)
    }

    @Test func testDetectsDownwardScroll() {
        let width = 160, frameHeight = 300
        let page = content(width: width, height: 900)
        let previous = frame(from: page, width: width, height: frameHeight, startRow: 100)
        let current = frame(from: page, width: width, height: frameHeight, startRow: 237)
        #expect(ScrollStitcher.verticalOffset(previous: previous, current: current) == 137)
    }

    @Test func testDetectsUpwardScroll() {
        let width = 160, frameHeight = 300
        let page = content(width: width, height: 900)
        let previous = frame(from: page, width: width, height: frameHeight, startRow: 300)
        let current = frame(from: page, width: width, height: frameHeight, startRow: 236)
        #expect(ScrollStitcher.verticalOffset(previous: previous, current: current) == -64)
    }

    @Test func testIdenticalFramesReportZero() {
        let width = 160, frameHeight = 300
        let page = content(width: width, height: 900)
        let frame = frame(from: page, width: width, height: frameHeight, startRow: 42)
        #expect(ScrollStitcher.verticalOffset(previous: frame, current: frame) == 0)
        #expect(ScrollStitcher.meanAbsoluteDifference(frame, frame) == 0)
    }

    @Test func testUnrelatedFramesReportNil() {
        let width = 160, frameHeight = 300
        let first = frame(from: content(width: width, height: frameHeight, seedBase: 7),
                          width: width, height: frameHeight, startRow: 0)
        let second = frame(from: content(width: width, height: frameHeight, seedBase: 999_331),
                           width: width, height: frameHeight, startRow: 0)
        #expect(ScrollStitcher.verticalOffset(previous: first, current: second) == nil)
    }

    @Test func testSizeMismatchReportsNil() {
        let small = GrayFrame(width: 160, height: 300, pixels: [UInt8](repeating: 3, count: 160 * 300))
        let large = GrayFrame(width: 160, height: 301, pixels: [UInt8](repeating: 3, count: 160 * 301))
        #expect(ScrollStitcher.verticalOffset(previous: small, current: large) == nil)
    }

    /// Text-like page: white background, dark glyph runs on a fixed line
    /// pitch, lightly blurred vertically the way rendered text is. Unlike
    /// the noise page above, rows repeat structurally (same pitch, similar
    /// density) — what real articles and chat logs actually look like.
    private func textPage(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height)
        var line = 0
        var y = 24
        while y + 11 < height {
            var state = UInt32(line &+ 1) &* 2_654_435_761 &+ 2_246_822_519
            func next() -> UInt32 {
                state = state &* 1_664_525 &+ 1_013_904_223
                return state >> 24
            }
            var x = Int(next() % 12)
            while x < width - 16 {
                let segment = 10 + Int(next() % 30)
                for row in y..<(y + 11) {
                    for col in x..<min(x + segment, width) where next() % 5 != 0 {
                        pixels[row * width + col] = UInt8(30 + next() % 80)
                    }
                }
                x += segment + 5 + Int(next() % 12)
            }
            y += 30
            line += 1
        }
        // One vertical 3-tap blur pass, mimicking anti-aliased text edges.
        var blurred = pixels
        for row in 1..<(height - 1) {
            for col in 0..<width {
                let i = row * width + col
                blurred[i] = UInt8((Int(pixels[i - width]) + 2 * Int(pixels[i]) + Int(pixels[i + width])) / 4)
            }
        }
        return blurred
    }

    private func blended(_ a: GrayFrame, _ b: GrayFrame) -> GrayFrame {
        GrayFrame(width: a.width, height: a.height,
                  pixels: zip(a.pixels, b.pixels).map { UInt8((Int($0) + Int($1)) / 2) })
    }

    @Test func testTextLikePageScrollsDown() {
        let width = 160, frameHeight = 300
        let page = textPage(width: width, height: 900)
        let previous = frame(from: page, width: width, height: frameHeight, startRow: 100)
        let current = frame(from: page, width: width, height: frameHeight, startRow: 190)
        #expect(ScrollStitcher.verticalOffset(previous: previous, current: current) == 90)
    }

    @Test func testHalfPixelOffsetStillStitches() {
        let width = 160, frameHeight = 300
        let page = textPage(width: width, height: 900)
        let previous = frame(from: page, width: width, height: frameHeight, startRow: 100)
        let at60 = frame(from: page, width: width, height: frameHeight, startRow: 160)
        let at61 = frame(from: page, width: width, height: frameHeight, startRow: 161)
        // Content resting half a pixel past the 60-row shift matches the 60
        // and 61 shifts almost equally well; the uniqueness gate used to
        // reject that outright, so no slice ever stitched.
        let dy = ScrollStitcher.verticalOffset(previous: previous, current: blended(at60, at61))
        #expect(dy == 60 || dy == 61)
    }
}
