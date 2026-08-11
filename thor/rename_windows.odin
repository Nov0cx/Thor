#+build windows
package thor

import "core:os"
import win32 "core:sys/windows"

// Whether a rename/move failed because the source and destination are on
// different volumes.
thor_is_cross_device_error :: proc(err: os.Error) -> bool {
    pe, ok := err.(os.Platform_Error)
    return ok && win32.System_Error(pe) == .NOT_SAME_DEVICE
}
