// Reading a file the way the editor holds it. The byte space every offset in
// this seam is counted in — CRLF collapsed to LF — is defined here, so a backend
// that reads a file from disk means the same thing by an offset as one that
// reads a live buffer.
package lang

import "core:os"
import "core:strings"

// Reads a source file the way the editor holds it: CRLF collapsed to LF. Every
// offset the seam reports is in that space, so it means the same thing on disk
// and in an open buffer. Read source through this, never os.read_entire_file.
source_read :: proc(path: string, allocator := context.temp_allocator) -> (string, bool) {
    data, rerr := os.read_entire_file(path, allocator)
    if rerr != nil {
        return "", false
    }
    source := string(data)
    if !strings.contains(source, "\r\n") {
        return source, true
    }
    out, allocated := strings.replace_all(source, "\r\n", "\n", allocator)
    if allocated {
        delete(data, allocator) // the read before the collapse, dead once `out` holds it
    }
    return out, true
}
