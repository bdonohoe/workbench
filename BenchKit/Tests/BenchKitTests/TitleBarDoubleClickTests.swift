import Testing
@testable import BenchKit

@Test func followsTheMacsTitleBarSetting() {
    #expect(TitleBarDoubleClick.resolve(action: "Maximize", minimizes: false) == .zoom)
    #expect(TitleBarDoubleClick.resolve(action: "Fill", minimizes: false) == .zoom)
    #expect(TitleBarDoubleClick.resolve(action: "Minimize", minimizes: false) == .minimize)
    #expect(TitleBarDoubleClick.resolve(action: "None", minimizes: true) == .nothing)
}

@Test func fallsBackToTheOlderTitleBarSetting() {
    #expect(TitleBarDoubleClick.resolve(action: nil, minimizes: false) == .zoom)
    #expect(TitleBarDoubleClick.resolve(action: nil, minimizes: true) == .minimize)
}
