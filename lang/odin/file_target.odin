// Per-file build targets: the os and arch one file is analyzed and checked for, set by the editor.
package odin

import "core:log"
import "core:strings"
import "core:sync"

import odinsema "sema"

// The os and arch the editor sets for one file.
@(private)
File_Target :: struct {
    os:   odinsema.Target_OS,
    arch: odinsema.Target_Arch,
}

// Sets the build target of the file at `path` to the `-target:` value `triple`. An empty triple clears it.
// False when the path is empty or the compiler has no such target; the old choice then stays.
engine_set_target :: proc(e: ^Engine, path, triple: string) -> bool {
    if path == "" {
        return false
    }
    choice: File_Target
    if triple != "" {
        target_os, arch, ok := target_from_triple(triple)
        if !ok {
            log.warnf("build target %q is not a compiler target and was ignored", triple)
            return false
        }
        choice = File_Target{os = target_os, arch = arch}
    }
    key := odinsema.path_key(path)
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    if triple == "" {
        if key in cache.file_targets {
            old_key, _ := delete_key(&cache.file_targets, key)
            delete(old_key, cache.alloc)
        }
        return true
    }
    if _, found := cache.file_targets[key]; found {
        cache.file_targets[key] = choice
        return true
    }
    if cache.file_targets == nil {
        cache.file_targets = make(map[string]File_Target, cache.alloc)
    }
    owned, err := strings.clone(key, cache.alloc)
    if err != nil {
        return false
    }
    if _, _, _, merr := map_entry(&cache.file_targets, owned); merr != nil {
        delete(owned, cache.alloc)
        return false
    }
    cache.file_targets[owned] = choice
    return true
}

// Clears the build target of every file.
engine_clear_targets :: proc(e: ^Engine) {
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    file_targets_free(cache)
}

// The `-target:` value the file at `path` is analyzed for, and true when the file has its own.
// Without its own, the workspace config as last read, else the host. Reads no file.
engine_target_label :: proc(e: ^Engine, workspace, path: string) -> (triple: string, own: bool) {
    host := odinsema.target_host()
    target_os, arch := host.os, host.arch
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    if choice, found := file_target_lookup(cache, path); found {
        return target_triple(choice.os, choice.arch), true
    }
    if workspace != "" && cache.loaded && cache.workspace == workspace {
        if cache.cfg.target_os != .Unknown {
            target_os = cache.cfg.target_os
        }
        if cache.cfg.target_arch != .Unknown {
            arch = cache.cfg.target_arch
        }
    }
    return target_triple(target_os, arch), false
}

// Every `-target:` value target_triple knows, by os then arch.
target_names :: proc(allocator := context.temp_allocator) -> []string {
    out := make([dynamic]string, allocator)
    for target_os in odinsema.Target_OS {
        for arch in odinsema.Target_Arch {
            if triple := target_triple(target_os, arch); triple != "" {
                append(&out, triple)
            }
        }
    }
    return out[:]
}

// The os and arch of a `-target:` value, case-insensitive. False when the compiler has no such target.
target_from_triple :: proc(triple: string) -> (target_os: odinsema.Target_OS, arch: odinsema.Target_Arch, ok: bool) {
    if triple == "" {
        return
    }
    for o in odinsema.Target_OS {
        for a in odinsema.Target_Arch {
            if name := target_triple(o, a); name != "" && strings.equal_fold(name, triple) {
                return o, a, true
            }
        }
    }
    return
}

// The build target the editor set for `path`. Caller holds cache.mutex.
@(private)
file_target_lookup :: proc(cache: ^Config_Cache, path: string) -> (File_Target, bool) {
    if path == "" || len(cache.file_targets) == 0 {
        return {}, false
    }
    choice, found := cache.file_targets[odinsema.path_key(path)]
    return choice, found
}

// Frees every per-file target. Caller holds cache.mutex.
@(private)
file_targets_free :: proc(cache: ^Config_Cache) {
    for key in cache.file_targets {
        delete(key, cache.alloc)
    }
    delete(cache.file_targets)
    cache.file_targets = nil
}
