#+build !windows
package odin

import "base:runtime"
import "core:path/filepath"

// filepath.abs (os.get_absolute_path) already shells out to realpath(3) on
// POSIX, which resolves symlinks and `.`/`..` on its own — this exists only so
// index.odin has one path_real name to call regardless of platform.
path_real :: proc(path: string, allocator: runtime.Allocator) -> (string, bool) {
    abs, err := filepath.abs(path, allocator)
    return abs, err == nil
}
