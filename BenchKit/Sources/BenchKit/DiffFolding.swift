import Foundation

/// A diff loaded with the whole file around its changes, cut down to the
/// changes and a few lines either side. Each stretch left out becomes one
/// "Show N lines" row that opens it in place.
public enum DiffFolding {
    /// Unchanged lines kept next to each change.
    public static let margin = 3

    public struct Result: Sendable {
        public var lines: [DiffLine]
        /// Fold rows, by their index in `lines`, each with its key for `expanded`.
        public var folds: [Int: Int] = [:]
        /// The ids of the lines each fold hides (or would, if it's open).
        public var hidden: [Int: Set<Int>] = [:]

        public init(lines: [DiffLine], folds: [Int: Int] = [:], hidden: [Int: Set<Int>] = [:]) {
            self.lines = lines
            self.folds = folds
            self.hidden = hidden
        }
    }

    /// `expanded` holds the keys of stretches already opened: each one's
    /// first new-file line number, which stays put while lines above it don't change.
    public static func fold(_ all: [DiffLine], expanded: Set<Int>) -> Result {
        // With the whole file in one hunk, its header says nothing.
        let lines = all.filter { $0.kind != .hunk }
        var result = Result(lines: [])
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .context else {
                result.lines.append(lines[index])
                index += 1
                continue
            }
            let start = index
            while index < lines.count, lines[index].kind == .context { index += 1 }
            let end = index
            // Keep lines next to a change: none above the first change, at
            // the top of the file, and none below the last.
            let keepTop = lines[..<start].contains(where: isChange) ? margin : 0
            let keepBottom = lines[end...].contains(where: isChange) ? margin : 0
            // One or two hidden lines aren't worth a row of their own.
            guard end - start - keepTop - keepBottom > 2 else {
                result.lines += lines[start..<end]
                continue
            }
            let hidden = (start + keepTop)..<(end - keepBottom)
            let key = lines[hidden.lowerBound].newNumber ?? lines[hidden.lowerBound].id
            result.hidden[key] = Set(lines[hidden].map(\.id))
            if expanded.contains(key) {
                result.lines += lines[start..<end]
                continue
            }
            result.lines += lines[start..<hidden.lowerBound]
            result.folds[result.lines.count] = key
            result.lines.append(DiffLine(id: -1 - lines[hidden.lowerBound].id, kind: .hunk,
                                         text: "Show \(hidden.count) lines", oldNumber: nil, newNumber: nil))
            result.lines += lines[hidden.upperBound..<end]
        }
        return result
    }

    /// The folds that hide any of `lines`, so comments on them show.
    public static func keys(hiding lines: [DiffLine], in all: [DiffLine]) -> Set<Int> {
        let wanted = Set(lines.map(\.id))
        return Set(fold(all, expanded: []).hidden.filter { !$0.value.isDisjoint(with: wanted) }.keys)
    }

    private static func isChange(_ line: DiffLine) -> Bool {
        line.kind == .added || line.kind == .removed
    }

    /// Where each run of added and removed lines starts, for stepping
    /// from change to change.
    public static func changeStarts(_ kinds: [DiffLine.Kind]) -> [Int] {
        kinds.indices.filter { index in
            let changed = kinds[index] == .added || kinds[index] == .removed
            let previous = index > 0 && (kinds[index - 1] == .added || kinds[index - 1] == .removed)
            return changed && !previous
        }
    }
}
