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
}
