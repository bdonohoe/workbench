import Foundation
import Testing
@testable import Bench

/// The Claude actions list: what ships by default, how prompts fill in,
/// and how a saved file is read back.
@MainActor
struct ClaudeActionsTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-actions-\(UUID().uuidString)")
            .appendingPathComponent("claude-actions.json")
    }

    /// Its own suite, so the merge flag never touches the real app's.
    private func scratchDefaults() -> UserDefaults {
        let name = "bench-actions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func shipsCommitPushPullRequestAndMerge() {
        let actions = ClaudeActions(file: temporaryFile(), defaults: scratchDefaults())
        #expect(actions.all.map(\.role) == [.commit, .push, .pullRequest, .merge])
        #expect(actions.isDefault)
    }

    @Test func fillsPullRequestNumber() {
        #expect(ClaudeAction.merge.filledPrompt(branch: "x", base: "main", pullRequest: 42).hasPrefix("Merge pull request #42 into main."))
        let action = ClaudeAction(name: "M", prompt: "Merge {pr}.")
        #expect(action.filledPrompt(branch: nil, base: nil) == "Merge the pull request for this branch.")
    }

    @Test func addsMergeOnceToAListSavedBeforeIt() throws {
        let file = temporaryFile()
        let defaults = scratchDefaults()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [{"name": "Commit", "prompt": "c", "role": "commit"}, {"name": "Open PR", "prompt": "p", "role": "pullRequest"},
         {"name": "Tidy", "prompt": "t"}]
        """.write(to: file, atomically: true, encoding: .utf8)

        let actions = ClaudeActions(file: file, defaults: defaults)
        #expect(actions.all.map(\.name) == ["Commit", "Open PR", "Merge", "Tidy"])

        // Deleting it sticks.
        actions.delete(actions.all[2].id)
        #expect(ClaudeActions(file: file, defaults: defaults).all.map(\.name) == ["Commit", "Open PR", "Tidy"])
    }

    @Test func aNewListDoesNotGetMergeBackAfterDeletingIt() {
        let file = temporaryFile()
        let defaults = scratchDefaults()
        let actions = ClaudeActions(file: file, defaults: defaults)
        actions.delete(actions.all.first { $0.role == .merge }!.id)
        #expect(!ClaudeActions(file: file, defaults: defaults).all.contains { $0.role == .merge })
    }

    @Test func fillsBranchAndBase() {
        let action = ClaudeAction(name: "PR", prompt: "Open a PR for {branch} against {base}.")
        #expect(action.filledPrompt(branch: "feat/x", base: "main") == "Open a PR for feat/x against main.")
        #expect(action.filledPrompt(branch: nil, base: nil) == "Open a PR for the current branch against the default branch.")
    }

    @Test func savesAndReadsBack() throws {
        let file = temporaryFile()
        let defaults = scratchDefaults()
        let actions = ClaudeActions(file: file, defaults: defaults)
        actions.save(ClaudeAction(name: "Rebase", prompt: "Rebase {branch} on {base}.", symbol: "arrow.clockwise"))
        actions.delete(actions.all[0].id)
        actions.move(from: IndexSet(integer: 3), to: 0)
        #expect(!actions.isDefault)

        let again = ClaudeActions(file: file, defaults: defaults)
        #expect(again.all.map(\.name) == ["Rebase", "Push", "Open PR", "Merge"])
        #expect(again.all[0].role == .custom)
        #expect(again.all[1].role == .push)

        again.restoreDefaults()
        #expect(ClaudeActions(file: file, defaults: defaults).isDefault)
    }

    @Test func readsEntriesMissingNewerFields() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // One old-style entry, one that can't be read, which is dropped
        // rather than losing the whole list.
        try """
        [{"name": "Tidy", "prompt": "Tidy up."}, {"prompt": "No name"}]
        """.write(to: file, atomically: true, encoding: .utf8)
        let defaults = scratchDefaults()
        defaults.set(true, forKey: ClaudeActions.offeredMergeKey)
        let actions = ClaudeActions(file: file, defaults: defaults)
        #expect(actions.all.count == 1)
        #expect(actions.all[0].name == "Tidy")
        #expect(actions.all[0].symbol == "sparkles")
        #expect(actions.all[0].role == .custom)
    }
}
