package update

// The shell-outs. Every call runs one external command with a timeout, so it
// belongs on a worker thread — the same rule the shell package states.

import "core:log"
import "core:os"
import "core:strings"
import "core:sync"

import "../shell"

// How many slices one download may take before it is called failed. A slice
// stops after SLICE_SECONDS or a stall, so this is the retry budget.
@(private = "file")
MAX_SLICES :: 30

// The tools this machine has, best first.
Tools :: struct {
    downloader: Downloader,
    extractor:  Extractor,
}

// Probes for a downloader and an extractor for `archive`. Windows keeps the
// PowerShell fallbacks, since curl and bsdtar are only there from Windows 10
// 1803; elsewhere curl and tar are the only candidates.
tools_detect :: proc(archive: Archive) -> (tools: Tools, ok: bool) {
    downloaders := [?]Downloader{.Curl, .Powershell}
    found_downloader := false
    for candidate in downloaders {
        when ODIN_OS != .Windows {
            if candidate == .Powershell {
                continue
            }
        }
        if probe(probe_download_command(candidate)) {
            tools.downloader = candidate
            found_downloader = true
            break
        }
    }
    if !found_downloader {
        return {}, false
    }

    for candidate in archive_extractors(archive) {
        when ODIN_OS != .Windows {
            if candidate == .Expand_Archive {
                continue
            }
        }
        if probe(probe_extract_command(candidate)) {
            tools.extractor = candidate
            return tools, true
        }
    }
    return {}, false
}

// Whether a tool is there. `run_status` owns the output it returns, and a probe
// wants none of it.
@(private = "file")
probe :: proc(command: string) -> bool {
    output, code, ok := shell.run_status(command, "", PROBE_TIMEOUT)
    defer delete(output)
    if !ok || code != 0 {
        log.debugf("Update tool probe %q stopped with %d: %s", command, code, strings.trim_space(output))
        return false
    }
    return true
}

// Reads a URL into `dest` and answers the HTTP status code. Used for the API
// reply and for SHA256SUMS, both small enough for one request.
fetch_text :: proc(tools: Tools, url: string, dest: string, agent: string) -> (code: int, ok: bool) {
    command := api_command(tools.downloader, url, dest, agent, context.temp_allocator)
    output, _, run_ok := shell.run_status(command, "", API_TIMEOUT)
    defer delete(output)
    if !run_ok {
        return 0, false
    }
    return http_code(output), true
}

// Downloads a file one slice at a time, resuming where the last slice stopped.
// The loop is what keeps a shutdown from waiting out a whole download: `cancel`
// is read between slices, so the worst case is one slice.
fetch_file :: proc(tools: Tools, url: string, dest: string, agent: string, cancel: ^bool) -> bool {
    command := download_command(tools.downloader, url, dest, agent, context.temp_allocator)
    for slice in 0 ..< MAX_SLICES {
        if cancel != nil && sync.atomic_load(cancel) {
            return false
        }
        output, code, run_ok := shell.run_status(command, "", SLICE_TIMEOUT)
        defer delete(output)
        if run_ok && code == 0 {
            return true
        }
        if !downloader_resumes(tools.downloader) {
            log.warnf("Update download failed: %s", strings.trim_space(output))
            return false
        }
        // curl exits 33 when the server refuses a range, which leaves the
        // partial file unusable for a resume.
        if code == 33 {
            if err := os.remove(dest); err != nil {
                log.warnf("Could not remove the partial download %q: %v", dest, err)
                return false
            }
        }
        log.debugf("Update download slice %d stopped with %d, resuming", slice, code)
    }
    return false
}

// Unpacks `archive` into the existing directory `dir`.
extract_archive :: proc(tools: Tools, archive: string, dir: string) -> bool {
    command := extract_command(tools.extractor, archive, dir, context.temp_allocator)
    output, code, ok := shell.run_status(command, "", EXTRACT_TIMEOUT)
    defer delete(output)
    if !ok || code != 0 {
        log.warnf("Update archive did not unpack: %s", strings.trim_space(output))
        return false
    }
    return true
}
