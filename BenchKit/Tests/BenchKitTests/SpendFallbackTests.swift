import Testing
@testable import BenchKit

@Test func aTokenWithNoSubscriptionShowsSpending() {
    #expect(PlanUsage.showsSpendInstead(loggedIn: true, subscriptionType: nil, hasRecentLimits: false))
    #expect(PlanUsage.showsSpendInstead(loggedIn: true, subscriptionType: "", hasRecentLimits: false))
}

@Test func usageBilledPlansWithNoLimitsShowSpending() {
    #expect(PlanUsage.showsSpendInstead(loggedIn: true, subscriptionType: "enterprise", hasRecentLimits: false))
    #expect(PlanUsage.showsSpendInstead(loggedIn: true, subscriptionType: "team", hasRecentLimits: false))
}

@Test func planLimitsWinOverSpending() {
    for plan in [nil, "team", "enterprise", "pro", "max"] {
        #expect(!PlanUsage.showsSpendInstead(loggedIn: true, subscriptionType: plan, hasRecentLimits: true))
    }
}

@Test func proAndMaxWaitForTheirLimits() {
    #expect(!PlanUsage.showsSpendInstead(loggedIn: true, subscriptionType: "pro", hasRecentLimits: false))
    #expect(!PlanUsage.showsSpendInstead(loggedIn: true, subscriptionType: "Max", hasRecentLimits: false))
}

@Test func signedOutShowsNothing() {
    #expect(!PlanUsage.showsSpendInstead(loggedIn: false, subscriptionType: nil, hasRecentLimits: false))
}
