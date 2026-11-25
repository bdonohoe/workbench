import Foundation
import Testing
@testable import BenchKit

@Test func aTimingLineHasTheStepAndAShortTabID() {
    let tab = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
    let line = ChatTiming.line(date: .now, elapsed: 3.214, step: "transcript read", tab: tab, details: "messages=600")
    #expect(line.hasSuffix("+3.21s tab=ABCDEF12 transcript read messages=600"))
    #expect(!line.contains("0000-0000"))
}

@Test func aTimingLineWithoutATabLeavesItOut() {
    #expect(ChatTiming.line(date: .now, elapsed: 0, step: "app launched", tab: nil, details: "").hasSuffix("+0.00s app launched"))
}

@Test func aTimingLineSaysWhenInLocalTime() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)
    #expect(ChatTiming.line(date: date, elapsed: 0, step: "x", tab: nil, details: "").hasPrefix(date.formatted(style)))
    #expect(date.formatted(style).contains("T"))
}

@Test func trimKeepsTheNewestWholeLines() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let lines = (0..<40_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
    let padded = String(repeating: "x", count: Int(ChatTiming.maxBytes)) + "\n" + lines
    try Data(padded.utf8).write(to: url)
    ChatTiming.trim(url)
    let kept = try String(contentsOf: url, encoding: .utf8)
    #expect(kept.utf8.count <= ChatTiming.keptBytes)
    #expect(kept.hasSuffix("line 39999\n"))
    #expect(kept.split(separator: "\n").allSatisfy { $0.hasPrefix("line ") })
}

@Test func trimLeavesASmallFileAlone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("short\n".utf8).write(to: url)
    ChatTiming.trim(url)
    #expect(try String(contentsOf: url, encoding: .utf8) == "short\n")
}
