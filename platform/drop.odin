package platform

import "core:strings"
import rl "vendor:raylib"

// raylib 6.0 lays FilePathList out as {count, capacity, paths}, but the
// vendor:raylib binding still declares raylib 5's {capacity, count, paths}.
@(private = "file")
Dropped_Files :: struct {
    count:    u32,
    capacity: u32,
    paths:    [^]cstring,
}

// The paths dropped on the window since the last call, cloned with `allocator`.
// Empty when nothing was dropped.
take_dropped_files :: proc(allocator := context.temp_allocator) -> []string {
    if !rl.IsFileDropped() {
        return nil
    }
    dropped := rl.LoadDroppedFiles()
    defer rl.UnloadDroppedFiles(dropped)
    files := transmute(Dropped_Files)dropped

    paths := make([]string, files.count, allocator)
    for i in 0 ..< files.count {
        paths[i] = strings.clone(string(files.paths[i]), allocator)
    }
    return paths
}
