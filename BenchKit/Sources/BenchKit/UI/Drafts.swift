import Foundation

/// What you've typed into each conversation's message box but not sent,
/// so it's still there when you come back from another project. Text is
/// kept on disk too, so it survives quitting the app; attachments are
/// kept while the app runs.
@MainActor public enum Drafts {
    private static var saved: [String: Any] = [:]
    private static let storeKey = "drafts.text"
    private static var stored: [String: String] = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
    /// The write to disk, a moment after the last keystroke rather than
    /// the whole dictionary on every one.
    private static var flush: Task<Void, Never>?

    public static func load<Value>(_ key: String, as type: Value.Type = Value.self) -> Value? {
        if let value = saved[key] as? Value { return value }
        return key.hasSuffix(".text") ? stored[key] as? Value : nil
    }

    /// Saves it, or forgets it when nil.
    public static func save(_ value: Any?, for key: String) {
        saved[key] = value
        guard key.hasSuffix(".text") else { return }
        let text = value as? String
        guard stored[key] != text else { return }
        stored[key] = text
        // Old drafts for conversations long gone shouldn't pile up.
        if stored.count > 200 { stored = Dictionary(uniqueKeysWithValues: stored.suffix(150).map { ($0.key, $0.value) }) }
        flush?.cancel()
        flush = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(stored, forKey: storeKey)
        }
    }
}
