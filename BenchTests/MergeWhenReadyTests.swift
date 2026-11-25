import Foundation
import Testing
@testable import Bench

/// Merge When Ready: Workbench waits on a pull request's checks and sends
/// the merge to Claude only once they pass.
@MainActor
struct MergeWhenReadyTests {
    private let project = UUID()

    private func pr(_ checks: PullRequestInfo.Checks, number: Int = 7, state: PullRequestInfo.State = .open) -> PullRequestInfo {
        PullRequestInfo(number: number, title: "Thing", url: URL(string: "https://github.com/o/r/pull/\(number)")!,
                        state: state, checks: checks, passedCount: 1, totalCount: 3)
    }

    private func waiting() -> (PullRequests, () -> [String]) {
        let pullRequests = PullRequests()
        var sent: [String] = []
        pullRequests.onReadyToMerge = { _, prompt in sent.append(prompt) }
        pullRequests.setInfoForTesting(pr(.pending), for: project)
        pullRequests.mergeWhenReady(project, prompt: "merge it")
        return (pullRequests, { sent })
    }

    @Test func onlyWaitsWhileChecksRun() {
        let pullRequests = PullRequests()
        pullRequests.setInfoForTesting(pr(.passing), for: project)
        pullRequests.mergeWhenReady(project, prompt: "merge it")
        #expect(pullRequests.mergeWhenReady[project] == nil)
    }

    @Test func mergesWhenChecksPass() {
        let (pullRequests, sent) = waiting()
        #expect(!pullRequests.settleMerge(project, pr(.pending)))
        #expect(!pullRequests.settleMerge(project, nil))
        #expect(sent().isEmpty)
        #expect(pullRequests.settleMerge(project, pr(.passing)))
        #expect(sent() == ["merge it"])
        #expect(pullRequests.mergeWhenReady[project] == nil)
    }

    @Test func givesUpWhenChecksFail() {
        let (pullRequests, sent) = waiting()
        #expect(!pullRequests.settleMerge(project, pr(.failing)))
        #expect(sent().isEmpty)
        #expect(pullRequests.mergeWhenReady[project] == nil)
    }

    @Test func givesUpWhenThePullRequestChanges() {
        let (pullRequests, sent) = waiting()
        pullRequests.settleMerge(project, pr(.passing, number: 8))
        #expect(sent().isEmpty)
        #expect(pullRequests.mergeWhenReady[project] == nil)

        let (closed, sentClosed) = waiting()
        closed.settleMerge(project, pr(.passing, state: .merged))
        #expect(sentClosed().isEmpty)
        #expect(closed.mergeWhenReady[project] == nil)
    }

    @Test func cancels() {
        let (pullRequests, sent) = waiting()
        pullRequests.cancelMerge(project)
        pullRequests.settleMerge(project, pr(.passing))
        #expect(sent().isEmpty)
    }
}
