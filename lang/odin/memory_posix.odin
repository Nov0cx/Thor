#+build !windows
package odin

import "core:sys/posix"

// The resident and private bytes of this process, and the peak resident bytes. Zero when unknown.
// POSIX gives only the peak.
process_memory :: proc() -> (resident, peak, private: int) {
    usage: posix.rusage
    if posix.getrusage(.SELF, &usage) != .OK {
        return 0, 0, 0
    }
    // ru_maxrss is kilobytes on Linux and bytes on macOS.
    when ODIN_OS == .Darwin {
        peak = int(usage.ru_maxrss)
    } else {
        peak = int(usage.ru_maxrss) * 1024
    }
    return 0, peak, 0
}
