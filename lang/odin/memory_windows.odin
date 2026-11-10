#+build windows
package odin

import win "core:sys/windows"

// The resident and private bytes of this process, and the peak resident bytes. Zero when unknown.
process_memory :: proc() -> (resident, peak, private: int) {
    pmc: win.PROCESS_MEMORY_COUNTERS_EX
    pmc.cb = size_of(pmc)
    if !win.GetProcessMemoryInfo(win.GetCurrentProcess(), &pmc.counter, pmc.cb) {
        return 0, 0, 0
    }
    return int(pmc.WorkingSetSize), int(pmc.PeakWorkingSetSize), int(pmc.PrivateUsage)
}
