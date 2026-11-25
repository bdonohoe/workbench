import Foundation
import Testing
@testable import BenchKit

struct AppIconChoiceTests {
    @Test func everyIconHasAPreview() {
        for choice in AppIconChoice.allCases {
            #expect(choice.previewURL != nil, "Run scripts/render-icon-previews.sh for \(choice.assetName)")
        }
    }

    @Test func alternateNamesRoundTrip() {
        #expect(AppIconChoice.default.alternateIconName == nil)
        #expect(AppIconChoice(alternateIconName: nil) == .default)
        #expect(AppIconChoice(alternateIconName: "not-an-icon") == .default)
        for choice in AppIconChoice.allCases {
            #expect(AppIconChoice(alternateIconName: choice.alternateIconName) == choice)
        }
    }

    /// Every alternate needs a .icon file and a spot in project.yml, or iOS
    /// refuses to switch to it.
    @Test func everyAlternateIsInTheProject() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../..").standardized
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        for choice in AppIconChoice.allCases where choice != .default {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("AppIcons/\(choice.assetName).icon").path))
            #expect(project.components(separatedBy: "ALTERNATE_APPICON_NAMES").count == 3)
            #expect(project.contains(" \(choice.assetName)"))
        }
    }
}
