import Foundation
import Testing
@testable import BenchKit

struct SpendLimitTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func budgetSetsTheShare() {
        let limit = PlanLimit.monthSpend(dollars: 250, budget: 1000, now: date(2026, 11, 15), calendar: calendar)
        #expect(limit.isSpend)
        #expect(limit.percent == 25)
        #expect(limit.resetsAt == date(2026, 12, 1, hour: 0))
        #expect(limit.summary(at: date(2026, 11, 15)) == "$250 of $1,000")
    }

    @Test func noBudgetMeansNoShare() {
        let limit = PlanLimit.monthSpend(dollars: 312.27, budget: nil, now: date(2026, 11, 2), calendar: calendar)
        #expect(limit.percent == 0)
        #expect(limit.shortName == "$312")
        #expect(limit.summary(at: date(2026, 11, 2)) == "$312 this month")
    }

    @Test func paceFollowsTheMonth() {
        let limit = PlanLimit.monthSpend(dollars: 10, budget: 100, now: date(2026, 11, 16, hour: 0), calendar: calendar)
        let elapsed = limit.elapsed(at: date(2026, 11, 16, hour: 0)) ?? 0
        #expect(abs(elapsed - 0.5) < 0.01)
    }

    @Test func newMonthStartsAtZero() {
        let limit = PlanLimit.monthSpend(dollars: 900, budget: 1000, now: date(2026, 11, 30), calendar: calendar)
        let december = date(2026, 12, 1, hour: 9)
        #expect(limit.percent(at: december) == 0)
        #expect(limit.summary(at: december) == "$0 of $1,000")
    }

    @Test func shortDollarsFitUnderARing() {
        #expect(PlanLimit.shortDollars(0) == "$0")
        #expect(PlanLimit.shortDollars(38.2) == "$38.20")
        #expect(PlanLimit.shortDollars(142.4) == "$142")
        #expect(PlanLimit.shortDollars(1000) == "$1,000")
        #expect(PlanLimit.shortDollars(12_400) == "$12.4k")
    }

    @Test func dollarTextReadsLikeMoney() {
        #expect(PlanLimit.dollarText(1240) == "$1,240")
        #expect(PlanLimit.dollarText(38.2) == "$38.20")
        #expect(PlanLimit.dollarText(500) == "$500")
    }

    @Test func plansStillReadAsPercent() {
        let week = PlanLimit(id: "seven_day", name: "This week", shortName: "Week", percent: 52,
                             resetsAt: date(2026, 11, 9), window: PlanLimit.week)
        #expect(!week.isSpend)
        #expect(week.summary(at: date(2026, 11, 3)) == "Week 52%")
    }

    /// Phones and Macs on older versions send limits without dollars.
    @Test func olderLimitsDecode() throws {
        let json = #"{"id":"seven_day","name":"This week","shortName":"Week","percent":12,"window":604800,"isPerModel":false}"#
        let limit = try JSONDecoder().decode(PlanLimit.self, from: Data(json.utf8))
        #expect(limit.dollars == nil && limit.budget == nil && !limit.isSpend)
    }
}
