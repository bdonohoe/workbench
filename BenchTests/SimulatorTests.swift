import Foundation
import Testing
@testable import Bench

/// The parts of simulator tracking that don't need a simulator running:
/// reading a device's details, how its age is judged, and the command
/// that shuts it down.
struct SimulatorTests {
    private func simulator(bootedAt: Date = Date(), deviceSet: URL? = nil) -> Simulator {
        Simulator(id: "ABCD-1234", pid: 42, name: "iPhone 18 Pro", runtime: "iOS 27.2",
                  kind: .phone, bootedAt: bootedAt, deviceSet: deviceSet)
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser

    @Test func runtimeNamesReadLikeTheSystem() {
        #expect(Simulator.runtimeName(from: "com.apple.CoreSimulator.SimRuntime.iOS-27-2") == "iOS 27.2")
        #expect(Simulator.runtimeName(from: "com.apple.CoreSimulator.SimRuntime.xrOS-27-0") == "visionOS 27.0")
        // Built for one device, which is named after the version.
        #expect(Simulator.runtimeName(from: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4") == "iOS 27.2")
        #expect(Simulator.runtimeName(from: "com.apple.CoreSimulator.SimRuntime.watchOS") == "watchOS")
        #expect(Simulator.runtimeName(from: "") == "")
    }

    @Test func kindsComeFromTheDeviceType() {
        #expect(Simulator.Kind(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro") == .phone)
        #expect(Simulator.Kind(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4") == .tablet)
        #expect(Simulator.Kind(deviceType: "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-3") == .watch)
        #expect(Simulator.Kind(deviceType: "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K") == .tv)
        #expect(Simulator.Kind(deviceType: "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro") == .vision)
        #expect(Simulator.Kind(deviceType: "") == .other)
    }

    @Test func ageTurnsAtAnHourTwoHoursAndADay() {
        #expect(Simulator.Age(runningFor: 0) == .fresh)
        #expect(Simulator.Age(runningFor: 3599) == .fresh)
        #expect(Simulator.Age(runningFor: 3600) == .lingering)
        #expect(Simulator.Age(runningFor: 7200) == .forgotten)
        #expect(Simulator.Age(runningFor: 86399) == .forgotten)
        #expect(Simulator.Age(runningFor: 86400) == .neglected)
        #expect(Simulator.Age.fresh < .neglected)

        let now = Date()
        #expect(simulator(bootedAt: now.addingTimeInterval(-3 * 3600)).age(at: now) == .forgotten)
    }

    @Test func runningTimesAreShort() {
        #expect(Simulator.duration(20) == "just now")
        #expect(Simulator.duration(4 * 60) == "4m")
        #expect(Simulator.duration(2 * 3600) == "2h")
        #expect(Simulator.duration(2 * 3600 + 5 * 60) == "2h 5m")
        #expect(Simulator.duration(3 * 86400) == "3d")
        #expect(Simulator.duration(3 * 86400 + 4 * 3600 + 120) == "3d 4h")
        // A clock that moved back shouldn't print a negative time.
        #expect(Simulator.duration(-500) == "just now")
    }

    @Test func previewsAndTestRunsAreTagged() {
        let regular = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        let previews = home.appendingPathComponent("Library/Developer/Xcode/UserData/Previews/Simulator Devices")
        let tests = home.appendingPathComponent("Library/Developer/XCTestDevices")
        #expect(simulator(deviceSet: regular).origin == nil)
        #expect(simulator(deviceSet: previews).origin == "Xcode Previews")
        #expect(simulator(deviceSet: tests).origin == "Test run")
        #expect(simulator(deviceSet: nil).origin == nil)
    }

    @Test func shuttingDownNamesTheFolderOnlyWhenItIsNotTheRegularOne() {
        let regular = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        let tests = home.appendingPathComponent("Library/Developer/XCTestDevices")
        #expect(SimulatorControl.shutDownArguments(for: simulator(deviceSet: regular))
                == ["simctl", "shutdown", "ABCD-1234"])
        #expect(SimulatorControl.shutDownArguments(for: simulator(deviceSet: tests))
                == ["simctl", "--set", tests.path, "shutdown", "ABCD-1234"])
        // Without its folder, simctl has no way to reach it.
        #expect(SimulatorControl.shutDownArguments(for: simulator(deviceSet: nil)) == nil)
    }

    /// A process that isn't a simulator must never be signalled, even when
    /// a stale entry carries its process ID.
    @Test func aReusedProcessIDIsNotTakenForASimulator() {
        let stale = Simulator(id: "pid-1", pid: getpid(), name: "Simulator", runtime: "",
                              kind: .other, bootedAt: Date(), deviceSet: nil)
        #expect(!SimulatorScanner.isRunning(stale))
    }
}
