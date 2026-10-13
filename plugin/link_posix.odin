#+build !windows
package plugin

import "base:runtime"
import "core:os"
import "core:path/filepath"

// `path` made absolute against the working directory, with no link followed.
// os.get_absolute_path is realpath here: it resolves a link before
// has_link_below can see it.
@(private)
path_absolute :: proc(path: string, allocator: runtime.Allocator) -> (string, os.Error) {
    if filepath.is_abs(path) {
        return filepath.clean(path, allocator)
    }
    cwd, err := os.get_working_directory(context.temp_allocator)
    if err != nil {
        return "", err
    }
    joined, jerr := filepath.join({cwd, path}, context.temp_allocator)
    if jerr != nil {
        return "", jerr
    }
    return filepath.clean(joined, allocator)
}

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
