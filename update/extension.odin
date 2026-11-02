package update

// Updates of one plugin or theme. A release item names a GitHub `owner/repo` and
// a local version, and installs the source archive of the latest release tag. A
// git item is a clone with an upstream, and installs with a fast-forward pull.
// A source archive carries no SHA256SUMS, so a release install checks only that
// the archive unpacks to the expected shape.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import "../atomicfile"
import "../shell"

// The staging folder of a plugin or theme install, beside the executable.
// Removed at every start, apart from the app's STAGE_DIR so the two never meet.
EXT_STAGE_DIR :: ".update-ext"

// How an item is updated.
Ext_Kind :: enum {
    Release,
    Git,
}

// One item to check or install. Every string is borrowed.
Ext_Target :: struct {
    kind:    Ext_Kind,
    path:    string, // the live plugin folder or theme file
    repo:    string, // Git: the clone that holds `path`
    version: string, // Release: the local version
    source:  string, // Release: owner/repo
}

// What a check found. Ok is an update; Up_To_Date is the ordinary answer.
Ext_Result :: struct {
    status: Status,
    latest: string, // owned; Release: the latest version, no leading v
    tag:    string, // owned; Release: the tag the install downloads
    behind: int,    // Git: commits the clone is behind its upstream
    dirty:  bool,   // Git: the clone has local changes
}

// Frees what an Ext_Result owns.
ext_result_destroy :: proc(result: ^Ext_Result, allocator := context.allocator) {
    delete(result.latest, allocator)
    delete(result.tag, allocator)
    result^ = {}
}

// Whether `s` is a GitHub owner/repo. An allowlist, since the value reaches a
// URL and a shell command.
source_valid :: proc(s: string) -> bool {
    slash := strings.index_byte(s, '/')
    if slash <= 0 || slash == len(s) - 1 || strings.count(s, "/") != 1 || strings.contains(s, "..") {
        return false
    }
    return name_chars_valid(s[:slash]) && name_chars_valid(s[slash + 1:])
}

// Whether every byte of `s` is a letter, a digit, '.', '_' or '-'.
@(private = "file")
name_chars_valid :: proc(s: string) -> bool {
    if s == "" {
        return false
    }
    for c in transmute([]u8)s {
        switch c {
        case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-':
        case:
            return false
        }
    }
    return true
}

// Reads a plugin tag, a version with an optional leading `v`.
ext_version_from_tag :: proc(tag: string) -> (version: Version, ok: bool) {
    if len(tag) > 1 && tag[0] == 'v' {
        return version_parse(tag[1:])
    }
    return version_parse(tag)
}

// The releases API address of `source`.
ext_api_url :: proc(source: string, allocator := context.allocator) -> string {
    return fmt.aprintf("https://api.github.com/repos/%s/releases/latest", source, allocator = allocator)
}

// The source archive of `tag` in `source`, zip or gzipped tar as `archive` names.
ext_archive_url :: proc(source: string, tag: string, archive: Archive, allocator := context.allocator) -> string {
    kind := archive == .Zip ? "zip" : "tar.gz"
    return fmt.aprintf("https://codeload.github.com/%s/%s/refs/tags/%s", source, kind, tag, allocator = allocator)
}

// Reads the output of `git rev-list --count`.
ext_parse_count :: proc(output: string) -> (count: int, ok: bool) {
    trimmed := strings.trim_space(output)
    if trimmed == "" {
        return 0, false
    }
    return strconv.parse_int(trimmed, 10)
}

// Asks whether `target` has an update. Runs on a worker thread. The strings of
// the result are owned by `allocator`.
ext_check :: proc(target: Ext_Target, agent: string, allocator := context.allocator) -> (result: Ext_Result) {
    switch target.kind {
    case .Release:
        return ext_check_release(target, agent, allocator)
    case .Git:
        return ext_check_git(target)
    }
    return result
}

@(private = "file")
ext_check_release :: proc(target: Ext_Target, agent: string, allocator := context.allocator) -> (result: Ext_Result) {
    if !source_valid(target.source) {
        result.status = .Bad_Source
        return result
    }
    running, parsed := ext_version_from_tag(target.version)
    if !parsed {
        result.status = .Bad_Tag
        return result
    }
    host, has_host := target_host()
    if !has_host {
        result.status = .No_Asset
        return result
    }
    tools, has_tools := tools_detect(target_archive(host))
    if !has_tools {
        result.status = .No_Tools
        return result
    }
    release, status := fetch_latest_release(tools, ext_api_url(target.source, context.temp_allocator), agent, context.temp_allocator)
    if status != .Ok {
        result.status = status
        return result
    }
    if !name_chars_valid(release.tag_name) {
        result.status = .Bad_Tag
        return result
    }
    latest, tagged := ext_version_from_tag(release.tag_name)
    if !tagged {
        result.status = .Bad_Tag
        return result
    }
    if !version_less(running, latest) {
        result.status = .Up_To_Date
        return result
    }
    version := release.tag_name[0] == 'v' ? release.tag_name[1:] : release.tag_name
    result.status = .Ok
    result.latest = strings.clone(version, allocator)
    result.tag = strings.clone(release.tag_name, allocator)
    return result
}

// Runs git in `repo`. The output is owned by the caller.
@(private = "file")
git :: proc(repo: string, args: ..string) -> (output: string, ok: bool) {
    full := make([dynamic]string, 0, len(args) + 2, context.temp_allocator)
    append(&full, "-C", repo)
    append(&full, ..args)
    out, code, ran := shell.exec_status("git", full[:], "", API_TIMEOUT)
    if !ran || code != 0 {
        log.debugf("git %v in %q stopped with %d: %s", args, repo, code, strings.trim_space(out))
        delete(out)
        return "", false
    }
    return out, true
}

@(private = "file")
ext_check_git :: proc(target: Ext_Target) -> (result: Ext_Result) {
    if fetched, ok := git(target.repo, "fetch", "--quiet"); ok {
        delete(fetched)
    } else {
        result.status = .No_Network
        return result
    }
    counted, has_upstream := git(target.repo, "rev-list", "--count", "HEAD..@{u}")
    defer delete(counted)
    if !has_upstream {
        result.status = .No_Upstream
        return result
    }
    behind, parsed := ext_parse_count(counted)
    if !parsed {
        result.status = .Bad_Response
        return result
    }
    if porcelain, ok := git(target.repo, "status", "--porcelain"); ok {
        result.dirty = strings.trim_space(porcelain) != ""
        delete(porcelain)
    }
    result.behind = behind
    result.status = behind > 0 ? .Ok : .Up_To_Date
    return result
}

// Installs the update a check found. Runs on a worker thread. A plugin folder
// is swapped whole; a theme file is replaced through atomicfile. `cancel` is
// read between download slices.
ext_install :: proc(target: Ext_Target, found: Ext_Result, agent: string, cancel: ^bool) -> Status {
    switch target.kind {
    case .Release:
        return ext_install_release(target, found, agent, cancel)
    case .Git:
        return ext_install_git(target)
    }
    return .Install_Failed
}

@(private = "file")
ext_install_git :: proc(target: Ext_Target) -> Status {
    porcelain, ok := git(target.repo, "status", "--porcelain")
    if !ok {
        return .Install_Failed
    }
    dirty := strings.trim_space(porcelain) != ""
    delete(porcelain)
    if dirty {
        return .Local_Changes
    }
    pulled, pull_ok := git(target.repo, "pull", "--ff-only", "--quiet")
    delete(pulled)
    return pull_ok ? .Ok : .Install_Failed
}

@(private = "file")
ext_install_release :: proc(target: Ext_Target, found: Ext_Result, agent: string, cancel: ^bool) -> Status {
    if !source_valid(target.source) {
        return .Bad_Source
    }
    if !name_chars_valid(found.tag) {
        return .Bad_Tag
    }
    host, has_host := target_host()
    if !has_host {
        return .No_Asset
    }
    archive := target_archive(host)
    tools, has_tools := tools_detect(archive)
    if !has_tools {
        return .No_Tools
    }

    if err := os.remove_all(EXT_STAGE_DIR); err != nil && os.exists(EXT_STAGE_DIR) {
        log.warnf("Could not clear %q: %v", EXT_STAGE_DIR, err)
        return .Install_Failed
    }
    unpacked, uerr := filepath.join({EXT_STAGE_DIR, "x"}, context.temp_allocator)
    if uerr != nil {
        return .Install_Failed
    }
    if err := os.make_directory_all(unpacked); err != nil {
        log.warnf("Could not make %q: %v", unpacked, err)
        return .Install_Failed
    }
    defer if err := os.remove_all(EXT_STAGE_DIR); err != nil {
        log.warnf("Could not clear %q: %v", EXT_STAGE_DIR, err)
    }

    archive_path, aerr := filepath.join({EXT_STAGE_DIR, archive == .Zip ? "source.zip" : "source.tar.gz"}, context.temp_allocator)
    if aerr != nil {
        return .Install_Failed
    }
    url := ext_archive_url(target.source, found.tag, archive, context.temp_allocator)
    if !fetch_file(tools, url, archive_path, agent, cancel) {
        return cancelled(cancel) ? .Cancelled : .Download_Failed
    }
    if !extract_archive(tools, archive_path, unpacked) {
        return .Extract_Failed
    }
    entries, rerr := os.read_all_directory_by_path(unpacked, context.temp_allocator)
    if rerr != nil || len(entries) != 1 || entries[0].type != .Directory {
        return .Bad_Archive
    }
    root, jerr := filepath.join({unpacked, entries[0].name}, context.temp_allocator)
    if jerr != nil {
        return .Install_Failed
    }

    name := filepath.base(target.path)
    parent := filepath.dir(target.path)
    if !os.is_dir(target.path) {
        return ext_replace_file(root, name, target.path)
    }

    plugin_file, perr := filepath.join({root, "plugin.lua"}, context.temp_allocator)
    if perr != nil || !os.exists(plugin_file) {
        return .Bad_Archive
    }
    // swap_dirs reads the staged copy under the live folder's own name.
    staged, serr := filepath.join({EXT_STAGE_DIR, "y"}, context.temp_allocator)
    if serr != nil {
        return .Install_Failed
    }
    if err := os.make_directory_all(staged); err != nil {
        return .Install_Failed
    }
    named, nerr := filepath.join({staged, name}, context.temp_allocator)
    if nerr != nil {
        return .Install_Failed
    }
    if err := os.rename(root, named); err != nil {
        log.warnf("Could not move %q to %q: %v", root, named, err)
        return .Install_Failed
    }
    if _, failed := swap_dirs(parent, staged, {name}); failed > 0 {
        return .Install_Failed
    }
    // The backup would read as a second plugin to the next scan.
    _, old, ok := swap_paths(parent, name)
    if ok {
        if err := remove_path(old); err != nil && os.exists(old) {
            log.warnf("Could not remove %q: %v", old, err)
        }
    }
    return .Ok
}

// Replaces the theme file `live` with the file of the same name at the root of
// the unpacked archive.
@(private = "file")
ext_replace_file :: proc(root: string, name: string, live: string) -> Status {
    source, jerr := filepath.join({root, name}, context.temp_allocator)
    if jerr != nil {
        return .Install_Failed
    }
    data, rerr := os.read_entire_file(source, context.temp_allocator)
    if rerr != nil {
        return .Bad_Archive
    }
    if err := atomicfile.write(live, data); err != nil {
        log.warnf("Could not write %q: %v", live, err)
        return .Install_Failed
    }
    return .Ok
}

// Copies each held name under `install` over its staged copy, so a swap from
// `staged` keeps the local one. A held name the install no longer has is
// removed from the stage, so the swap does not bring it back. Answers how many
// names could not be carried.
carry_held :: proc(install: string, staged: string, names: []string) -> (failed: int) {
    for name in names {
        live, lerr := filepath.join({install, name}, context.temp_allocator)
        fresh, ferr := filepath.join({staged, name}, context.temp_allocator)
        if lerr != nil || ferr != nil {
            failed += 1
            continue
        }
        if err := remove_path(fresh); err != nil && os.exists(fresh) {
            log.errorf("Could not remove the staged %q: %v", fresh, err)
            failed += 1
            continue
        }
        if !os.exists(live) {
            continue
        }
        if parent := filepath.dir(fresh); parent != "" {
            if err := os.make_directory_all(parent); err != nil && !os.is_dir(parent) {
                log.errorf("Could not make %q: %v", parent, err)
                failed += 1
                continue
            }
        }
        copy_err: os.Error
        if os.is_dir(live) {
            copy_err = copy_tree(fresh, live)
        } else {
            copy_err = os.copy_file(fresh, live)
        }
        if copy_err != nil {
            log.errorf("Could not keep the held %q: %v", name, copy_err)
            failed += 1
        }
    }
    return failed
}

// Copies the directory `src` to `dst`. os.copy_directory_all keeps a handle on
// `src` on Windows, which then refuses the rename of the live folder.
@(private = "file")
copy_tree :: proc(dst: string, src: string) -> os.Error {
    if err := os.make_directory_all(dst); err != nil && err != .Exist {
        return err
    }
    entries := os.read_all_directory_by_path(src, context.temp_allocator) or_return
    for entry in entries {
        from := filepath.join({src, entry.name}, context.temp_allocator) or_return
        to := filepath.join({dst, entry.name}, context.temp_allocator) or_return
        if entry.type == .Directory {
            copy_tree(to, from) or_return
        } else {
            os.copy_file(to, from) or_return
        }
    }
    return nil
}
