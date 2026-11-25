import os

/// Loggers for dictation, in the unified log under Workbench's subsystem.
/// Transcripts are always `.private`; only timings and counts are public.
nonisolated enum DictationLog {
    static let engine = Logger(subsystem: "me.birchtree.Bench", category: "DictationEngine")
    static let pipeline = Logger(subsystem: "me.birchtree.Bench", category: "Dictation")
    static let cleanup = Logger(subsystem: "me.birchtree.Bench", category: "DictationCleanup")
}
