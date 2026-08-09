package thor

import "core:strings"
import "core:testing"

import "../lang"
import "../textedit"

// Document sync between the open buffers and a backend that mirrors them.
// Headless: the Manager is real, the backend only records. Run from the
// repository root: odin test thor

// Records every notification the seam delivers, in order.
@(private = "file")
Sync_Probe :: struct {
    events:    [dynamic]lang.Doc_Event,
    sources:   [dynamic]string, // owned; the text each event carried
    revisions: [dynamic]u64,
}

@(private = "file")
sync_handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".sync"
}

@(private = "file")
sync_resolve :: proc(data: rawptr, req: ^lang.Request, res: ^lang.Result) {}

@(private = "file")
sync_notify :: proc(data: rawptr, event: lang.Doc_Event, path, ext, source: string, revision: u64) {
    p := cast(^Sync_Probe)data
    append(&p.events, event)
    // `source` is borrowed for the call only, exactly as a real backend sees it.
    append(&p.sources, strings.clone(source))
    append(&p.revisions, revision)
}

@(private = "file")
sync_destroy :: proc(data: rawptr) {
    p := cast(^Sync_Probe)data
    for text in p.sources {
        delete(text)
    }
    delete(p.events)
    delete(p.sources)
    delete(p.revisions)
}

@(private = "file")
sync_backend :: proc(p: ^Sync_Probe) -> lang.Backend {
    return lang.Backend {
        data = p,
        name = "sync-probe",
        handles = sync_handles,
        resolve = sync_resolve,
        destroy = sync_destroy,
        notify = sync_notify,
    }
}

// An open, loaded buffer with no I/O behind it: the sync pass reads only `path`,
// `name`, `loaded` and the textedit state.
@(private = "file")
sync_file :: proc(thor: ^Thor, path, text: string) -> ^Open_File {
    file := new(Open_File)
    file.path = strings.clone(path)
    file.name = file.path // bare names here, so the base name is the whole path
    textedit.init(&file.state)
    textedit.set_text(&file.state, text)
    file.loaded = true
    append(&thor.open_files, file)
    return file
}

@(test)
test_lang_sync_one_change_per_edit :: proc(t: ^testing.T) {
    probe := Sync_Probe{}
    thor := new(Thor)
    defer free(thor)
    thor.open_files = make([dynamic]^Open_File)
    lang.manager_init(&thor.lang_manager)
    lang.manager_register(&thor.lang_manager, sync_backend(&probe))
    defer {
        for file in thor.open_files {
            thor_free_open_file(file)
        }
        delete(thor.open_files)
        lang.manager_destroy(&thor.lang_manager)
    }

    file := sync_file(thor, "probe.sync", "one\n")

    // Nothing before the mirror starts: a buffer the host never opened must not
    // reach the backend as a change.
    thor_sync_lang_documents(thor)
    testing.expect_value(t, len(probe.events), 0)

    thor_lang_notify(thor, file, .Opened)
    testing.expect_value(t, len(probe.events), 1)
    testing.expect_value(t, probe.events[0], lang.Doc_Event.Opened)
    testing.expect_value(t, probe.sources[0], "one\n")

    // An unchanged buffer costs nothing, however often the pass runs.
    thor_sync_lang_documents(thor)
    thor_sync_lang_documents(thor)
    testing.expect_value(t, len(probe.events), 1)

    // Two edits in one frame are one notification, carrying the last text.
    textedit.insert_text(&file.state, "a")
    textedit.insert_text(&file.state, "b")
    thor_sync_lang_documents(thor)
    testing.expect_value(t, len(probe.events), 2)
    testing.expect_value(t, probe.events[1], lang.Doc_Event.Changed)
    testing.expect_value(t, probe.sources[1], textedit.text(&file.state))
    testing.expect_value(t, probe.revisions[1], file.state.revision)

    thor_sync_lang_documents(thor)
    testing.expect_value(t, len(probe.events), 2)
}

@(test)
test_lang_sync_ignores_other_files :: proc(t: ^testing.T) {
    probe := Sync_Probe{}
    thor := new(Thor)
    defer free(thor)
    thor.open_files = make([dynamic]^Open_File)
    lang.manager_init(&thor.lang_manager)
    lang.manager_register(&thor.lang_manager, sync_backend(&probe))
    defer {
        for file in thor.open_files {
            thor_free_open_file(file)
        }
        delete(thor.open_files)
        lang.manager_destroy(&thor.lang_manager)
    }

    claimed := sync_file(thor, "claimed.sync", "one\n")
    other := sync_file(thor, "other.txt", "two\n")
    // A buffer that is still loading has no text to send.
    loading := sync_file(thor, "loading.sync", "")
    loading.loaded = false

    thor_lang_notify(thor, claimed, .Opened)
    thor_lang_notify(thor, other, .Opened)
    thor_lang_notify(thor, loading, .Opened)
    testing.expect_value(t, len(probe.events), 1)
    testing.expect(t, !loading.lang_open, "an unloaded buffer must not start the mirror")

    textedit.insert_text(&claimed.state, "x")
    textedit.insert_text(&other.state, "x")
    thor_sync_lang_documents(thor)
    testing.expect_value(t, len(probe.events), 2)
    testing.expect_value(t, probe.events[1], lang.Doc_Event.Changed)
}

@(test)
test_lang_sync_save_flushes_change :: proc(t: ^testing.T) {
    probe := Sync_Probe{}
    thor := new(Thor)
    defer free(thor)
    thor.open_files = make([dynamic]^Open_File)
    lang.manager_init(&thor.lang_manager)
    lang.manager_register(&thor.lang_manager, sync_backend(&probe))
    defer {
        for file in thor.open_files {
            thor_free_open_file(file)
        }
        delete(thor.open_files)
        lang.manager_destroy(&thor.lang_manager)
    }

    file := sync_file(thor, "probe.sync", "one\n")
    thor_lang_notify(thor, file, .Opened)

    // A save between the edit and the frame's sync pass sends the text first, so
    // the backend never saves a document it has an older text for.
    textedit.insert_text(&file.state, "x")
    thor_lang_notify(thor, file, .Saved)
    testing.expect_value(t, len(probe.events), 3)
    testing.expect_value(t, probe.events[1], lang.Doc_Event.Changed)
    testing.expect_value(t, probe.events[2], lang.Doc_Event.Saved)
    thor_sync_lang_documents(thor)
    testing.expect_value(t, len(probe.events), 3)

    // Close ends the mirror; a second close says nothing.
    thor_lang_notify(thor, file, .Closed)
    thor_lang_notify(thor, file, .Closed)
    testing.expect_value(t, len(probe.events), 4)
    testing.expect_value(t, probe.events[3], lang.Doc_Event.Closed)
    testing.expect(t, !file.lang_open, "close must end the mirror")
}
