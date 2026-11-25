import Foundation
import Testing
@testable import BenchKit

private let listJSON = Data(#"""
[
  {"number": 412, "title": "Sidebar flickers on wake", "url": "https://github.com/o/r/issues/412",
   "labels": [{"id": "L1", "name": "bug", "color": "d73a4a"}], "updatedAt": "2026-11-20T10:00:00Z"},
  {"number": 409, "title": "Add a dark mode toggle", "url": "https://github.com/o/r/issues/409",
   "labels": [{"name": "enhancement"}, {"name": "phone"}], "updatedAt": "2026-11-18T08:30:00Z"},
  {"title": "No number, so it's skipped", "url": "https://github.com/o/r/issues/1"}
]
"""#.utf8)

@Test func parsesTheIssueListInOrder() {
    let issues = GitHubIssue.parseList(listJSON)
    #expect(issues.map(\.number) == [412, 409])
    #expect(issues[1].labels == ["enhancement", "phone"])
    #expect(issues[0].updated != nil)
}

@Test func anythingElseIsNoIssues() {
    #expect(GitHubIssue.parseList(Data("no git remotes found".utf8)).isEmpty)
    #expect(GitHubIssue.parseOne(Data("{}".utf8)) == nil)
}

@Test func parsesOneIssue() {
    let one = Data(#"{"number": 7, "title": "Crash on launch", "url": "https://github.com/o/r/issues/7", "labels": []}"#.utf8)
    #expect(GitHubIssue.parseOne(one)?.number == 7)
}

@Test func aBugGetsAFixPromptAndBranch() {
    let issue = GitHubIssue.parseList(listJSON)[0]
    #expect(issue.prompt == """
    Fix issue #412: Sidebar flickers on wake
    https://github.com/o/r/issues/412

    Read the issue and its comments with `gh issue view 412 --comments` before you start.
    """)
    #expect(issue.branch == "fix/412-sidebar-flickers-wake")
}

@Test func anythingElseIsWorkedOn() {
    let issue = GitHubIssue.parseList(listJSON)[1]
    #expect(issue.prompt.hasPrefix("Work on issue #409: Add a dark mode toggle\n"))
    #expect(issue.branch == "feat/409-add-dark-mode-toggle")
}

@Test func aTitleThatReadsLikeABugIsOne() {
    let issue = GitHubIssue(number: 3, title: "Fix the export crash", url: URL(string: "https://github.com/o/r/issues/3")!)
    #expect(issue.isBug)
    #expect(issue.branch == "fix/3-export-crash")
}

@Test func aTitleWithNoWordsStillNamesABranch() {
    let issue = GitHubIssue(number: 12, title: "???", url: URL(string: "https://github.com/o/r/issues/12")!)
    #expect(issue.branch == "feat/12")
}

@Test func searchMatchesNumberTitleAndLabel() {
    let issue = GitHubIssue.parseList(listJSON)[0]
    #expect(issue.matches(""))
    #expect(issue.matches("41"))
    #expect(issue.matches("#412"))
    #expect(issue.matches("FLICKER"))
    #expect(issue.matches("bug"))
    #expect(!issue.matches("409"))
    #expect(!issue.matches("phone"))
}

@Test func readsAnIssueNumberHoweverItIsWritten() {
    #expect(GitHubIssue.number(from: "412") == 412)
    #expect(GitHubIssue.number(from: " #412 ") == 412)
    #expect(GitHubIssue.number(from: "https://github.com/o/r/issues/412") == 412)
    #expect(GitHubIssue.number(from: "https://github.com/o/r/pull/412") == nil)
    #expect(GitHubIssue.number(from: "fix/412") == nil)
    #expect(GitHubIssue.number(from: "0") == nil)
    #expect(GitHubIssue.number(from: "") == nil)
}
