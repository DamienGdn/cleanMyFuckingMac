import CoreGraphics

/// Squarified treemap (Bruls, Huizing, van Wijk). Values must be sorted largest first.
public enum Treemap {
    public static func layout(values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }

        var free = rect
        var index = 0
        while index < areas.count {
            let side = Double(min(free.width, free.height))
            guard side > 0 else { break }
            var rowMin = areas[index], rowMax = areas[index], sum = areas[index]
            var end = index + 1
            while end < areas.count, areas[end] > 0 {
                let candidate = areas[end]
                let newWorst = worst(min: min(rowMin, candidate), max: max(rowMax, candidate), sum: sum + candidate, side: side)
                guard newWorst <= worst(min: rowMin, max: rowMax, sum: sum, side: side) else { break }
                rowMin = min(rowMin, candidate)
                rowMax = max(rowMax, candidate)
                sum += candidate
                end += 1
            }

            let thickness = sum / side
            let vertical = free.width >= free.height
            var offset = 0.0
            for item in index..<end {
                let length = thickness > 0 ? areas[item] / thickness : 0
                result[item] = vertical
                    ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                    : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                offset += length
            }
            free = vertical
                ? CGRect(x: free.minX + thickness, y: free.minY, width: free.width - thickness, height: free.height)
                : CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: free.height - thickness)
            index = end
        }
        return result
    }

    /// Worst aspect ratio of a row laid along `side`.
    private static func worst(min rowMin: Double, max rowMax: Double, sum: Double, side: Double) -> Double {
        guard rowMin > 0, sum > 0 else { return .infinity }
        let side2 = side * side, sum2 = sum * sum
        return max(side2 * rowMax / sum2, sum2 / (side2 * rowMin))
    }
}
