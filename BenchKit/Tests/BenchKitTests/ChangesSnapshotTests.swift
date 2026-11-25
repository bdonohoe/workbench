import Foundation
import Testing
@testable import BenchKit

/// A Mac on an older Bench sends changes without the header details.
@Test func decodesChangesFromAnOlderMac() throws {
    let json = #"{"branch":"main","baseRef":"origin/main","staged":[],"unstaged":[],"againstBase":[],"commits":[],"isRepository":true}"#
    let snapshot = try JSONDecoder().decode(ChangesSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.branch == "main")
    #expect(snapshot.aheadOfBase == nil)
    #expect(snapshot.branches == nil)
    #expect(snapshot.remoteName == nil)
}

@Test func headerDetailsSurviveTheTrip() throws {
    let fetched = Date(timeIntervalSince1970: 1_800_000_000)
    let sent = ChangesSnapshot(branch: "feat/x", baseRef: "origin/main", aheadOfBase: 5, behindBase: 0,
                               upstream: "origin/feat/x", unpushed: 2, unpulled: 0, lastFetch: fetched,
                               branches: ["main", "origin/main"], chosenBase: "origin/main")
    let back = try JSONDecoder().decode(ChangesSnapshot.self, from: JSONEncoder().encode(sent))
    #expect(back == sent)
    #expect(back.remoteName == "origin")
}

@Test func branchControlMessagesRoundTrip() throws {
    let id = UUID()
    let set = try CompanionCoding.encoder.encode(ClientMessage.setBaseRef(projectID: id, ref: nil))
    guard case .setBaseRef(let projectID, let ref) = try CompanionCoding.decoder.decode(ClientMessage.self, from: set) else {
        Issue.record("Wrong message"); return
    }
    #expect(projectID == id)
    #expect(ref == nil)
    let refresh = try CompanionCoding.encoder.encode(ClientMessage.refreshChanges(projectID: id))
    guard case .refreshChanges = try CompanionCoding.decoder.decode(ClientMessage.self, from: refresh) else {
        Issue.record("Wrong message"); return
    }
}
