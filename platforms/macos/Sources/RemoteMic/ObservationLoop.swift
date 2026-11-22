import Foundation
import Observation

/// Runs `body` now, and again after each change to an observable property it
/// read.
///
/// Observation reports a change before the new value is stored, so the re-run
/// is queued on the main run loop (common modes, like Combine's
/// `receive(on: RunLoop.main)`), where the new value is visible. Changes made
/// before that re-run are coalesced into one. The loop ends once `body` reads
/// no observable property (for example after its owner is gone).
enum ObservationLoop {
    static func run(_ body: @escaping () -> Void) {
        withObservationTracking(body) {
            let mainLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) { run(body) }
            CFRunLoopWakeUp(mainLoop)
        }
    }
}
