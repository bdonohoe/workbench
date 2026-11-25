import Foundation
import Testing
@testable import Bench

/// Analytics only ever learns a model's family and version number.
struct ModelAnalyticsTests {
    @Test func sendsTheFamilyAndVersion() {
        #expect(ModelAnalytics.properties(model: "Opus 5.5") as? [String: String] == ["family": "opus", "version": "5.5"])
        #expect(ModelAnalytics.properties(model: "Fable 5.1") as? [String: String] == ["family": "fable", "version": "5.1"])
        #expect(ModelAnalytics.properties(model: "Haiku") as? [String: String] == ["family": "haiku"])
    }

    @Test func sendsNothingElseFromAnUnknownName() {
        let custom = ModelAnalytics.properties(model: "arn:aws:bedrock:us-east-1:123456789012:custom-model 7")
        #expect(custom as? [String: String] == ["family": "other"])
    }

    @Test func aSwitchSaysFromAndTo() {
        let props = ModelAnalytics.switchProperties(from: "Opus 5.5", to: "fable", fromPhone: true)
        #expect(props["from"] as? String == "opus")
        #expect(props["to"] as? String == "fable")
        #expect(props["from_phone"] as? Bool == true)
        #expect(ModelAnalytics.switchProperties(from: nil, to: "haiku", fromPhone: false)["from"] as? String == "unknown")
    }
}
