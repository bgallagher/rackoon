import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum HighlightKind: Sendable, Equatable {
    case ipAddress, error, warning, success
}

/// A highlighted stretch of text, as UTF-8 byte offsets into the text that was scanned.
public struct HighlightSpan: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var kind: HighlightKind
}

/// Finds things worth colouring in plain terminal output: IP addresses, error/warning/success words and
/// high percentages. Conservative on purpose: only whole words, only unambiguous patterns.
public enum OutputHighlighter {
    private static func regex(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)  // constant patterns, covered by unit tests
    }

    private static let octet = #"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"#
    private static let ipv4 = regex(#"(?<![\w.])"# + octet + #"(?:\."# + octet + #"){3}(?![\w]|\.\d)"#)
    private static let ipv6Candidate = regex(#"(?<![\w:.])[0-9A-Fa-f:]{3,}(?![\w:])"#)
    private static let errorWords = regex(#"\b(?:error|failed|failure|fatal|denied|refused|critical|panic)\b"#, .caseInsensitive)
    private static let warningWords = regex(#"\b(?:warning|warn)\b"#, .caseInsensitive)
    private static let successWords = regex(#"\b(?:success|successful|successfully|passed)\b"#, .caseInsensitive)
    private static let percent = regex(#"(?<![\w.])(\d{1,3})(?:\.\d+)?%"#)

    public static func spans(in text: String) -> [HighlightSpan] {
        let full = NSRange(text.startIndex..., in: text)
        var found: [HighlightSpan] = []

        func add(_ re: NSRegularExpression, group: Int = 0, _ kind: (NSTextCheckingResult) -> HighlightKind?) {
            // `matches` rather than `enumerateMatches`: on Linux Foundation the latter takes an escaping closure.
            for m in re.matches(in: text, range: full) {
                guard let k = kind(m), let r = Range(m.range(at: group), in: text) else { continue }
                found.append(HighlightSpan(start: text.utf8.distance(from: text.utf8.startIndex, to: r.lowerBound),
                                           end: text.utf8.distance(from: text.utf8.startIndex, to: r.upperBound), kind: k))
            }
        }

        add(ipv4) { _ in .ipAddress }
        add(ipv6Candidate) { m in
            guard let r = Range(m.range, in: text), isIPv6(String(text[r])) else { return nil }
            return .ipAddress
        }
        add(errorWords) { _ in .error }
        add(warningWords) { _ in .warning }
        add(successWords) { _ in .success }
        add(percent) { m in
            guard let r = Range(m.range(at: 1), in: text), let v = Int(text[r]) else { return nil }
            return v >= 90 ? .error : (v >= 75 ? .warning : nil)   // the span is the whole "91%"
        }
        return resolve(found)
    }

    /// Sorted, non-overlapping: when two spans overlap the earlier one wins, and for a tie the first found.
    static func resolve(_ spans: [HighlightSpan]) -> [HighlightSpan] {
        var result: [HighlightSpan] = []
        for s in spans.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let last = result.last, s.start < last.end { continue }
            result.append(s)
        }
        return result
    }

    /// A real IPv6 address: parses, and is written with `::` or all 8 groups, so times (11:26:02)
    /// and MAC addresses (aa:bb:cc:dd:ee:ff) are never mistaken for one.
    static func isIPv6(_ s: String) -> Bool {
        guard s.contains(":"), s.contains("::") || s.filter({ $0 == ":" }).count == 7 else { return false }
        var addr = in6_addr()
        return inet_pton(AF_INET6, s, &addr) == 1
    }
}
