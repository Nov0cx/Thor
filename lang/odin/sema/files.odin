package odinsema

import "core:os"
import "core:strings"

// `path` spelled for comparison: absolute, forward slashes, and lower case where the file system
// ignores case.
path_key :: proc(path: string, allocator := context.temp_allocator) -> string {
    abs, err := os.get_absolute_path(path, context.temp_allocator)
    if err != nil {
        abs = path
    }
    key, _ := strings.replace_all(abs, "\\", "/", context.temp_allocator)
    when ODIN_OS == .Windows || ODIN_OS == .Darwin {
        key = strings.to_lower(key, context.temp_allocator)
    }
    out, _ := strings.clone(key, allocator)
    return out
}

// Byte offset of each line start in `source`.
line_starts :: proc(source: string, allocator := context.temp_allocator) -> []int {
    count := 1
    for i in 0 ..< len(source) {
        if source[i] == '\n' {
            count += 1
        }
    }
    starts, err := make([]int, count, allocator)
    if err != nil {
        return nil
    }
    n := 1
    for i in 0 ..< len(source) {
        if source[i] == '\n' {
            starts[n] = i + 1
            n += 1
        }
    }
    return starts
}
