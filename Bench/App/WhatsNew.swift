import AppKit
import Foundation
import Observation
import SwiftUI

/// One version's release notes, from the update feed.
struct ReleaseNote: Identifiable, Equatable {
    var version: String
    var build: Int
    var date: Date?
    var blocks: [ReleaseNoteBlock]

    var id: Int { build }
}

/// Release notes are a little HTML: headings, paragraphs, and bullet lists
/// with bold and code inside. These are those, ready for SwiftUI.
enum ReleaseNoteBlock: Equatable {
    case heading(AttributedString)
    case paragraph(AttributedString)
    case bullets([AttributedString])
    /// A screenshot, with its description for VoiceOver.
    case image(URL, alt: String)

    /// Reads the HTML that scripts/appcast.py writes.
    static func parse(html: String) -> [ReleaseNoteBlock] {
        let pattern = #"<(h\d|p|ul)>(.*?)</\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let source = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let tag = source.substring(with: match.range(at: 1))
            let body = source.substring(with: match.range(at: 2))
            switch tag {
            case "p" where body.contains("<img"):
                guard let src = attribute("src", in: body).flatMap(URL.init(string:)) else { return nil }
                return .image(src, alt: attribute("alt", in: body) ?? "")
            case "p": return .paragraph(inline(body))
            case "ul":
                let items = body.components(separatedBy: "<li>").map { $0.replacingOccurrences(of: "</li>", with: "") }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                return .bullets(items.map(inline))
            default: return .heading(inline(body))
            }
        }
    }

    /// An attribute's value in a tag, like an image's src.
    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: #"\#(name)="([^"]*)""#, options: .regularExpression) else { return nil }
        let value = tag[range].dropFirst(name.count + 2).dropLast()
        return String(value).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
    }

    /// Bold and code become Markdown, the rest of the tags go, and the
    /// entities turn back into characters.
    private static func inline(_ html: String) -> AttributedString {
        var text = html
            .replacingOccurrences(of: "<strong>", with: "**").replacingOccurrences(of: "</strong>", with: "**")
            .replacingOccurrences(of: "<code>", with: "`").replacingOccurrences(of: "</code>", with: "`")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Reads release notes from the same feed Sparkle checks.
enum ReleaseFeed {
    static var url: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
    }

    /// This copy of Bench's build number.
    static var currentBuild: Int {
        #if DEBUG
        if let build = ProcessInfo.processInfo.environment["BENCH_CURRENT_BUILD"].flatMap(Int.init) { return build }
        #endif
        return Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// Every version in the feed, newest first. Nil when it can't be read.
    static func load() async -> [ReleaseNote]? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> [ReleaseNote] {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.notes.sorted { $0.build > $1.build }
    }

    private final class FeedReader: NSObject, XMLParserDelegate {
        var notes: [ReleaseNote] = []
        private var item: [String: String]?
        private var text = ""
        private static let dates: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" { item = [:] }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard item != nil else { return }
            if name == "item" {
                if let item, let build = item["sparkle:version"].flatMap({ Int($0) }) {
                    notes.append(ReleaseNote(
                        version: item["sparkle:shortVersionString"] ?? String(build), build: build,
                        date: item["pubDate"].flatMap { Self.dates.date(from: $0) },
                        blocks: ReleaseNoteBlock.parse(html: item["description"] ?? "")))
                }
                item = nil
            } else {
                item?[qualifiedName ?? name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

/// After an update, shows what changed since the version you last ran.
/// Also behind Bench > What's New.
@Observable
final class WhatsNew {
    static let lastSeenKey = "lastSeenBuild"

    /// What the window shows.
    private(set) var notes: [ReleaseNote] = []
    private(set) var isLoading = false
    private(set) var failed = false
    /// Right after an update, until you open What's New or close the
    /// sidebar card that offers it.
    var showsUpdatedCard = false
    /// The build you last ran, so notes newer than it are marked new.
    private(set) var previousBuild: Int?

    init() {
        let defaults = UserDefaults.standard
        let current = ReleaseFeed.currentBuild
        var last = defaults.object(forKey: Self.lastSeenKey) == nil ? nil : defaults.integer(forKey: Self.lastSeenKey)
        #if DEBUG
        // Pretend to have just updated from this build.
        if let since = ProcessInfo.processInfo.environment["BENCH_WHATS_NEW_SINCE"].flatMap(Int.init) { last = since }
        #endif
        // A first launch has nothing to compare against, and isn't an update.
        if let last, last < current {
            previousBuild = last
            showsUpdatedCard = true
        }
        #if !DEBUG
        defaults.set(current, forKey: Self.lastSeenKey)
        #endif
    }

    /// Reads the feed. After an update, keeps the versions since the one
    /// you ran last; otherwise the latest few.
    func load() async {
        isLoading = true
        failed = false
        defer { isLoading = false }
        guard var all = await ReleaseFeed.load() else {
            failed = notes.isEmpty
            return
        }
        all = all.filter { $0.build <= ReleaseFeed.currentBuild }
        notes = Array(all.prefix(max(5, all.filter { $0.build > (previousBuild ?? .max) }.count)))
    }

    func isNew(_ note: ReleaseNote) -> Bool {
        guard let previousBuild else { return false }
        return note.build > previousBuild
    }
}

/// The What's New window.
struct WhatsNewView: View {
    @Environment(WhatsNew.self) private var whatsNew
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if whatsNew.notes.isEmpty {
                        if whatsNew.failed {
                            Text("Couldn't load the release notes. Check your connection and try again.")
                                .foregroundStyle(.secondary)
                            Button("Try Again") { Task { await whatsNew.load() } }
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(whatsNew.notes) { note in
                        ReleaseNoteView(note: note, isNew: whatsNew.isNew(note))
                        if note != whatsNew.notes.last { Divider() }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.prominent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 460, idealWidth: 540, minHeight: 360, idealHeight: 620)
        .task { if whatsNew.notes.isEmpty { await whatsNew.load() } }
        // Seen it, so the sidebar card's job is done.
        .onAppear { whatsNew.showsUpdatedCard = false }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(whatsNew.previousBuild == nil ? "What's new in Workbench" : "Workbench is up to date")
                    .font(.ui(size: 20, weight: .semibold))
                Text(subtitle)
                    .font(.ui(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let count = whatsNew.notes.filter(whatsNew.isNew).count
        if whatsNew.previousBuild != nil, count > 1 {
            return "You're on \(version). Here's what changed in the \(count) versions since you last opened it."
        }
        if whatsNew.previousBuild != nil { return "You're on \(version). Here's what changed." }
        return "You're on \(version). Here's what changed in recent versions."
    }
}

/// One version's notes.
struct ReleaseNoteView: View {
    let note: ReleaseNote
    var isNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Workbench \(note.version)")
                    .font(.ui(size: 15, weight: .semibold))
                if isNew {
                    Chip("New", tint: .primary)
                }
                Spacer()
                if let date = note.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.ui(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(note.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text).font(.ui(size: 13, weight: .semibold))
                case .paragraph(let text):
                    Text(text).font(.ui(size: 13)).fixedSize(horizontal: false, vertical: true)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(item).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.ui(size: 13))
                        }
                    }
                case .image(let url, let alt):
                    ReleaseNoteImage(url: url, alt: alt)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// What's in the update that's waiting, shown from the sidebar button
/// before you restart.
struct UpdateNotesPopover: View {
    @Environment(Updater.self) private var updater
    let close: () -> Void
    @State private var notes: [ReleaseNote]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Workbench \(updater.readyVersion ?? "") is ready")
                    .font(.ui(size: 15, weight: .semibold))
                Text("It installs when you restart or quit Workbench.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let notes, !notes.isEmpty {
                        ForEach(notes) { note in
                            ReleaseNoteView(note: note)
                        }
                    } else if notes == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("No release notes for this version.").foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 340)
            Divider()
            HStack {
                Button("Later", action: close)
                Spacer()
                Button("Restart to Update") {
                    close()
                    updater.restartToUpdate()
                }
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 400)
        .task { notes = await upcoming() }
    }

    /// Every version between this one and the update, newest first, so
    /// skipping a version doesn't hide what it changed.
    private func upcoming() async -> [ReleaseNote] {
        let current = ReleaseFeed.currentBuild
        if let feed = await ReleaseFeed.load() {
            let newer = feed.filter { $0.build > current && $0.build <= (updater.readyBuild ?? .max) }
            if !newer.isEmpty { return newer }
        }
        // The feed didn't load: fall back to what Sparkle downloaded.
        guard let html = updater.readyNotes, let version = updater.readyVersion else { return [] }
        return [ReleaseNote(version: version, build: updater.readyBuild ?? 0, date: nil, blocks: ReleaseNoteBlock.parse(html: html))]
    }
}

/// A screenshot in the release notes, loaded from the release page.
/// Leaves no gap if it can't load, say when offline.
private struct ReleaseNoteImage: View {
    let url: URL
    let alt: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                    .padding(.vertical, 2)
            case .empty:
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .aspectRatio(16 / 10, contentMode: .fit)
            default:
                EmptyView()
            }
        }
        .accessibilityLabel(alt)
    }
}
