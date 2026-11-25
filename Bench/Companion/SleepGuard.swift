import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from going to sleep on its own while an agent is working,
/// the way a download does. A closed laptop lid still sleeps it unless
/// it's plugged in with that setting on.
final class SleepGuard {
    private var assertion: IOPMAssertionID = 0
    private(set) var isHolding = false

    func set(_ hold: Bool) {
        guard hold != isHolding else { return }
        if hold {
            let reason = "An agent in Workbench is working, and your iPhone may be watching it." as CFString
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion)
            isHolding = result == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            isHolding = false
        }
    }

    deinit { if isHolding { IOPMAssertionRelease(assertion) } }
}
