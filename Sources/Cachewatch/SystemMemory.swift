import Foundation

enum SystemMemory {
    static let totalBytes = ProcessInfo.processInfo.physicalMemory

    /// Activity-Monitor-style "used": active + wired + compressed pages.
    /// macOS keeps free memory near zero by design (file cache), so raw free
    /// is meaningless — this is the number that reflects real pressure.
    static func usedBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * pageSize
    }
}
