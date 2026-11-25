import Foundation

/// What a piece of code is, for coloring it: the Mac's highlighter works
/// it out, and each app picks its own color for each kind.
public enum CodeKind: String, Codable, Sendable, Hashable {
    case keyword, string, comment, number, function, type, tag, builtin
}

/// A stretch of text to color, in UTF-16 units: within its line for a
/// `DiffLine`, or from the start of the file for a whole file.
public struct CodeRun: Codable, Sendable, Hashable {
    public var start: Int
    public var length: Int
    public var kind: CodeKind

    public init(start: Int, length: Int, kind: CodeKind) {
        self.start = start
        self.length = length
        self.kind = kind
    }
}

extension DiffLayout {
    /// Runs over the whole layout, cut up by line and moved to be
    /// relative to the start of each line. Index matches `ranges`.
    public func runsByLine(_ runs: [CodeRun]) -> [[CodeRun]] {
        var result = Array(repeating: [CodeRun](), count: ranges.count)
        for run in runs {
            guard var index = line(at: run.start) else { continue }
            let end = run.start + run.length
            while index < ranges.count, ranges[index].location < end {
                let range = ranges[index]
                let start = max(run.start, range.location), stop = min(end, NSMaxRange(range))
                if stop > start {
                    result[index].append(CodeRun(start: start - range.location, length: stop - start, kind: run.kind))
                }
                index += 1
            }
        }
        return result
    }
}
