import Foundation

/// How long a stretch of Claude's work took, as the chat words it after
/// the run: "Simmered for 20m 23s · done 4:50 PM".
public enum TurnTime {
    /// Playful words for "worked", as Claude Code's terminal uses after a run.
    static let verbs = ["Baked", "Brewed", "Churned", "Cogitated", "Cooked", "Crunched", "Marinated", "Mulled", "Noodled",
                        "Percolated", "Pondered", "Puzzled", "Ruminated", "Sautéed", "Simmered", "Stewed", "Tinkered",
                        "Whisked", "Worked", "Wrangled"]

    /// The verb for one run. Picked from the run's id, so it looks random
    /// from run to run but a run keeps its verb each time it's drawn, on
    /// the Mac and the phone alike.
    public static func verb(for id: String) -> String {
        // FNV-1a: Swift's own hashes change from launch to launch.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return verbs[Int(hash % UInt64(verbs.count))]
    }

    /// "Simmered for 20m 23s".
    public static func summary(id: String, worked: TimeInterval) -> String {
        "\(verb(for: id)) for \(duration(worked))"
    }

    /// Runs shorter than this get no note: you were there for them.
    public static let shortest: TimeInterval = 30

    /// "45s", "20m 23s", "1h 4m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }

    /// When it finished: the time alone for today, with the day before it
    /// for anything earlier.
    public static func finished(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        return date.formatted(.dateTime.month(.abbreviated).day()) + ", " + time
    }
}
