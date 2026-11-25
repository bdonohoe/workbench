import Foundation
import Testing
@testable import BenchKit

let pitwall = SplitProject(id: UUID(), name: "pitwall", summary: "F1 race tracker.")
let bench = SplitProject(id: UUID(), name: "Bench", summary: "Mac terminal.")

@Test func parsesTasksInOrder() throws {
    let reply = #"{"tasks":[{"project":"pitwall","unsure":null,"prompt":"Add a lap delta chart.","source":"In pitwall I want"},{"project":"Bench","unsure":null,"prompt":"Fix the sidebar flicker.","source":"Also in Bench"}]}"#
    let tasks = try TaskSplit.parse(reply, projects: [pitwall, bench])
    #expect(tasks.map(\.projectID) == [pitwall.id, bench.id])
    #expect(tasks.map(\.prompt) == ["Add a lap delta chart.", "Fix the sidebar flicker."])
    #expect(tasks[0].source == "In pitwall I want")
    #expect(tasks[0].branch == BranchNames.suggest(from: "Add a lap delta chart."))
    #expect(tasks[1].branch.hasPrefix("fix/"))
}

@Test func parsesJSONInsideProseAndFences() throws {
    let reply = "Here you go:\n```json\n{\"tasks\":[{\"project\":\"Bench\",\"prompt\":\"Add export.\",\"source\":\"x\"}]}\n```\nDone."
    #expect(try TaskSplit.parse(reply, projects: [bench]).count == 1)
}

@Test func matchesProjectNamesIgnoringCase() throws {
    let reply = #"{"tasks":[{"project":"bench","prompt":"Add export.","source":"x"}]}"#
    #expect(try TaskSplit.parse(reply, projects: [bench])[0].projectID == bench.id)
}

@Test func keepsUnsureReasonWithNoProject() throws {
    let reply = #"{"tasks":[{"project":null,"unsure":"Could be read-later or quick-reads-ios.","prompt":"Add a font slider.","source":"the reading app"}]}"#
    let task = try TaskSplit.parse(reply, projects: [bench])[0]
    #expect(task.projectID == nil)
    #expect(task.unsure == "Could be read-later or quick-reads-ios.")
}

@Test func unknownProjectBecomesUnsure() throws {
    let reply = #"{"tasks":[{"project":"Nonesuch","prompt":"Do it.","source":"x"}]}"#
    let task = try TaskSplit.parse(reply, projects: [bench])[0]
    #expect(task.projectID == nil)
    #expect(task.unsure == "Claude suggested “Nonesuch”, which isn't one of your projects.")
}

@Test func duplicateProjectNamesBecomeUnsure() throws {
    let a = SplitProject(id: UUID(), name: "app", summary: ""), b = SplitProject(id: UUID(), name: "app", summary: "")
    let reply = #"{"tasks":[{"project":"app","prompt":"Do it.","source":"x"}]}"#
    let task = try TaskSplit.parse(reply, projects: [a, b])[0]
    #expect(task.projectID == nil)
    #expect(task.unsure == "More than one of your projects is called “app”.")
}

@Test func emptyTaskListIsNotAnError() throws {
    #expect(try TaskSplit.parse(#"{"tasks":[]}"#, projects: [bench]).isEmpty)
}

@Test func unreadableReplyThrows() {
    #expect(throws: TaskSplit.ParseError.self) { try TaskSplit.parse("Sorry, I can't help.", projects: [bench]) }
    #expect(throws: TaskSplit.ParseError.self) { try TaskSplit.parse(#"{"items":[]}"#, projects: [bench]) }
}

@Test func inputListsMessageThenProjects() {
    let text = TaskSplit.input(message: "Fix it.", projects: [pitwall, SplitProject(id: UUID(), name: "nono", summary: "")])
    #expect(text == "Message:\nFix it.\n\nProjects:\n- pitwall: F1 race tracker.\n- nono: No description.")
}

@Test func secondTaskWithSameBranchGetsSuffix() {
    let tasks = [DraftTask(projectID: bench.id, branch: "fix/sidebar"), DraftTask(projectID: bench.id, branch: "fix/sidebar"),
                 DraftTask(projectID: pitwall.id, branch: "fix/sidebar")]
    let result = TaskSplit.uniquingBranches(tasks, existing: [:])
    #expect(result.map(\.branch) == ["fix/sidebar", "fix/sidebar-2", "fix/sidebar"])
}

@Test func suffixSkipsExistingBranches() {
    let tasks = [DraftTask(projectID: bench.id, branch: "feat/export")]
    let result = TaskSplit.uniquingBranches(tasks, existing: [bench.id: ["feat/export", "feat/export-2"]])
    #expect(result[0].branch == "feat/export-3")
}

@Test func readyTasksHaveNoProblems() {
    let task = DraftTask(projectID: bench.id, prompt: "Add export.", branch: "feat/export")
    #expect(TaskSplit.problems([task], existing: [bench.id: ["main"]], names: [bench.id: "Bench"]).isEmpty)
}

@Test func problemsNameWhatToFix() {
    let noProject = DraftTask(prompt: "x", branch: "feat/a")
    let noBranch = DraftTask(projectID: bench.id, prompt: "x", branch: "  ")
    let noPrompt = DraftTask(projectID: bench.id, prompt: " \n", branch: "feat/b")
    let taken = DraftTask(projectID: bench.id, prompt: "x", branch: "main")
    let twinA = DraftTask(projectID: pitwall.id, prompt: "x", branch: "feat/c")
    let twinB = DraftTask(projectID: pitwall.id, prompt: "y", branch: "feat/c")
    let p = TaskSplit.problems([noProject, noBranch, noPrompt, taken, twinA, twinB],
                               existing: [bench.id: ["main"], pitwall.id: []],
                               names: [bench.id: "Bench", pitwall.id: "pitwall"])
    #expect(p[noProject.id] == "Pick a project.")
    #expect(p[noBranch.id] == "Add a branch name.")
    #expect(p[noPrompt.id] == "Write a prompt.")
    #expect(p[taken.id] == "main already exists in Bench. Pick another branch name.")
    #expect(p[twinA.id] == nil)
    #expect(p[twinB.id] == "Another task in pitwall already uses feat/c.")
}

@Test func briefSkipsHeadingsBadgesAndCode() {
    let readme = "# Workbench\n\n[![CI](x.svg)](y)\n\n```sh\nmake\n```\n\nA lean Mac terminal for working\nacross many projects.\n\nMore text."
    #expect(TaskSplit.brief(fromMarkdown: readme) == "A lean Mac terminal for working across many projects.")
}

@Test func briefStopsAtLimitOnAWord() {
    #expect(TaskSplit.brief(fromMarkdown: "one two three four", limit: 9) == "one two…")
}

@Test func nullPromptItemIsDropped() throws {
    let reply = #"{"tasks":[{"project":"Bench","prompt":null,"source":"x"},{"project":"Bench","prompt":"Add export.","source":"y"}]}"#
    let tasks = try TaskSplit.parse(reply, projects: [bench])
    #expect(tasks.count == 1)
    #expect(tasks.first?.prompt == "Add export.")
}

@Test func emptyProjectNameIsTreatedAsNull() throws {
    let reply = #"{"tasks":[{"project":"  ","unsure":null,"prompt":"Add export.","source":"x"}]}"#
    let task = try TaskSplit.parse(reply, projects: [bench])[0]
    #expect(task.projectID == nil)
    #expect(task.unsure?.hasPrefix("Claude suggested") != true)
}

@Test func taskSplitRoundTripsThroughTheCompanionCoder() throws {
    let task = DraftTask(projectID: bench.id, unsure: nil, prompt: "Fix the sidebar flicker.", source: "Also in Bench", branch: "fix/sidebar-flicker")
    let result = TaskSplitResult(message: "Also in Bench fix the flicker", tasks: [task], projects: [pitwall, bench],
                                 existingBranches: [bench.id: ["main", "fix/sidebar-flicker"]], problem: nil)
    let data = try CompanionCoding.encoder.encode(ServerMessage.taskSplit(result))
    guard case .taskSplit(let decoded) = try CompanionCoding.decoder.decode(ServerMessage.self, from: data) else {
        Issue.record("Wrong message back"); return
    }
    #expect(decoded == result)

    let start = try CompanionCoding.encoder.encode(ClientMessage.startTasks([task]))
    guard case .startTasks(let tasks) = try CompanionCoding.decoder.decode(ClientMessage.self, from: start) else {
        Issue.record("Wrong message back"); return
    }
    #expect(tasks == [task])

    let failures = try CompanionCoding.encoder.encode(ServerMessage.tasksStarted(failures: [task.id: "Branch exists."]))
    guard case .tasksStarted(let decodedFailures) = try CompanionCoding.decoder.decode(ServerMessage.self, from: failures) else {
        Issue.record("Wrong message back"); return
    }
    #expect(decodedFailures == [task.id: "Branch exists."])
}
