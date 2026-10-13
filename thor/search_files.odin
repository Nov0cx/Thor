// Find in files: a worker scans the workspace for the query and the rows land in
// the palette's rich picker. The scan itself is `search`; the find bar's
// case, word and regex toggles apply here too.
package thor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

import "../lang"
import "../search"
import "../shell"
import "../textedit"

// Rows the picker takes; a scan stops when it has this many.
@(private = "file")
FILE_SEARCH_HIT_MAX :: 1000
// A larger file is not read.
@(private = "file")
FILE_SEARCH_SIZE_MAX :: 4 * 1024 * 1024
@(private = "file")
FILE_SEARCH_FILE_MAX :: 20000
@(private = "file")
FILE_SEARCH_PREVIEW_MAX :: 160
// A query shorter than this matches too much to be of use.
@(private = "file")
FILE_SEARCH_QUERY_MIN :: 2
// Wait after the last key before a scan starts.
@(private = "file")
FILE_SEARCH_DELAY :: 200 * time.Millisecond

File_Search_Hit :: struct {
    path:    string, // owned
    offset:  int,    // byte offset of the match, CRLF counted as LF
    line:    int,    // 1-based
    preview: string, // owned; the line of the match, cut to a row
}

File_Search_Job :: struct {
    owner:       ^Thor,
    allocator:   runtime.Allocator,
    worker:      ^thread.Thread,
    root:        string, // owned
    query:       string, // owned
    options:     search.Options,
    // The scan this job is. A newer serial on the owner stops it.
    serial:      u64,
    hits:        [dynamic]File_Search_Hit, // owned, with the strings in it
    files:       int,
    capped:      bool,
    bad_pattern: bool,
}

// Opens the picker. The scan starts when the query is long enough.
thor_find_in_files :: proc(thor: ^Thor) {
    if thor.workspace_dir == "" {
        thor_flash_status(thor, "Open a folder to search in files")
        return
    }
    thor_palette_pick_rich_loading(thor, "Find in files...", thor_pick_symbol, thor, thor_file_search_query_changed, thor)
    thor_palette_set_unfiltered(thor)
    thor_palette_pick_rich_set(thor, {}, "Type to search the files of the folder")

    // A selection is the first query, as in the find bar.
    if editor := thor_active_editor(thor); editor != nil && editor.state != nil {
        lo, hi := textedit.selection_range(textedit.primary_cursor(editor.state))
        text := textedit.text(editor.state)[lo:hi]
        if len(text) >= FILE_SEARCH_QUERY_MIN && !strings.contains(text, "\n") {
            thor_palette_set_query(thor, strings.clone(text, context.temp_allocator))
        }
    }
}

thor_cmd_find_in_files :: proc(data: rawptr) {
    thor_find_in_files(cast(^Thor) data)
}

// The palette's query hook: the scan starts when the typing rests.
@(private = "file")
thor_file_search_query_changed :: proc(data: rawptr, query: string) {
    thor := cast(^Thor) data
    // The running scan answers an old query.
    sync.atomic_add(&thor.file_search_serial, 1)
    delete(thor.file_search_query)
    thor.file_search_query = strings.clone(query)
    thor.file_search_due = time.tick_now()
    thor.file_search_waiting = len(query) >= FILE_SEARCH_QUERY_MIN
    if thor.file_search_waiting {
        thor_palette_set_loading(thor)
    } else {
        thor_palette_set_loading(thor)
        thor_palette_pick_rich_set(thor, {}, "Type to search the files of the folder")
    }
}

// True while the open picker is the find-in-files one and waits for rows.
@(private = "file")
file_search_owns_palette :: proc(thor: ^Thor) -> bool {
    return thor_palette_pick_loading(thor) && thor.palette.on_query_changed == thor_file_search_query_changed
}

// Starts the scan a rested query waits for. One scan runs at a time: a waiting
// query starts when the scan before it lands.
thor_file_search_tick :: proc(thor: ^Thor) {
    if !thor.file_search_waiting || thor.file_search_inflight {
        return
    }
    if time.tick_since(thor.file_search_due) < FILE_SEARCH_DELAY {
        return
    }
    thor.file_search_waiting = false
    if !file_search_owns_palette(thor) {
        return
    }

    job := new(File_Search_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.root = strings.clone(thor.workspace_dir)
    job.query = strings.clone(thor.file_search_query)
    job.options = thor.find.options
    job.serial = sync.atomic_load(&thor.file_search_serial)

    thor.file_search_inflight = true
    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, file_search_worker)
}

@(private = "file")
file_search_worker :: proc(job: ^File_Search_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    job.hits = make([dynamic]File_Search_Hit, job.allocator)
    files := file_search_list(job.root)
    matches := make([dynamic]search.Match, context.temp_allocator)

    for path in files {
        if sync.atomic_load(&job.owner.file_search_serial) != job.serial || job.capped || job.bad_pattern {
            break
        }
        text, ok := file_search_read(path)
        if !ok {
            continue
        }
        job.files += 1
        clear(&matches)
        if !search.scan(text, job.query, job.options, &matches) {
            job.bad_pattern = true
            break
        }

        line, counted := 1, 0
        for match in matches {
            line += strings.count(text[counted:match.start], "\n")
            counted = match.start
            append(&job.hits, File_Search_Hit {
                path    = strings.clone(path, job.allocator),
                offset  = match.start,
                line    = line,
                preview = file_search_preview(text, match.start, job.allocator),
            })
            if len(job.hits) >= FILE_SEARCH_HIT_MAX {
                job.capped = true
                break
            }
        }
    }

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_file_searches, job)
    sync.unlock(&job.owner.io_mutex)
}

// The files to scan, as absolute paths in the temp allocator. A git work tree
// gives its tracked and untracked files, so what .gitignore names is left out;
// any other folder is walked.
@(private = "file")
file_search_list :: proc(root: string) -> []string {
    output, status, _ := shell.run_status("git ls-files -z --cached --others --exclude-standard", root)
    defer delete(output)
    if status == 0 && len(output) > 0 {
        files := make([dynamic]string, context.temp_allocator)
        rest := output
        for len(rest) > 0 && len(files) < FILE_SEARCH_FILE_MAX {
            end := strings.index_byte(rest, 0)
            rel := end < 0 ? rest : rest[:end]
            rest = end < 0 ? "" : rest[end + 1:]
            if rel != "" {
                append(&files, strings.concatenate({root, "/", rel}, context.temp_allocator))
            }
        }
        return files[:]
    }
    walked := thor_walk_workspace_files(root, context.temp_allocator, FILE_SEARCH_FILE_MAX)
    return walked[:]
}

// The text of one file with CRLF as LF, in the temp allocator. False for a file
// that is missing, too large or binary.
@(private = "file")
file_search_read :: proc(path: string) -> (string, bool) {
    info, stat_err := os.stat(path, context.temp_allocator)
    if stat_err != nil || info.type == .Directory || info.size > FILE_SEARCH_SIZE_MAX {
        return "", false
    }
    text, ok := lang.source_read(path, context.temp_allocator)
    if !ok {
        return "", false
    }
    if strings.index_byte(text[:min(len(text), BINARY_PROBE_BYTES)], 0) >= 0 {
        return "", false
    }
    return text, true
}

// The line that holds `offset`, without its indent and cut to a row.
@(private = "file")
file_search_preview :: proc(text: string, offset: int, allocator: runtime.Allocator) -> string {
    start := offset
    for start > 0 && text[start - 1] != '\n' {
        start -= 1
    }
    end := offset
    for end < len(text) && text[end] != '\n' {
        end += 1
    }
    line := strings.trim_left(text[start:end], " \t")
    if len(line) > FILE_SEARCH_PREVIEW_MAX {
        cut := FILE_SEARCH_PREVIEW_MAX
        for cut > 0 && !utf8.rune_start(line[cut]) {
            cut -= 1
        }
        line = line[:cut]
    }
    return strings.clone(line, allocator)
}

// Drains a finished scan (called from thor_process_io). A scan a newer query
// overtook is dropped, and the waiting query starts on the next tick.
thor_apply_file_search :: proc(thor: ^Thor, job: ^File_Search_Job) {
    thread.join(job.worker)
    thread.destroy(job.worker)
    thor.file_search_inflight = false
    thor.inflight_jobs -= 1
    defer file_search_job_destroy(job)

    if job.serial != sync.atomic_load(&thor.file_search_serial) || !file_search_owns_palette(thor) {
        return
    }
    if job.bad_pattern {
        thor_palette_pick_rich_set(thor, {}, "The pattern is not a valid regular expression")
        return
    }
    if len(job.hits) == 0 {
        thor_palette_pick_rich_set(thor, {}, fmt.tprintf("No match in %d files", job.files))
        return
    }

    thor_clear_doc_symbols(thor)
    items := make([dynamic]Pick_Item, 0, len(job.hits), context.temp_allocator)
    for hit in job.hits {
        append(&thor.doc_symbols, Doc_Symbol {path = strings.clone(hit.path), offset = hit.offset})
        rel := strings.trim_left(strings.trim_prefix(hit.path, thor.workspace_dir), "/\\")
        slash, _ := strings.replace_all(rel, "\\", "/", context.temp_allocator)
        append(&items, Pick_Item {
            text   = hit.preview,
            color  = thor.theme.primary_text_color,
            detail = fmt.tprintf("%s:%d", slash, hit.line),
        })
    }
    thor_palette_pick_rich_set(thor, items[:])
    if job.capped {
        thor_flash_status(thor, fmt.tprintf("Showing the first %d matches", FILE_SEARCH_HIT_MAX))
    }
}

@(private = "file")
file_search_job_destroy :: proc(job: ^File_Search_Job) {
    for hit in job.hits {
        delete(hit.path, job.allocator)
        delete(hit.preview, job.allocator)
    }
    delete(job.hits)
    delete(job.root)
    delete(job.query)
    free(job)
}

// Frees what find in files holds on the Thor. The jobs are drained before.
thor_file_search_destroy :: proc(thor: ^Thor) {
    delete(thor.file_search_query)
    thor.file_search_query = ""
}
