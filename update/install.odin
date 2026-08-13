package update

// Staging an update, and cleaning up after one.
//
// install_apply only ever adds: it downloads, verifies and unpacks into
// STAGE_DIR and stops there. Nothing beside the running binary is touched until
// the caller performs the swap, so a failure at any step leaves the install as
// it was and the next start removes the staging folder.

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import "../shell"

// The names the swap replaces, each renamed aside before its new copy lands.
// The order is the swap's: the binary and the library it loads move first, as
// one group, because a failure there is the only one that needs a rollback.
// settings/ is in the list because it holds shipped defaults only — what the
// user writes lives in user/, which no update touches.
SWAPPED_DIRS :: [?]string{"assets", "plugins", "docs", "settings"}

// The file the writability probe creates and removes.
@(private = "file")
PROBE_FILE :: ".update-probe"

// Whether this build may replace itself. A debug build and a build run out of
// the repository's bin/ are refused: they are not what a release archive holds,
// and overwriting one would throw away a working tree.
installable :: proc() -> (ok: bool, why: Status) {
    when ODIN_DEBUG {
        return false, .Not_Installable
    }
    if in_dev_tree() {
        return false, .Not_Installable
    }
    if !install_dir_writable() {
        return false, .Not_Installable
    }
    return true, .Ok
}

// Whether the working directory — the executable's own, since Thor moves there
// at start — takes a new file. This is the /opt and Program Files case.
install_dir_writable :: proc() -> bool {
    handle, err := os.open(PROBE_FILE, {.Write, .Create, .Trunc})
    if err != nil {
        return false
    }
    if close_err := os.close(handle); close_err != nil {
        log.warnf("Could not close %q: %v", PROBE_FILE, close_err)
    }
    if remove_err := os.remove(PROBE_FILE); remove_err != nil {
        log.warnf("Could not remove %q: %v", PROBE_FILE, remove_err)
    }
    return true
}

// Whether the executable sits in the repository's own bin/debug or bin/release.
// A staged build there has assets/ beside it like a release does, so the
// build.odin above it is what tells the two apart.
@(private = "file")
in_dev_tree :: proc() -> bool {
    exe, err := os.get_executable_path(context.temp_allocator)
    if err != nil {
        return false
    }
    dir := os.dir(exe)
    name := filepath.base(dir)
    if name != "debug" && name != "release" && name != "test" {
        return false
    }
    parent := os.dir(dir)
    if filepath.base(parent) != "bin" {
        return false
    }
    driver, join_err := filepath.join({os.dir(parent), "build.odin"}, context.temp_allocator)
    if join_err != nil {
        return false
    }
    return os.exists(driver)
}

// Downloads, verifies and unpacks a release into STAGE_DIR. On success `root`
// is the unpacked folder the swap copies from. Runs on a worker thread and
// reads `cancel` between download slices.
install_apply :: proc(plan: Install_Plan, agent: string, cancel: ^bool, allocator := context.allocator) -> (result: Install_Result) {
    if ok, why := installable(); !ok {
        result.status = why
        return result
    }

    tools, has_tools := tools_detect(target_archive(plan.target))
    if !has_tools {
        result.status = .No_Tools
        return result
    }

    // A leftover from an interrupted run, so its absence is the wanted state
    // and only a failure to reach it counts.
    if err := os.remove_all(STAGE_DIR); err != nil && os.exists(STAGE_DIR) {
        log.warnf("Could not clear %q: %v", STAGE_DIR, err)
        result.status = .Install_Failed
        return result
    }
    if err := os.make_directory_all(STAGE_DIR); err != nil {
        log.warnf("Could not make %q: %v", STAGE_DIR, err)
        result.status = .Install_Failed
        return result
    }
    // Every failure below leaves nothing behind: the staging folder is the only
    // thing written, and it goes with the error.
    staged := false
    defer if !staged {
        if err := os.remove_all(STAGE_DIR); err != nil {
            log.warnf("Could not clear %q: %v", STAGE_DIR, err)
        }
    }

    archive_path, archive_ok := stage_path(plan.asset, context.temp_allocator)
    if !archive_ok {
        result.status = .Install_Failed
        return result
    }
    if !fetch_file(tools, plan.url, archive_path, agent, cancel) {
        result.status = cancelled(cancel) ? .Cancelled : .Download_Failed
        return result
    }
    if info, stat_err := os.stat(archive_path, context.temp_allocator); stat_err != nil || info.size != plan.size {
        result.status = .Bad_Size
        return result
    }

    sums_path, sums_ok := stage_path(SUMS_ASSET, context.temp_allocator)
    if !sums_ok {
        result.status = .Install_Failed
        return result
    }
    if !fetch_file(tools, plan.sums_url, sums_path, agent, cancel) {
        result.status = cancelled(cancel) ? .Cancelled : .No_Asset
        return result
    }
    sums_data, sums_err := os.read_entire_file(sums_path, context.temp_allocator)
    if sums_err != nil {
        result.status = .No_Asset
        return result
    }
    expected, listed := checksums_find(string(sums_data), plan.asset)
    if !listed {
        result.status = .No_Asset
        return result
    }
    digest, hashed := sha256_file(archive_path)
    if !hashed || !digest_matches(digest, expected) {
        result.status = .Bad_Checksum
        return result
    }

    unpacked, unpacked_ok := stage_path("x", context.temp_allocator)
    if !unpacked_ok {
        result.status = .Install_Failed
        return result
    }
    if err := os.make_directory_all(unpacked); err != nil {
        log.warnf("Could not make %q: %v", unpacked, err)
        result.status = .Install_Failed
        return result
    }
    if !extract_archive(tools, archive_path, unpacked) {
        result.status = .Extract_Failed
        return result
    }

    root, rooted := archive_root(unpacked, plan.target, allocator)
    if !rooted {
        result.status = .Bad_Archive
        return result
    }

    when ODIN_OS == .Darwin {
        // curl does not set the quarantine attribute, but a future transport
        // could, and the release notes tell the user to clear it by hand.
        command := strings.concatenate({"xattr -dr com.apple.quarantine \"", root, "\""}, context.temp_allocator)
        output, _, _ := shell.run_status(command, "", XATTR_TIMEOUT)
        delete(output)
    }
    when ODIN_OS != .Windows {
        exe, join_err := filepath.join({root, target_exe_name(plan.target)}, context.temp_allocator)
        if join_err != nil {
            result.status = .Install_Failed
            return result
        }
        if err := os.change_mode(exe, os.perm_number(0o755)); err != nil {
            log.warnf("Could not make %q executable: %v", exe, err)
        }
    }

    staged = true
    result.status = .Ok
    result.root = root
    return result
}

// Frees what an install owns.
install_result_destroy :: proc(result: ^Install_Result, allocator := context.allocator) {
    delete(result.root, allocator)
    delete(result.detail, allocator)
    result^ = {}
}

// The single folder an archive unpacks to. Requiring exactly one entry is also
// what refuses an archive that spills its files over the staging directory.
@(private = "file")
archive_root :: proc(dir: string, target: Target, allocator := context.allocator) -> (root: string, ok: bool) {
    entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
    if err != nil || len(entries) != 1 || entries[0].type != .Directory {
        return "", false
    }
    found, join_err := filepath.join({dir, entries[0].name}, allocator)
    if join_err != nil {
        return "", false
    }
    exe, exe_err := filepath.join({found, target_exe_name(target)}, context.temp_allocator)
    if exe_err != nil || !os.exists(exe) {
        delete(found, allocator)
        return "", false
    }
    return found, true
}

// A path inside the staging folder.
@(private = "file")
stage_path :: proc(name: string, allocator := context.allocator) -> (path: string, ok: bool) {
    joined, err := filepath.join({STAGE_DIR, name}, allocator)
    if err != nil {
        log.errorf("Could not build a path under %q: %v", STAGE_DIR, err)
        return "", false
    }
    return joined, true
}

@(private = "file")
cancelled :: proc(cancel: ^bool) -> bool {
    return cancel != nil && sync.atomic_load(cancel)
}

// Settles whatever a previous run left behind, and must run before anything
// reads assets/, plugins/ or settings/. For each replaced name: the backup goes
// when the new file is in place, and comes back when it is not. The one case it
// cannot answer is a death between the binary's rename and its copy, where
// there is no binary left to run this.
install_cleanup_leftovers :: proc() {
    names := make([dynamic]string, 0, 8, context.temp_allocator)
    append(&names, "thor" + EXE_SUFFIX)
    when ODIN_OS == .Windows {
        append(&names, "lua54.dll")
    }
    when ODIN_OS == .Darwin {
        append(&names, "libs")
    }
    for dir in SWAPPED_DIRS {
        append(&names, dir)
    }

    for live in names {
        old := strings.concatenate({live, OLD_SUFFIX}, context.temp_allocator)
        if !os.exists(old) {
            continue
        }
        if os.exists(live) {
            if err := os.remove_all(old); err != nil {
                log.warnf("Could not remove %q: %v", old, err)
            }
            continue
        }
        log.warnf("An interrupted update left %q behind, putting it back", old)
        if err := os.rename(old, live); err != nil {
            log.errorf("Could not restore %q: %v", live, err)
        }
    }
    if err := os.remove_all(STAGE_DIR); err != nil && os.exists(STAGE_DIR) {
        log.warnf("Could not clear %q: %v", STAGE_DIR, err)
    }
}

// The extension the running platform's binary carries.
EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""
