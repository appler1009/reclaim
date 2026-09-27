import Foundation

/// One heavy filesystem walk at a time, for the whole process.
///
/// A tab, the nightly rescan, the watchlist, `scan_now` and the Trash
/// measurement each used to start their own walk, and each walk starts a pool
/// of readers. The trees then sit on top of each other. Callers take a permit
/// and hold it until the walk returns.
///
/// A scan a person started waits, and cancels an unattended walk that is
/// already inside so it can begin. Unattended walks wait their turn rather
/// than running beside it. They do not start at all when the system is under
/// memory pressure — that check belongs to the caller, before it asks here.
final class ScanGate: @unchecked Sendable {
    static let shared = ScanGate()

    private let condition = NSCondition()
    private var holder: Holder?

    private struct Holder {
        let unattended: Bool
        let cancel: () -> Void
    }

    final class Permit: @unchecked Sendable {
        private let gate: ScanGate
        private var active = true

        fileprivate init(gate: ScanGate) {
            self.gate = gate
        }

        func release() {
            gate.condition.lock()
            defer { gate.condition.unlock() }
            guard active else { return }
            active = false
            gate.holder = nil
            gate.condition.broadcast()
        }
    }

    /// `unattended` waits behind whoever is inside. An interactive caller
    /// cancels an unattended holder on the way in, then waits for it to leave.
    func acquire(unattended: Bool, cancel: @escaping () -> Void) -> Permit {
        condition.lock()
        while holder != nil {
            if !unattended, holder?.unattended == true {
                holder?.cancel()
            }
            condition.wait()
        }
        holder = Holder(unattended: unattended, cancel: cancel)
        condition.unlock()
        return Permit(gate: self)
    }
}
