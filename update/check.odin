package update

// What the latest release is. Runs on a worker thread and touches nothing the
// editor owns; the whole answer is one Check_Result the caller frees.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

// The check writes the API reply beside the executable only when it may also
// install; otherwise it uses the system temporary directory, so a Thor in a
// read-only directory still learns that an update exists. The thread id keeps
// the app check and a plugin check apart.
@(private = "file")
API_FILE_FORMAT :: "thor-update-api-%d.json"

// Asks GitHub what the latest release is and whether it is newer than
// `current`. Every string of the result is owned by `allocator`.
check :: proc(current: string, cancel: ^bool = nil, allocator := context.allocator) -> (result: Check_Result) {
    running, parsed := version_parse(current)
    if !parsed {
        // A binary whose version is not a release version cannot be compared
        // against one, and must never install over itself.
        result.status = .Not_Installable
        return result
    }

    target, has_target := target_host()
    if !has_target {
        result.status = .No_Asset
        return result
    }

    tools, has_tools := tools_detect(target_archive(target), cancel)
    if cancelled(cancel) {
        result.status = .Cancelled
        return result
    }
    if !has_tools {
        result.status = .No_Tools
        return result
    }

    agent := user_agent(current, context.temp_allocator)
    release, status := fetch_latest_release(tools, API_URL, agent, cancel, context.temp_allocator)
    if status != .Ok {
        result.status = status
        return result
    }

    latest, tagged := version_from_tag(release.tag_name)
    if !tagged {
        result.status = .Bad_Tag
        return result
    }
    if !version_less(running, latest) {
        result.status = .Up_To_Date
        return result
    }

    version := release.tag_name[1:]
    asset_name := target_asset_name(target, version, context.temp_allocator)
    asset, has_asset := release_find_asset(release, asset_name)
    if !has_asset {
        result.status = .No_Asset
        return result
    }
    sums, has_sums := release_find_asset(release, SUMS_ASSET)
    if !has_sums {
        // The checksum is not optional, so a release without one is not an
        // update this can offer.
        result.status = .No_Asset
        return result
    }
    if !url_is_release_download(asset.browser_download_url) ||
       !url_is_release_download(sums.browser_download_url) {
        result.status = .Bad_Url
        return result
    }
    if asset.size <= 0 || asset.size > MAX_ASSET_BYTES {
        result.status = .Bad_Size
        return result
    }

    notes := release.body
    if len(notes) > NOTES_MAX {
        notes = notes[:NOTES_MAX]
    }

    result.status = .Ok
    result.version = strings.clone(version, allocator)
    result.notes = strings.clone(strings.trim_space(notes), allocator)
    result.url = strings.clone(asset.browser_download_url, allocator)
    result.sums_url = strings.clone(sums.browser_download_url, allocator)
    result.asset = strings.clone(asset_name, allocator)
    result.size = asset.size
    result.installable, _ = installable()
    return result
}

// Reads the latest release of `url`, a releases API address. Up_To_Date is a
// repository that has published nothing yet.
fetch_latest_release :: proc(tools: Tools, url: string, agent: string, cancel: ^bool = nil, allocator := context.allocator) -> (release: Api_Release, status: Status) {
    scratch, has_scratch := scratch_dir(context.temp_allocator)
    if !has_scratch {
        return {}, .Not_Installable
    }
    api_path, join_err := filepath.join({scratch, fmt.tprintf(API_FILE_FORMAT, sync.current_thread_id())}, context.temp_allocator)
    if join_err != nil {
        log.errorf("Could not build the api scratch path: %v", join_err)
        return {}, .Not_Installable
    }
    defer if err := os.remove(api_path); err != nil && os.exists(api_path) {
        log.warnf("Could not remove %q: %v", api_path, err)
    }

    code, fetched := fetch_text(tools, url, api_path, agent, cancel)
    if cancelled(cancel) {
        return {}, .Cancelled
    }
    if !fetched {
        return {}, .No_Network
    }
    switch {
    case code == 403 || code == 429:
        return {}, .Rate_Limited
    case code == 404:
        // /latest answers 404 for a repository that has published nothing yet,
        // which is not an error and not an update either.
        return {}, .Up_To_Date
    case code != 200:
        log.warnf("The releases API answered %d", code)
        return {}, .Bad_Response
    }

    data, read_err := os.read_entire_file(api_path, context.temp_allocator)
    if read_err != nil {
        return {}, .Bad_Response
    }
    decoded: bool
    release, decoded = release_decode(data, allocator)
    if !decoded {
        return {}, .Bad_Response
    }
    if release.draft || release.prerelease {
        return {}, .Draft_Release
    }
    return release, .Ok
}

// Frees what a check owns.
check_result_destroy :: proc(result: ^Check_Result, allocator := context.allocator) {
    delete(result.version, allocator)
    delete(result.notes, allocator)
    delete(result.url, allocator)
    delete(result.sums_url, allocator)
    delete(result.asset, allocator)
    result^ = {}
}

// Where the API reply is written. The system temporary directory first: a check
// is not an install, and it has no business leaving a file in the folder the
// user unpacked. The install directory only stands in when there is no
// temporary one, which is also the case where the install would fail anyway.
@(private = "file")
scratch_dir :: proc(allocator := context.allocator) -> (dir: string, ok: bool) {
    if temp, err := os.temp_directory(allocator); err == nil {
        return temp, true
    }
    if !install_dir_writable() {
        return "", false
    }
    return strings.clone(".", allocator), true
}
