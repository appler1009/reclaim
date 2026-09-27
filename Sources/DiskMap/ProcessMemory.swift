import Darwin
import Foundation

/// The process's physical footprint, which is what `footprint` reports.
///
/// `ps` leaves out compressed memory, so an idle tree looks small until the
/// next walk faults it back in. This is the number to put next to a file count.
enum ProcessMemory {
    static var physFootprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride
                                            / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}

/// Above this, an unattended scan stops and an interactive one stops keeping
/// every small file. A single open volume is the case this is sized for.
enum ScanBudget {
    static let byteLimit: UInt64 = 1 << 30
}
