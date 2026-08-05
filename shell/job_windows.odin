#+build windows
package shell

import win32 "core:sys/windows"

foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "system", private)
foreign kernel32 {
    CreateJobObjectW         :: proc(attributes: rawptr, name: win32.LPCWSTR) -> win32.HANDLE ---
    SetInformationJobObject  :: proc(job: win32.HANDLE, class: i32, info: rawptr, length: win32.DWORD) -> win32.BOOL ---
    AssignProcessToJobObject :: proc(job: win32.HANDLE, process: win32.HANDLE) -> win32.BOOL ---
    TerminateJobObject       :: proc(job: win32.HANDLE, exit_code: win32.UINT) -> win32.BOOL ---
}

@(private)
JobObjectExtendedLimitInformation :: 9

@(private)
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x00002000

@(private)
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
    PerProcessUserTimeLimit: win32.LARGE_INTEGER,
    PerJobUserTimeLimit:     win32.LARGE_INTEGER,
    LimitFlags:              win32.DWORD,
    MinimumWorkingSetSize:   win32.SIZE_T,
    MaximumWorkingSetSize:   win32.SIZE_T,
    ActiveProcessLimit:      win32.DWORD,
    Affinity:                win32.ULONG_PTR,
    PriorityClass:           win32.DWORD,
    SchedulingClass:         win32.DWORD,
}

@(private)
IO_COUNTERS :: struct {
    ReadOperationCount:  win32.ULONGLONG,
    WriteOperationCount: win32.ULONGLONG,
    OtherOperationCount: win32.ULONGLONG,
    ReadTransferCount:   win32.ULONGLONG,
    WriteTransferCount:  win32.ULONGLONG,
    OtherTransferCount:  win32.ULONGLONG,
}

@(private)
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo:                IO_COUNTERS,
    ProcessMemoryLimit:    win32.SIZE_T,
    JobMemoryLimit:        win32.SIZE_T,
    PeakProcessMemoryUsed: win32.SIZE_T,
    PeakJobMemoryUsed:     win32.SIZE_T,
}

// A job whose processes die with it, which is what makes a kill reach the
// grandchildren a shell started. Returns nil when the job cannot be set up,
// which only costs the caller the child-tree cleanup.
@(private)
create_kill_on_close_job :: proc() -> win32.HANDLE {
    job := CreateJobObjectW(nil, nil)
    if job == nil {
        return nil
    }
    limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, size_of(limits)) {
        win32.CloseHandle(job)
        return nil
    }
    return job
}
