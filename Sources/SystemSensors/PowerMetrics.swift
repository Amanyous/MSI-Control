import Foundation

public enum PowerMetrics {
    // Only accept measured absolute MHz, never "% of nominal" or nominal sysctl values.
    public static func frequency(in output: String) -> Double? {
        let normalized = output.replacingOccurrences(of: "\r", with: "\n")
        let pattern = #"(?im)^\s*(?:System Average frequency as fraction of nominal|CPU Average frequency|Average frequency(?: as fraction of nominal)?)\s*:\s*(?:[0-9]+(?:\.[0-9]+)?%\s*\()?([0-9]+(?:\.[0-9]+)?)\s*MHz\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let range = Range(match.range(at: 1), in: normalized),
              let mhz = Double(normalized[range]), (50...10000).contains(mhz) else { return nil }
        return mhz / 1000
    }
}
