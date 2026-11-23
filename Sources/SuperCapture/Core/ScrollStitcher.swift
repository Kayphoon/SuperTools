import Foundation

/// One frame of a scroll-capture region reduced to 8-bit grayscale rows
/// (top row first, row-major). Used only for offset detection between
/// consecutive frames; the color frames themselves are composited by the
/// capture session, never by this type.
public struct GrayFrame: Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height,
                     "GrayFrame pixel count must equal width * height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Pure vertical-overlap matching for manual scroll capture.
///
/// The user scrolls the target window by hand; the session photographs the
/// region several times per second and asks here how far the content moved
/// between two photographs. Matching samples a horizontal band in the middle
/// of the frame (away from sticky headers/footers at the edges) and searches
/// every integer shift for the lowest mean absolute difference.
public enum ScrollStitcher {
    /// How far the content moved from `previous` to `current`, in pixels.
    ///
    /// A positive result means the user scrolled down: the content moved up
    /// inside the region, so `current` shows what sat `dy` pixels lower in
    /// `previous`. A negative result is an upward scroll. Returns 0 when the
    /// frames are effectively identical and nil when no alignment is reliable
    /// (blank region, unrelated frames, or a jump larger than the overlap).
    public static func verticalOffset(previous: GrayFrame, current: GrayFrame) -> Int? {
        guard previous.width == current.width, previous.height == current.height else { return nil }
        let width = previous.width, height = previous.height
        guard width >= 8, height >= 40 else { return nil }

        // Sample a fixed grid so cost stays bounded on Retina-sized regions:
        // up to 36 rows from the middle band and up to 120 columns.
        let bandTop = height / 4
        let bandBottom = (3 * height) / 4
        let rowCount = min(36, bandBottom - bandTop)
        let colCount = min(120, width)
        guard rowCount >= 8, colCount >= 8 else { return nil }
        var rows: [Int] = []
        rows.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            rows.append(bandTop + index * (bandBottom - bandTop) / rowCount)
        }
        var cols: [Int] = []
        cols.reserveCapacity(colCount)
        for index in 0..<colCount {
            cols.append(index * width / colCount)
        }

        func meanDifference(_ dy: Int) -> Double {
            var sum = 0
            var count = 0
            for row in rows {
                let currentRow = row - dy
                guard currentRow >= 0, currentRow < height else { continue }
                let previousBase = row * width
                let currentBase = currentRow * width
                for col in cols {
                    sum += abs(Int(previous.pixels[previousBase + col]) - Int(current.pixels[currentBase + col]))
                    count += 1
                }
            }
            // A shift that pushes the sample band out of the frame is not a match.
            guard count >= (rowCount * colCount) / 2 else { return .infinity }
            return Double(sum) / Double(count)
        }

        // Keep at least a quarter of the frame overlapping so the band always
        // has real content to compare.
        let maxShift = height - height / 4
        var bestDy = 0
        var best = meanDifference(0)
        var second = Double.infinity
        for dy in stride(from: -maxShift, through: maxShift, by: 1) where dy != 0 {
            let score = meanDifference(dy)
            if score < best {
                second = best
                best = score
                bestDy = dy
            } else if score < second {
                second = score
            }
        }
        if bestDy == 0 { return best <= 10 ? 0 : nil }
        // The winning alignment must be near-exact and clearly better than the
        // runner-up; uniform or unrelated content fails both checks.
        guard best <= 10, best <= 3 || best + 2 <= second else { return nil }
        return bestDy
    }

    /// Mean absolute pixel difference over a sparse sample grid.
    /// Used by the session as a cheap "nothing moved" check before matching.
    public static func meanAbsoluteDifference(_ lhs: GrayFrame, _ rhs: GrayFrame) -> Double {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return .infinity }
        let width = lhs.width, height = lhs.height
        let rowStep = max(1, height / 24)
        let colStep = max(1, width / 48)
        var sum = 0
        var count = 0
        var row = 0
        while row < height {
            let base = row * width
            var col = 0
            while col < width {
                sum += abs(Int(lhs.pixels[base + col]) - Int(rhs.pixels[base + col]))
                count += 1
                col += colStep
            }
            row += rowStep
        }
        return count == 0 ? .infinity : Double(sum) / Double(count)
    }
}
