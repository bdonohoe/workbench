import Foundation
import Observation

/// What a model costs on the Claude API, in dollars per million tokens.
nonisolated struct ModelPrice: Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
    /// Above this many prompt tokens a request costs `longFactor` times as
    /// much (Haiku 5.5 only).
    var longThreshold: Int?
    var longFactor: Double = 1

    // Cache writes cost 1.25x input for 5 minutes, 2x for an hour.
    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2 }

    /// First-party API prices, matched on the model id without its date.
    /// Order matters: longer names first, so "opus-5-5" wins over "opus-5".
    static let table: [(String, ModelPrice)] = [
        ("fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("mythos-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.2)),
        ("opus-5", ModelPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("opus-4-8", ModelPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("opus-4-7", ModelPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("opus-4-6", ModelPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("opus-4-5", ModelPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("opus-4", ModelPrice(input: 15, output: 75, cacheRead: 1.5)),
        ("sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.2)),
        ("sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: 0.2)),
        ("sonnet-4", ModelPrice(input: 3, output: 15, cacheRead: 0.3)),
        ("sonnet-3", ModelPrice(input: 3, output: 15, cacheRead: 0.3)),
        ("haiku-5-5", ModelPrice(input: 0.1, output: 0.5, cacheRead: 0.01, longThreshold: 100_000, longFactor: 5)),
        ("haiku-4-5", ModelPrice(input: 1, output: 5, cacheRead: 0.1)),
        ("haiku-3-5", ModelPrice(input: 0.8, output: 4, cacheRead: 0.08)),
    ]

    /// Bump when prices change, so saved totals are counted again.
    static let version = 1

    static func price(for model: String) -> ModelPrice? {
        let id = model.lowercased()
        return table.first { id.contains($0.0) }?.1
    }
}

/// Tokens and estimated cost for some set of requests.
nonisolated struct UsageTally: Codable, Sendable, Equatable {
    var requests = 0
    var input = 0
    var cacheWrite = 0
    var cacheRead = 0
    var output = 0
    /// At API prices. 0 for a model without a known price.
    var cost: Double = 0
    /// What the same requests would cost with no prompt caching.
    var uncachedCost: Double = 0

    var promptTokens: Int { input + cacheWrite + cacheRead }
    var totalTokens: Int { promptTokens + output }

    static func + (a: UsageTally, b: UsageTally) -> UsageTally {
        UsageTally(requests: a.requests + b.requests, input: a.input + b.input, cacheWrite: a.cacheWrite + b.cacheWrite,
                   cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output,
                   cost: a.cost + b.cost, uncachedCost: a.uncachedCost + b.uncachedCost)
    }
    static func += (a: inout UsageTally, b: UsageTally) { a = a + b }
}

/// One day's usage of one model in one folder.
nonisolated struct UsageBucket: Codable, Sendable, Hashable {
    /// "2026-10-31", in local time.
    var day: String
    /// The model id without a date, like "claude-opus-5-5".
    var model: String
    /// The folder Claude ran in.
    var folder: String
}

/// Claude Code's token usage on this Mac, from its session transcripts in
/// ~/.claude/projects (and every other Claude account's folder), priced at
/// API rates.
///
/// Each transcript is read once and boiled down to daily totals, which are
/// saved. Claude Code deletes old transcripts after a while; their totals
/// stay, so history here can outlast them.
@Observable
final class UsageLedger {
    static let shared = UsageLedger()

    private(set) var buckets: [UsageBucket: UsageTally] = [:]
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    @ObservationIgnored private var files: [String: SavedFile] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    nonisolated private static let saveFile = BenchPaths.support.appendingPathComponent("usage-ledger.json")

    nonisolated struct SavedFile: Codable, Sendable {
        var size: Int
        var modified: Double
        var entries: [Entry]
    }

    nonisolated struct Entry: Codable, Sendable {
        var bucket: UsageBucket
        var tally: UsageTally
    }

    nonisolated private struct Saved: Codable, Sendable {
        var version: Int
        var files: [String: SavedFile]
    }

    /// Reads any transcripts that are new or changed since last time.
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        if !loaded { load() }
        let known = files
        Task.detached(priority: .utility) {
            var updated = Self.scan(known: known)
            await MainActor.run {
                // Background calls may have come in during the scan.
                for (path, file) in self.files where Self.isBackgroundCalls(path) { updated[path] = file }
                self.files = updated
                self.rebuild()
                self.isScanning = false
                self.lastScan = .now
                self.save()
            }
        }
    }

    private func load() {
        loaded = true
        guard let data = try? Data(contentsOf: Self.saveFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == ModelPrice.version else { return }
        files = saved.files
        rebuild()
    }

    private func save() {
        let saved = Saved(version: ModelPrice.version, files: files)
        Task.detached(priority: .background) {
            do {
                try JSONEncoder().encode(saved).write(to: Self.saveFile, options: .atomic)
            } catch {
                NSLog("Bench: couldn't save the usage ledger: \(error)")
            }
        }
    }

    private func rebuild() {
        var all: [UsageBucket: UsageTally] = [:]
        for file in files.values {
            for entry in file.entries { all[entry.bucket, default: UsageTally()] += entry.tally }
        }
        buckets = all
    }

    #if DEBUG
    /// Scans every transcript from scratch and prints the totals by model.
    static func printReport() {
        let start = Date()
        let files = scan(known: [:])
        var byModel: [String: UsageTally] = [:]
        for file in files.values {
            for entry in file.entries { byModel[entry.bucket.model, default: UsageTally()] += entry.tally }
        }
        print("Scanned \(files.count) files in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        for (model, tally) in byModel.sorted(by: { $0.value.cost > $1.value.cost }) {
            print(model, tally.requests, "cost", String(format: "%.2f", tally.cost),
                  "uncached", String(format: "%.2f", tally.uncachedCost), "out", tally.output, "read", tally.cacheRead)
        }
        print("TOTAL", String(format: "%.2f", byModel.values.reduce(UsageTally(), +).cost))
    }

    /// Fills the ledger right away, for rendering the page in tests.
    func loadNow() {
        files = Self.scan(known: [:])
        rebuild()
        lastScan = .now
    }
    #endif

    // MARK: Background calls

    /// Recaps and Brain Dump leave no transcript, so they report here. Each
    /// account's calls are kept under a made-up path in its projects folder:
    /// no scan ever touches it, and they count for that account like the rest.
    func recordBackground(_ tally: UsageTally, model: String, profile: ClaudeProfile, at date: Date = .now) {
        if !loaded { load() }
        let path = profile.projectsURL.appendingPathComponent(Self.backgroundCallsName).path
        let bucket = UsageBucket(day: Self.dayFormatter.string(from: date), model: Self.undatedModel(model), folder: Self.backgroundCallsLabel)
        var file = files[path] ?? SavedFile(size: 0, modified: 0, entries: [])
        if let index = file.entries.firstIndex(where: { $0.bucket == bucket }) {
            file.entries[index].tally += tally
        } else {
            file.entries.append(Entry(bucket: bucket, tally: tally))
        }
        files[path] = file
        buckets[bucket, default: UsageTally()] += tally
        saveSoon()
    }

    nonisolated private static let backgroundCallsName = "workbench-background-calls"
    /// Stands in for a folder, and is how the Usage page's By Project table names these.
    nonisolated private static let backgroundCallsLabel = "Recaps and Brain Dump"

    nonisolated private static func isBackgroundCalls(_ path: String) -> Bool {
        path.hasSuffix("/" + backgroundCallsName)
    }

    /// The ledger can be large and these calls can come often, so one save
    /// covers a burst of them.
    private func saveSoon() {
        guard pendingSave == nil else { return }
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(30))
            pendingSave = nil
            save()
        }
    }

    // MARK: Reading transcripts

    nonisolated private static func scan(known: [String: SavedFile]) -> [String: SavedFile] {
        var result = known
        // Every account's sessions, from every agent.
        for reader in Agents.allTranscripts {
            for account in ClaudeAccounts.all {
                for url in reader.allSessionFiles(account: account) {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = values?.fileSize ?? 0
                    let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    if let old = known[url.path], old.size == size, old.modified == modified { continue }
                    result[url.path] = SavedFile(size: size, modified: modified, entries: reader.ledgerEntries(in: url))
                }
            }
        }
        return result
    }

    /// What everything since the start of `day` cost at API prices.
    func cost(since day: Date) -> Double {
        if !loaded { load() }
        let first = Self.dayFormatter.string(from: day)
        return buckets.reduce(0) { $1.key.day >= first ? $0 + $1.value.cost : $0 }
    }

    /// The same, for one Claude account's sessions only.
    func cost(since day: Date, in profile: ClaudeProfile) -> Double {
        if !loaded { load() }
        let first = Self.dayFormatter.string(from: day)
        let root = profile.projectsURL.standardizedFileURL.path + "/"
        var total = 0.0
        for (path, file) in files where URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root) {
            for entry in file.entries where entry.bucket.day >= first { total += entry.tally.cost }
        }
        return total
    }

    nonisolated static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// One of Claude Code's transcripts' daily totals. A reply is written
    /// several times as it streams, so each message counts once.
    nonisolated static func readClaude(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var seen = Set<String>()
        var totals: [UsageBucket: UsageTally] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Find lines with token usage by their bytes, and parse only those.
        let marker = Array("\"usage\"".utf8)
        var lines: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let count = raw.count
            while offset < count {
                let start = base + offset
                let remaining = count - offset
                let length = memchr(start, Int32(UInt8(ascii: "\n")), remaining).map { UnsafeRawPointer($0) - start } ?? remaining
                if marker.withUnsafeBytes({ memmem(start, length, $0.baseAddress, marker.count) }) != nil {
                    lines.append(Data(bytes: start, count: length))
                }
                offset += length + 1
            }
        }
        for line in lines {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let rawModel = message["model"] as? String, rawModel.hasPrefix("claude") else { continue }
            let key = "\(message["id"] as? String ?? "")|\(entry["requestId"] as? String ?? "")"
            guard seen.insert(key).inserted else { continue }

            let date = (entry["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            let model = undatedModel(rawModel)
            let bucket = UsageBucket(day: dayFormatter.string(from: date), model: model, folder: entry["cwd"] as? String ?? "")
            totals[bucket, default: UsageTally()] += tally(usage: usage, model: model)
        }
        return totals.map { Entry(bucket: $0.key, tally: $0.value) }
    }

    nonisolated private static func undatedModel(_ model: String) -> String {
        model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }

    nonisolated static func tally(usage: [String: Any], model: String) -> UsageTally {
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let input = int(usage["input_tokens"])
        let write = int(usage["cache_creation_input_tokens"])
        let read = int(usage["cache_read_input_tokens"])
        let output = int(usage["output_tokens"])
        var write1h = 0
        if let split = usage["cache_creation"] as? [String: Any] { write1h = int(split["ephemeral_1h_input_tokens"]) }
        let write5m = max(write - write1h, 0)

        var tally = UsageTally(requests: 1, input: input, cacheWrite: write, cacheRead: read, output: output)
        guard let price = ModelPrice.price(for: model) else { return tally }
        let prompt = input + write + read
        var factor = (price.longThreshold.map { prompt > $0 } ?? false) ? price.longFactor : 1
        // Fast mode costs twice as much.
        if usage["speed"] as? String == "fast" { factor *= 2 }
        let million = 1_000_000.0
        tally.cost = factor * (Double(input) * price.input + Double(write5m) * price.cacheWrite5m
            + Double(write1h) * price.cacheWrite1h + Double(read) * price.cacheRead + Double(output) * price.output) / million
        tally.uncachedCost = factor * (Double(prompt) * price.input + Double(output) * price.output) / million
        return tally
    }
}
