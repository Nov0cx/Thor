package syntax

import "core:strings"
import "core:sync"
import "core:thread"

import "../prof"
import "../treecache"
import ts "../vendor/odin-tree-sitter"

// The smallest buffer whose first parse runs on a worker thread. A smaller one parses in a few milliseconds.
ASYNC_PARSE_MIN :: 32 << 10

// The first parse of one buffer, into the shared tree cache, on a worker thread with its own parser.
@(private)
Parse_Job :: struct {
    h:       ^Highlighter,
    lang:    ts.Language,
    lang_id: string, // owned
    path:    string, // owned
    source:  string, // owned
    done:    bool,   // set by the worker
    worker:  ^thread.Thread,
}

// True when highlight_range and fold_ranges can answer for the buffer at `path` without a whole parse on
// the calling thread. Else starts the parse on a worker thread and returns false; a later call returns
// true. A buffer with no path, an unknown language and a small buffer are always ready.
tree_ready :: proc(h: ^Highlighter, path, source, lang_id: string) -> bool {
    parse_poll(h)
    if path == "" || len(source) < ASYNC_PARSE_MIN {
        return true
    }
    entry, known := h.languages[lang_id]
    if !known {
        return true
    }
    for job in h.parsing {
        if job.path == path {
            return false
        }
    }
    if treecache.resident(&h.trees, path, lang_id) {
        return true
    }

    job := new(Parse_Job)
    job.h = h
    job.lang = entry.lang
    job.lang_id = strings.clone(lang_id)
    job.path = strings.clone(path)
    job.source = strings.clone(source)
    job.worker = thread.create_and_start_with_poly_data(job, parse_worker)
    if job.worker == nil {
        // No thread: the caller parses on its own thread.
        parse_job_free(job)
        return true
    }
    append(&h.parsing, job)
    return false
}

// Frees the finished parses. Their trees stay in the tree cache.
@(private)
parse_poll :: proc(h: ^Highlighter) {
    for i := len(h.parsing) - 1; i >= 0; i -= 1 {
        job := h.parsing[i]
        if !sync.atomic_load(&job.done) {
            continue
        }
        unordered_remove(&h.parsing, i)
        thread.join(job.worker)
        thread.destroy(job.worker)
        parse_job_free(job)
    }
}

// Waits for every parse and frees it. Called by highlighter_destroy before the tree cache goes.
@(private)
parse_jobs_destroy :: proc(h: ^Highlighter) {
    for job in h.parsing {
        thread.join(job.worker)
        thread.destroy(job.worker)
        parse_job_free(job)
    }
    delete(h.parsing)
}

@(private = "file")
parse_job_free :: proc(job: ^Parse_Job) {
    delete(job.lang_id)
    delete(job.path)
    delete(job.source)
    free(job)
}

@(private = "file")
parse_worker :: proc(job: ^Parse_Job) {
    prof.thread_scope("first parse")
    parser := ts.parser_new()
    if parser != nil {
        if ts.parser_set_language(parser, job.lang) {
            if tree := treecache.for_source(&job.h.trees, parser, job.path, job.lang_id, job.source); tree != nil {
                ts.tree_delete(tree)
            }
        }
        ts.parser_delete(parser)
    }
    sync.atomic_store(&job.done, true)
}
