//
//  TreemapLayout.swift
//  TreemapKit
//
//  Squarified treemap layout (Bruls, Huizing, van Wijk, 2000).
//

#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum TreemapLayout {
    /// Lays out `weights` inside `rect` using the squarified algorithm.
    /// Returns one rect per weight, in the same order. Weights must be non-negative;
    /// zero-weight entries produce empty rects at the current layout cursor.
    public nonisolated static func squarify(weights: [Double], in rect: CGRect) -> [CGRect] {
        guard !weights.isEmpty else { return [] }

        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0, rect.width > 0, rect.height > 0 else {
            return Array(repeating: CGRect(origin: rect.origin, size: .zero), count: weights.count)
        }

        // Scale weights so they sum to the rect's area.
        let scale = Double(rect.width * rect.height) / totalWeight
        let areas = weights.map { $0 * scale }

        var results = Array(repeating: CGRect.zero, count: weights.count)
        var remaining = rect
        var rowStart = 0

        while rowStart < areas.count {
            let shortSide = Double(min(remaining.width, remaining.height))
            guard shortSide > 0 else {
                for index in rowStart..<areas.count {
                    results[index] = CGRect(origin: remaining.origin, size: .zero)
                }
                break
            }

            // Grow the current row while it improves the worst aspect ratio.
            var rowEnd = rowStart + 1
            var rowArea = areas[rowStart]
            var rowMin = areas[rowStart]
            var rowMax = areas[rowStart]
            var worst = worstAspectRatio(
                rowArea: rowArea, minArea: rowMin, maxArea: rowMax, shortSide: shortSide
            )

            while rowEnd < areas.count {
                let candidate = areas[rowEnd]
                let nextArea = rowArea + candidate
                let nextMin = min(rowMin, candidate)
                let nextMax = max(rowMax, candidate)
                let nextWorst = worstAspectRatio(
                    rowArea: nextArea, minArea: nextMin, maxArea: nextMax, shortSide: shortSide
                )
                if nextWorst > worst {
                    break
                }
                rowArea = nextArea
                rowMin = nextMin
                rowMax = nextMax
                worst = nextWorst
                rowEnd += 1
            }

            layoutRow(
                areas: areas[rowStart..<rowEnd],
                rowArea: rowArea,
                in: &remaining,
                writingTo: &results,
                startIndex: rowStart
            )
            rowStart = rowEnd
        }

        return results
    }

    private nonisolated static func worstAspectRatio(
        rowArea: Double,
        minArea: Double,
        maxArea: Double,
        shortSide: Double
    ) -> Double {
        guard rowArea > 0, minArea > 0 else { return .infinity }
        let sideSquared = shortSide * shortSide
        let areaSquared = rowArea * rowArea
        return max(
            (sideSquared * maxArea) / areaSquared,
            areaSquared / (sideSquared * minArea)
        )
    }

    /// Slices one row of cells off `remaining`, along its short side.
    private nonisolated static func layoutRow(
        areas: ArraySlice<Double>,
        rowArea: Double,
        in remaining: inout CGRect,
        writingTo results: inout [CGRect],
        startIndex: Int
    ) {
        guard rowArea > 0 else {
            for index in areas.indices {
                results[index] = CGRect(origin: remaining.origin, size: .zero)
            }
            return
        }

        let horizontalRow = remaining.width >= remaining.height

        if horizontalRow {
            // Row is a vertical strip on the left edge; cells stack top to bottom.
            let stripWidth = CGFloat(rowArea / Double(remaining.height))
            var y = remaining.minY
            for index in areas.indices {
                let cellHeight = CGFloat(areas[index] / rowArea) * remaining.height
                results[index] = CGRect(x: remaining.minX, y: y, width: stripWidth, height: cellHeight)
                y += cellHeight
            }
            remaining = CGRect(
                x: remaining.minX + stripWidth,
                y: remaining.minY,
                width: max(0, remaining.width - stripWidth),
                height: remaining.height
            )
        } else {
            // Row is a horizontal strip on the top edge; cells run left to right.
            let stripHeight = CGFloat(rowArea / Double(remaining.width))
            var x = remaining.minX
            for index in areas.indices {
                let cellWidth = CGFloat(areas[index] / rowArea) * remaining.width
                results[index] = CGRect(x: x, y: remaining.minY, width: cellWidth, height: stripHeight)
                x += cellWidth
            }
            remaining = CGRect(
                x: remaining.minX,
                y: remaining.minY + stripHeight,
                width: remaining.width,
                height: max(0, remaining.height - stripHeight)
            )
        }
    }
}
