#+build darwin, freebsd, openbsd, netbsd
package thor

import "core:os"
import "core:sys/posix"

// Whether a rename/move failed because the source and destination are on
// different volumes.
thor_is_cross_device_error :: proc(err: os.Error) -> bool {
    pe, ok := err.(os.Platform_Error)
    return ok && posix.Errno(pe) == .EXDEV
}
