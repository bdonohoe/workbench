import Foundation

/// An array that decodes what it can and drops the rest. For saved lists
/// where one entry written by a newer build (a tab kind this build doesn't
/// know, say) shouldn't lose the whole file.
@propertyWrapper
struct LossyArray<Element: Codable & Hashable>: Codable, Hashable {
    var wrappedValue: [Element]

    init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var kept: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                kept.append(element)
            } else {
                // Move past the entry that failed, or the loop never ends.
                _ = try? container.decode(Skipped.self)
                dropped += 1
            }
        }
        if dropped > 0 { NSLog("Bench: dropped \(dropped) saved \(Element.self) entries that couldn't be read") }
        wrappedValue = kept
    }

    func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }

    /// Decodes as anything, to step over an entry.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension KeyedDecodingContainer {
    /// A missing list reads as empty, as a plain `[T] = []` would not.
    func decode<T>(_ type: LossyArray<T>.Type, forKey key: Key) throws -> LossyArray<T> {
        try decodeIfPresent(type, forKey: key) ?? LossyArray(wrappedValue: [])
    }
}
