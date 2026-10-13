#+build !windows
package plugin

import "core:os"

// What `path` is, read with lstat so the link is not followed.
@(private)
path_link_state :: proc(path: string) -> Link_State {
    info, err := os.lstat(path, context.temp_allocator)
    if err == .Not_Exist {
        return .Missing
    }
    if err != nil {
        return .Unknown
    }
    return .Link if info.type == .Symlink else .Plain
}
