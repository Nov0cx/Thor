package atomicfile

// Replaces a file in one step: the data goes to a temp file beside the target,
// then a rename puts it at the target. A crash, a kill or a full disk leaves the
// old file whole.

import "core:log"
import "core:os"
import "core:strings"
import "core:time"

// The most symlink hops followed to the real file.
@(private)
MAX_LINK_HOPS :: 16

// Writes `data` to `path`. A symlink is followed, so its target is replaced and
// the link stays. When no temp file can be made beside the target, or the rename
// is refused, it writes the target in place.
write :: proc(path: string, data: []byte) -> os.Error {
    target := resolve_links(path)
    if err := write_replace(target, data); err == nil {
        return nil
    } else {
        log.warnf("Cannot replace %q in one step, writing it in place: %v", target, err)
    }
    return os.write_entire_file(target, data)
}

// The file `path` names after its symlinks. A link that cannot be read is
// taken as the path itself.
@(private)
resolve_links :: proc(path: string) -> string {
    current := path
    for _ in 0 ..< MAX_LINK_HOPS {
        info, err := os.lstat(current, context.temp_allocator)
        if err != nil || info.type != .Symlink {
            return current
        }
        link, link_err := os.read_link(current, context.temp_allocator)
        if link_err != nil || link == "" {
            return current
        }
        if os.is_absolute_path(link) {
            current = link
            continue
        }
        joined, join_err := os.join_path({parent_dir(current), link}, context.temp_allocator)
        if join_err != nil {
            return current
        }
        current = joined
    }
    return current
}

// The directory part of `path`, "." when it names none.
@(private)
parent_dir :: proc(path: string) -> string {
    dir, _ := os.split_path(path)
    return dir == "" ? "." : dir
}

@(private)
write_replace :: proc(target: string, data: []byte) -> os.Error {
    _, base := os.split_path(target)
    pattern := strings.concatenate({".", base, ".*.tmp"}, context.temp_allocator)
    f, create_err := os.create_temp_file(parent_dir(target), pattern)
    if create_err != nil {
        return create_err
    }
    temp := strings.clone(os.name(f), context.temp_allocator)

    err := fill(f, target, data)
    if close_err := os.close(f); err == nil {
        err = close_err
    }
    if err == nil {
        err = retry_rename(temp, target)
    }
    if err != nil {
        if rerr := retry_remove(temp); rerr != nil && os.exists(temp) {
            log.warnf("Cannot remove the temp file %q: %v", temp, rerr)
        }
    }
    return err
}

// How often a refused rename or remove is tried. A virus scanner or an indexer
// on Windows opens a new file for a moment, and the call then fails with a
// sharing violation.
@(private)
RETRIES :: 10 when ODIN_OS == .Windows else 1

@(private)
RETRY_STEP :: 5 * time.Millisecond

@(private)
retry_rename :: proc(from, to: string) -> (err: os.Error) {
    for attempt in 0 ..< RETRIES {
        if err = os.rename(from, to); err != .Permission_Denied {
            return
        }
        time.sleep(time.Duration(attempt + 1) * RETRY_STEP)
    }
    return
}

@(private)
retry_remove :: proc(path: string) -> (err: os.Error) {
    for attempt in 0 ..< RETRIES {
        if err = os.remove(path); err != .Permission_Denied {
            return
        }
        time.sleep(time.Duration(attempt + 1) * RETRY_STEP)
    }
    return
}

// Writes and flushes `data` into the temp file, giving it the mode of the file
// it replaces.
@(private)
fill :: proc(f: ^os.File, target: string, data: []byte) -> os.Error {
    when ODIN_OS != .Windows {
        if info, err := os.stat(target, context.temp_allocator); err == nil {
            if merr := os.fchange_mode(f, info.mode); merr != nil {
                log.warnf("Cannot keep the mode of %q: %v", target, merr)
            }
        }
    }
    written := 0
    for written < len(data) {
        n, err := os.write(f, data[written:])
        if err != nil {
            return err
        }
        if n <= 0 {
            return .Short_Write
        }
        written += n
    }
    return os.sync(f)
}
