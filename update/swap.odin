package update

// Replacing an install's files with a staged copy of them.
//
// Every replaced name is renamed aside before its new copy lands, never removed
// first. A rename inside one directory is a metadata operation, so it is legal
// on a running image and on a loaded library, and it is what leaves a swap that
// dies part-way recoverable: restore_names puts the backups back at the next
// start. The one window it cannot cover is between the binary's rename and its
// copy, where there is no binary left to run it.
//
// Every path is an argument and no editor state is read, so the swap runs over
// a scratch directory in a test.

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The live path of `name` under `install` and the name its backup is kept
// under, which is the live path plus OLD_SUFFIX.
@(private)
swap_paths :: proc(install: string, name: string, allocator := context.temp_allocator) -> (live: string, old: string, ok: bool) {
    joined, err := filepath.join({install, name}, allocator)
    if err != nil {
        log.errorf("Could not build the path of %q under %q: %v", name, install, err)
        return "", "", false
    }
    return joined, strings.concatenate({joined, OLD_SUFFIX}, allocator), true
}

// Removes a file or a whole directory. `os.remove_all` opens its path as a
// directory, which answers ENOTDIR for a file on Darwin, so a file is unlinked.
@(private)
remove_path :: proc(path: string) -> os.Error {
    if os.is_dir(path) {
        return os.remove_all(path)
    }
    return os.remove(path)
}

// Moves each of `names` aside inside `install` and copies the staged copy in.
// All or none: the stage is read first, so a name the archive does not hold
// fails before anything moves, and a failure after the first rename puts every
// moved name back. `failed` names the file the swap stopped on.
swap_files :: proc(install: string, staged: string, names: []string) -> (failed: string, ok: bool) {
    sources := make([dynamic]string, 0, len(names), context.temp_allocator)
    for name in names {
        source, err := filepath.join({staged, name}, context.temp_allocator)
        if err != nil || !os.exists(source) {
            log.errorf("The staged build holds no %q", name)
            return name, false
        }
        append(&sources, source)
    }

    // The names already renamed aside, so a failure below knows what to undo.
    moved := make([dynamic]string, 0, len(names), context.temp_allocator)
    rollback := proc(install: string, moved: []string) {
        for name in moved {
            live, old, ok := swap_paths(install, name)
            if !ok {
                continue
            }
            if err := os.rename(old, live); err != nil {
                log.errorf("Could not undo the move of %q: %v", live, err)
            }
        }
    }

    for name in names {
        live, old, paths_ok := swap_paths(install, name, context.temp_allocator)
        if !paths_ok {
            rollback(install, moved[:])
            return name, false
        }
        // A backup from an earlier update. It has to go before the rename, and
        // a failure to remove it is a failure to replace the file.
        if err := os.remove(old); err != nil && os.exists(old) {
            log.errorf("Could not remove %q: %v", old, err)
            rollback(install, moved[:])
            return name, false
        }
        if err := os.rename(live, old); err != nil {
            log.errorf("Could not move %q aside: %v", live, err)
            rollback(install, moved[:])
            return name, false
        }
        append(&moved, name)
    }

    for name, index in names {
        live, _, paths_ok := swap_paths(install, name, context.temp_allocator)
        copy_err: os.Error = paths_ok ? os.copy_file(live, sources[index]) : .Invalid_Path
        if copy_err != nil {
            log.errorf("Could not copy %q into place: %v", name, copy_err)
            // Whatever landed is half a build, so it goes before the backups
            // come back.
            for done in moved {
                written, _, done_ok := swap_paths(install, done, context.temp_allocator)
                if !done_ok {
                    continue
                }
                if err := os.remove(written); err != nil && os.exists(written) {
                    log.errorf("Could not remove the half-written %q: %v", written, err)
                }
            }
            rollback(install, moved[:])
            return name, false
        }
        when ODIN_OS != .Windows {
            if err := os.change_mode(live, os.perm_number(0o755)); err != nil {
                log.warnf("Could not make %q executable: %v", live, err)
            }
        }
    }
    return "", true
}

// Replaces each of `dirs` under `install` with the staged one. A directory the
// stage does not hold is left alone. A failure is counted rather than stopping
// the rest: the backup stays under its .old name for the next start to restore,
// which is better than a binary newer than the whole tree beside it.
swap_dirs :: proc(install: string, staged: string, dirs: []string) -> (replaced: int, failed: int) {
    for dir in dirs {
        source, join_err := filepath.join({staged, dir}, context.temp_allocator)
        if join_err != nil {
            log.errorf("Could not build the source path for %q: %v", dir, join_err)
            failed += 1
            continue
        }
        if !os.exists(source) {
            continue
        }
        live, old, paths_ok := swap_paths(install, dir, context.temp_allocator)
        if !paths_ok {
            failed += 1
            continue
        }
        if err := remove_path(old); err != nil && os.exists(old) {
            log.errorf("Could not remove %q: %v", old, err)
            failed += 1
            continue
        }
        if err := os.rename(live, old); err != nil && os.exists(live) {
            log.errorf("Could not move %q aside: %v", live, err)
            failed += 1
            continue
        }
        if err := os.copy_directory_all(live, source); err != nil {
            log.errorf("Could not copy %q: %v", source, err)
            failed += 1
            continue
        }
        replaced += 1
    }
    return replaced, failed
}

// Copies the *.json files of `from` into `to`, creating it. A `to` that already
// exists is left alone, so this carries an older layout over at most once.
migrate_json_files :: proc(from: string, to: string) -> (carried: int, ok: bool) {
    if os.is_dir(to) || !os.is_dir(from) {
        return 0, false
    }
    entries, err := os.read_all_directory_by_path(from, context.temp_allocator)
    if err != nil {
        log.warnf("Could not read %q: %v", from, err)
        return 0, false
    }
    if make_err := os.make_directory_all(to); make_err != nil {
        log.errorf("Could not create %q: %v", to, make_err)
        return 0, false
    }
    for entry in entries {
        if entry.type == .Directory || !strings.has_suffix(entry.name, ".json") {
            continue
        }
        destination, dest_err := filepath.join({to, entry.name}, context.temp_allocator)
        source, source_err := filepath.join({from, entry.name}, context.temp_allocator)
        if dest_err != nil || source_err != nil {
            log.warnf("Could not build a path for %q: %v", entry.name, dest_err != nil ? dest_err : source_err)
            continue
        }
        if copy_err := os.copy_file(destination, source); copy_err != nil {
            log.warnf("Could not carry %q over: %v", entry.name, copy_err)
            continue
        }
        carried += 1
    }
    return carried, true
}
