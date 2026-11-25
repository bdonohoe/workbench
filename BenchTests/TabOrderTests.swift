import AppKit
import Testing
@testable import Bench

/// Dragging a tab along the tab bar, and Ctrl-Tab to step through tabs.
struct TabOrderTests {
    private func project(_ kinds: [TabKind]) -> Project {
        var project = Project(path: "/tmp/example")
        project.tabs = kinds.map { TabRecord(kind: $0) }
        return project
    }

    @Test func aTabDraggedRightPassesTheOneItsOver() {
        var p = project([.agent, .shell, .shell])
        let (a, b, c) = (p.tabs[0].id, p.tabs[1].id, p.tabs[2].id)
        p.moveStop(a, over: c)
        #expect(p.tabs.map(\.id) == [b, c, a])
    }

    @Test func aTabDraggedLeftPassesTheOneItsOver() {
        var p = project([.agent, .shell, .shell])
        let (a, b, c) = (p.tabs[0].id, p.tabs[1].id, p.tabs[2].id)
        p.moveStop(c, over: a)
        #expect(p.tabs.map(\.id) == [c, a, b])
    }

    @Test func aSplitPairMovesAsOneTab() {
        var p = project([.agent, .shell, .shell, .agent])
        let (a, b, c, d) = (p.tabs[0].id, p.tabs[1].id, p.tabs[2].id, p.tabs[3].id)
        // a and c are a pair, shown as one tab where a is.
        p.splits = [TabSplit(first: a, second: c, axis: .sideBySide)]
        p.moveStop(a, over: d)
        #expect(p.tabStops.map(\.id) == [b, d, a])
        #expect(p.tabs.map(\.id) == [b, d, a, c])
        #expect(p.split(of: a)?.second == c)
    }

    @Test func movingOntoItselfOrAnUnknownTabDoesNothing() {
        var p = project([.agent, .shell])
        let before = p.tabs.map(\.id)
        p.moveStop(before[0], over: before[0])
        p.moveStop(UUID(), over: before[1])
        p.moveStop(before[0], over: UUID())
        #expect(p.tabs.map(\.id) == before)
    }

    @Test func controlTabStepsForwardAndShiftStepsBack() {
        #expect(ControlTab.offset(keyCode: 48, modifiers: .control) == 1)
        #expect(ControlTab.offset(keyCode: 48, modifiers: [.control, .shift]) == -1)
        // Caps Lock doesn't count.
        #expect(ControlTab.offset(keyCode: 48, modifiers: [.control, .capsLock]) == 1)
    }

    @Test func otherKeysAreLeftAlone() {
        #expect(ControlTab.offset(keyCode: 48, modifiers: []) == nil)
        #expect(ControlTab.offset(keyCode: 48, modifiers: .shift) == nil)
        #expect(ControlTab.offset(keyCode: 48, modifiers: [.control, .option]) == nil)
        #expect(ControlTab.offset(keyCode: 48, modifiers: [.control, .command]) == nil)
        #expect(ControlTab.offset(keyCode: 36, modifiers: .control) == nil)
    }
}
