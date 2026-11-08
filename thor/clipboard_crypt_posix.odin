#+build !windows
package thor

import "core:crypto"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"

// The key file in the user config directory, owner-only: <config>/thor/clipboard.key.
@(private = "file")
clipboard_key_path :: proc() -> (dir, path: string, ok: bool) {
    config, err := os.user_config_dir(context.temp_allocator)
    if err != nil {
        log.errorf("Could not find the user config dir: %v", err)
        return
    }
    jerr: os.Error
    if dir, jerr = filepath.join({config, "thor"}, context.temp_allocator); jerr != nil {
        log.errorf("Could not join the clipboard key dir: %v", jerr)
        return
    }
    if path, jerr = filepath.join({dir, "clipboard.key"}, context.temp_allocator); jerr != nil {
        log.errorf("Could not join the clipboard key path: %v", jerr)
        return
    }
    return dir, path, true
}

clipboard_key :: proc(create: bool) -> (key: Clipboard_Key, ok: bool) {
    dir, path := clipboard_key_path() or_return

    if os.exists(path) {
        data, err := os.read_entire_file(path, context.temp_allocator)
        if err != nil {
            log.errorf("Could not read %q: %v", path, err)
            return
        }
        defer mem.zero_explicit(raw_data(data), len(data))
        if len(data) != len(key) {
            log.errorf("%q holds a key of the wrong size", path)
            return
        }
        copy(key[:], data)
        return key, true
    }
    if !create {
        return
    }

    if !os.is_dir(dir) {
        if err := os.make_directory_all(dir, os.perm_number(0o700)); err != nil {
            log.errorf("Could not create %q: %v", dir, err)
            return
        }
    }
    crypto.rand_bytes(key[:])
    f, err := os.open(path, {.Write, .Create, .Excl}, os.perm_number(0o600))
    if err != nil {
        log.errorf("Could not create %q: %v", path, err)
        mem.zero_explicit(&key, len(key))
        return
    }
    defer os.close(f)
    if _, werr := os.write(f, key[:]); werr != nil {
        log.errorf("Could not write %q: %v", path, werr)
        mem.zero_explicit(&key, len(key))
        return
    }
    if serr := os.sync(f); serr != nil {
        log.warnf("Could not sync %q: %v", path, serr)
    }
    return key, true
}
