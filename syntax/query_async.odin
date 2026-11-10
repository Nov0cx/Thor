package syntax

import "core:strings"
import "core:sync"
import "core:thread"

import "../prof"
import ts "../vendor/odin-tree-sitter"

// A highlights query that compiles on a worker thread. A large query takes over 100 ms to compile.
@(private)
Query_Job :: struct {
    lang:    ts.Language,
    lang_id: string, // owned
    source:  string, // owned
    query:   ts.Query, // owned until query_poll installs it
    done:    bool, // set by the worker
    worker:  ^thread.Thread,
}

// True when the highlights query of `lang_id` is compiled, so highlight_range does not compile it on the
// calling thread. Else starts the compile on a worker thread and returns false; query_poll installs the
// result. An unknown language, or a query that failed on the worker, returns true: the synchronous path
// then answers as before.
query_ready :: proc(h: ^Highlighter, lang_id: string) -> bool {
    if lang_id in h.resolved {
        return true
    }
    entry, known := h.languages[lang_id]
    if !known || lang_id in h.async_failed {
        return true
    }
    for job in h.compiling {
        if job.lang_id == lang_id {
            return false
        }
    }
    source := highlights_source(h, lang_id, entry)
    if (Query_Key{lang_id = lang_id, source = source}) in h.queries {
        return true
    }

    job := new(Query_Job)
    job.lang = entry.lang
    job.lang_id = strings.clone(lang_id)
    job.source = strings.clone(source)
    job.worker = thread.create_and_start_with_poly_data(job, query_worker)
    if job.worker == nil {
        // No thread: the caller compiles on its own thread.
        delete(job.lang_id)
        delete(job.source)
        free(job)
        return true
    }
    append(&h.compiling, job)
    return false
}

// Installs the queries that finished compiling. True when one was installed, so the caller highlights again.
query_poll :: proc(h: ^Highlighter) -> (installed: bool) {
    for i := len(h.compiling) - 1; i >= 0; i -= 1 {
        job := h.compiling[i]
        if !sync.atomic_load(&job.done) {
            continue
        }
        unordered_remove(&h.compiling, i)
        thread.join(job.worker)
        thread.destroy(job.worker)
        if query_install(h, job) {
            installed = true
        }
        delete(job.lang_id)
        delete(job.source)
        free(job)
    }
    return installed
}

// Waits for every compile and frees it. Called by highlighter_destroy.
@(private)
query_jobs_destroy :: proc(h: ^Highlighter) {
    for job in h.compiling {
        thread.join(job.worker)
        thread.destroy(job.worker)
        if job.query != nil {
            ts.query_delete(job.query)
        }
        delete(job.lang_id)
        delete(job.source)
        free(job)
    }
    delete(h.compiling)
    for id in h.async_failed {
        delete(id)
    }
    delete(h.async_failed)
}

// The highlights source in force for `lang_id`: the override of a plugin, else the compiled-in query.
@(private)
highlights_source :: proc(h: ^Highlighter, lang_id: string, entry: Language_Entry) -> string {
    if override, ok := h.overrides[lang_id]; ok {
        return override
    }
    return entry.highlights
}

@(private = "file")
query_worker :: proc(job: ^Query_Job) {
    prof.thread_scope("query compile")
    query, _, err := ts.query_new(job.lang, job.source)
    if err == .None {
        job.query = query
    }
    sync.atomic_store(&job.done, true)
}

// Puts a finished query into the caches. A query whose source an override replaced meanwhile is dropped.
@(private = "file")
query_install :: proc(h: ^Highlighter, job: ^Query_Job) -> bool {
    entry, known := h.languages[job.lang_id]
    current := known && highlights_source(h, job.lang_id, entry) == job.source
    if job.query == nil {
        if current && job.lang_id not_in h.async_failed {
            h.async_failed[strings.clone(job.lang_id)] = true
        }
        return current
    }
    key := Query_Key{lang_id = job.lang_id, source = job.source}
    if !current || job.lang_id in h.resolved || key in h.queries {
        ts.query_delete(job.query)
        return false
    }
    h.queries[Query_Key{lang_id = strings.clone(job.lang_id), source = strings.clone(job.source)}] = job.query
    h.resolved[strings.clone(job.lang_id)] = job.query
    return true
}
