import Foundation
import Testing
@testable import BenchKit

@Test func benchCommandNamesAreUniqueAndAliasesPointSomewhere() {
    let names = BenchCommand.all.map(\.name)
    #expect(Set(names).count == names.count)
    for (alias, name) in BenchCommand.aliases {
        #expect(!names.contains(alias), "\(alias) is a command and an alias")
        #expect(names.contains(name), "\(alias) points at a command that doesn't exist")
    }
    #expect(BenchCommand.named("tell")?.name == "send")
    #expect(BenchCommand.named("nope") == nil)
}

@Test func benchHelpListsEveryCommandButTheHiddenOnes() {
    let help = BenchCommand.help()
    for command in BenchCommand.all {
        #expect(help.contains("  \(command.name) ") == !command.isHidden, "\(command.name)")
    }
    for limit in BenchCommand.limits { #expect(help.contains(limit)) }
}

@Test func benchHelpForOneCommandHasItsUsageAndExamples() throws {
    let send = try #require(BenchCommand.named("send")).help
    #expect(send.hasPrefix("bench send <agent>"))
    #expect(send.contains("bench send --all \"Go.\""))
}

@Test func benchNoteNamesTheHeadlineCommandsAndPointsAtHelp() {
    let note = BenchCommand.note
    #expect(note.contains("Run `bench help`"))
    for command in BenchCommand.all {
        #expect(note.contains("`\(command.usage)`") == command.isHeadline, "\(command.name)")
    }
    // It's passed on a command line and paid for in every session.
    #expect(note.count < 2500)
}

/// No dashes in the middle of a sentence, in anything a person reads.
@Test func benchTextHasNoEmDashes() {
    let text = BenchCommand.help() + BenchCommand.note + BenchCommand.changedNotice
        + BenchCommand.all.map(\.help).joined()
    #expect(!text.contains("\u{2014}"))
}

@Test func benchUnknownCommandSuggestsCloseOnes() {
    #expect(BenchCommand.unknown("statu").contains("`bench status`"))
    #expect(BenchCommand.unknown("sen").contains("`bench send`"))
    let far = BenchCommand.unknown("zzzzzz")
    #expect(!far.contains("Did you mean"))
    #expect(far.contains("`bench help`"))
    #expect(!far.contains("discard-feedback"))
}

@Test func benchVersionIsStable() {
    #expect(BenchCommand.version == BenchCommand.version)
    #expect(!BenchCommand.version.isEmpty)
}

/// The README lists the commands by hand, so it can fall behind.
@Test func readmeMentionsEveryCommand() throws {
    let readme = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("README.md")
    let text = try String(contentsOf: readme, encoding: .utf8)
    for command in BenchCommand.all where !command.isHidden {
        #expect(text.contains("bench \(command.name)"), "README.md doesn't mention `bench \(command.name)`")
    }
}

// MARK: Requests

@Test func benchRequestParsesArgumentsWithLineBreaks() {
    let id = UUID()
    let request = BenchRequest.parse("tab=\(id.uuidString)\ncwd=/tmp/app\nargs=3\nstdin=0\n\nsend\0turn-review\0Go ahead.\n\nThen open a PR.\0")
    #expect(request.tabID == id)
    #expect(request.folder == "/tmp/app")
    #expect(request.arguments == ["send", "turn-review", "Go ahead.\n\nThen open a PR."])
    #expect(request.input == nil)
    #expect(request.commandName == "send")
}

@Test func benchRequestKeepsStandardInputApart() {
    let request = BenchRequest.parse("tab=\ncwd=\nargs=1\nstdin=1\n\nagent\0Fix it\nx=1\n")
    #expect(request.tabID == nil)
    #expect(request.folder == nil)
    #expect(request.arguments == ["agent"])
    #expect(request.input == "Fix it\nx=1\n")
}

@Test func benchRequestWithNothingIsEmpty() {
    #expect(BenchRequest.parse("") == BenchRequest(arguments: []))
    #expect(BenchRequest.parse("tab=\nargs=0\nstdin=0\n\n").commandName == nil)
}

// MARK: Arguments

private let agent = BenchCommand.named("agent")!

@Test func benchArgumentsSortOptionsFromWords() throws {
    let parsed = try BenchArguments(["--branch", "fix/a", "--base=main", "Fix", "the crash"], for: agent)
    #expect(parsed.values == ["branch": "fix/a", "base": "main"])
    #expect(parsed.text() == "Fix the crash")
}

@Test func benchArgumentsTakeEverythingAfterTwoDashes() throws {
    let parsed = try BenchArguments(["--", "--not-an-option", "x"], for: agent)
    #expect(parsed.positional == ["--not-an-option", "x"])
}

@Test func benchArgumentsCanStopAtTheFirstWord() throws {
    let run = try #require(BenchCommand.named("run"))
    let parsed = try BenchArguments(["--show", "npm", "run", "dev", "--port", "3000"], for: run, stopsAtFirstWord: true)
    #expect(parsed.has("show"))
    #expect(parsed.text() == "npm run dev --port 3000")
}

@Test func benchArgumentsRefuseUnknownOptionsAndMissingValues() {
    #expect(throws: BenchArguments.Problem.self) { try BenchArguments(["--nope"], for: agent) }
    #expect(throws: BenchArguments.Problem.self) { try BenchArguments(["--branch"], for: agent) }
    do {
        _ = try BenchArguments(["--nope"], for: agent)
    } catch {
        #expect(error.message.contains("--branch"))
    }
}

// MARK: Targets

private let recipes = BenchTarget(id: UUID(), name: "Recipes", path: "/Users/me/Apps/Recipes", tabIDs: [UUID()])
private let fix = BenchTarget(id: UUID(), name: "fix-crash", branch: "fix/crash", path: "/Users/me/Apps/Recipes.worktrees/fix-crash",
                              parentID: recipes.id, tabIDs: [UUID()])
private let review = BenchTarget(id: UUID(), name: "turn-review", branch: "turn-review", path: "/Users/me/Apps/Recipes.worktrees/turn-review",
                                 parentID: recipes.id)
private let notes = BenchTarget(id: UUID(), name: "Field Notes", path: "/Users/me/Apps/Notes")
private let notesReview = BenchTarget(id: UUID(), name: "turn-review", branch: "turn-review", path: "/Users/me/Apps/Notes.worktrees/turn-review",
                                      parentID: notes.id)
private let everything = [recipes, fix, review, notes, notesReview]

@Test func benchHomeIsTheTabsProjectThenTheFolders() {
    #expect(BenchTarget.home(tabID: fix.tabIDs[0], folder: "/Users/me/Apps/Notes", among: everything) == fix)
    #expect(BenchTarget.home(tabID: UUID(), folder: "/Users/me/Apps/Notes/Sources", among: everything) == notes)
    #expect(BenchTarget.home(tabID: nil, folder: "/Users/me/Apps/RecipesTwo", among: everything) == nil)
    #expect(BenchTarget.home(tabID: nil, folder: nil, among: everything) == nil)
    #expect(BenchTarget.root(of: fix, among: everything) == recipes)
    #expect(BenchTarget.root(of: notes, among: everything) == notes)
}

@Test func benchFindsAgentsInTheHomeProjectFirst() {
    #expect(BenchTarget.find("turn-review", home: fix, among: everything) == .one(review))
    #expect(BenchTarget.find("turn-review", home: notes, among: everything) == .one(notesReview))
    #expect(BenchTarget.find("turn-review", home: nil, among: everything)
            == .ambiguous("turn-review", folders: [review.path, notesReview.path]))
}

@Test func benchFindsByBranchItsLastPartNameOrFolder() {
    #expect(BenchTarget.find("fix/crash", home: recipes, among: everything) == .one(fix))
    #expect(BenchTarget.find("crash", home: recipes, among: everything) == .one(fix))
    #expect(BenchTarget.find("FIX-CRASH", home: recipes, among: everything) == .one(fix))
    #expect(BenchTarget.find("recipes", home: fix, among: everything) == .one(recipes))
    #expect(BenchTarget.find("field notes", home: fix, among: everything) == .one(notes))
    #expect(BenchTarget.find("/Users/me/Apps/Notes/", home: fix, among: everything) == .one(notes))
}

@Test func benchUnknownNamesComeBackWithTheOnesThatWork() {
    #expect(BenchTarget.find("turn-reviw", home: fix, among: everything)
            == .unknown("turn-reviw", choices: ["Recipes", "fix/crash", "turn-review"]))
    #expect(BenchTarget.find("nope", home: nil, among: everything) == .unknown("nope", choices: ["Recipes", "Field Notes"]))
}
