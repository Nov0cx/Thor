package thor

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

import "../lang"
import "../lang/lsp"
import "../lang/odin"
import "../setting"
import "../textedit"
import "../widgets"

// How long a transient statusline notice stays up.
STATUS_MESSAGE_SECS :: 3.0

// How long the analyzer must stay busy before the statusline says so.
LANG_BUSY_DELAY_SECS :: 0.25

// Reads the analyzer's in-flight work for the statusline indicator. Called once
// per frame, after the results of the frame are reaped.
thor_poll_lang_busy :: proc(thor: ^Thor) {
    thor_lang_busy_update(thor, lang.manager_busy_kinds(&thor.lang_manager), rl.GetTime())
}

// Folds this frame's in-flight kinds into the indicator state. The flag only
// goes up once the manager has been busy without a break for
// LANG_BUSY_DELAY_SECS: the requests that fire while typing (completion,
// semantic tokens) are answered in a few frames, and a spinner flashing on
// every keystroke says nothing.
thor_lang_busy_update :: proc(thor: ^Thor, kinds: bit_set[lang.Request_Kind], now: f64) {
    if kinds == {} {
        thor.lang_busy_kinds = {}
        thor.lang_busy_shown = false
        return
    }
    if thor.lang_busy_kinds == {} {
        thor.lang_busy_since = now
    }
    thor.lang_busy_kinds = kinds
    thor.lang_busy_shown = now - thor.lang_busy_since >= LANG_BUSY_DELAY_SECS
}

// Labels the indicator after the most user-visible kind in flight, so a
// workspace scan reads as one even when the passes that run while typing are
// alongside it.
thor_lang_busy_label :: proc(kinds: bit_set[lang.Request_Kind]) -> string {
    switch {
    case .Rename in kinds:
        return "Renaming..."
    case .References in kinds:
        return "Finding references..."
    case .Workspace_Symbols in kinds:
        return "Scanning workspace..."
    case .Definition in kinds, .Document_Symbols in kinds, .Hover in kinds, .Package_Doc in kinds:
        return "Resolving..."
    case .Code_Actions in kinds:
        return "Looking for fixes..."
    case .Format in kinds, .Format_Range in kinds:
        return "Formatting..."
    case .Diagnostics in kinds:
        return "Checking..."
    }
    return "Analyzing..."
}

// Pushes the language-intelligence settings onto the manager: the master switch
// and the per-feature gate, which the seam then enforces on every dispatch.
// Called from thor_apply_settings, so startup and every reload take the same
// path. A feature that goes off has its in-flight work cancelled by the manager;
// what it already put on screen is dropped here.
thor_apply_language_settings :: proc(thor: ^Thor) {
    enabled := setting.language_enabled(&thor.config)
    features := setting.language_features(&thor.config)
    before := thor_language_gate(thor)
    lang.manager_set_enabled(&thor.lang_manager, enabled)
    lang.manager_set_features(&thor.lang_manager, features)
    odin.engine_set_enabled(thor.odin_engine, setting.backend_enabled(&thor.config, ODIN_BACKEND_ID))
    odin.engine_set_features(thor.odin_engine, setting.backend_features(&thor.config, ODIN_BACKEND_ID))
    for id in lsp.client_server_ids(thor.lsp_client) {
        lsp.client_set_server_enabled(thor.lsp_client, id, setting.backend_enabled(&thor.config, id))
        lsp.client_set_server_features(thor.lsp_client, id, setting.backend_features(&thor.config, id))
    }
    after := thor_language_gate(thor)
    if after == before {
        return
    }

    if .Diagnostics not_in after {
        for file in thor.open_files {
            thor_clear_file_diagnostics(file)
            file.diagnostics_revision = 0
        }
    }
    if .Semantic_Tokens not_in after {
        for file in thor.open_files {
            clear(&file.semantic)
            file.semantic_ready = false
            file.highlighted = false // re-merged by the per-frame highlight pass, now without the overlay
        }
    }
    // The editors are told once per bind whether semantic completion exists, so
    // a change to that answer only reaches them through a re-bind.
    for pane in 0 ..< len(thor.pane_file) {
        thor_bind_pane(thor, pane, keep_view = true)
    }
}

// The kinds the manager currently lets through, master switch included.
@(private = "file")
thor_language_gate :: proc(thor: ^Thor) -> bit_set[lang.Request_Kind] {
    if !lang.manager_enabled(&thor.lang_manager) {
        return {}
    }
    return lang.manager_features(&thor.lang_manager)
}

// Rebuilds the LSP client against the new workspace root on a folder switch.
// settings/lsp.json + .thor/lsp.json are read once, in lsp.client_create, so
// a stale Client would keep talking to the old root's servers (and the old
// .thor/lsp.json overlay) otherwise. The in-client Odin engine needs no
// rebuild — it re-validates its own config file per request through
// config_ensure's workspace/stat check — so only the LSP side is torn down.
thor_reload_lang :: proc(thor: ^Thor) {
    // No worker may be inside resolve on the old Client when it is destroyed
    // — the same guarantee manager_destroy gives every backend at shutdown.
    lang.manager_cancel_all(&thor.lang_manager)
    for lang.manager_busy(&thor.lang_manager) {
        lang.manager_dispatch(&thor.lang_manager, nil, nil)
        time.sleep(time.Millisecond)
    }
    lang.manager_dispatch(&thor.lang_manager, nil, nil)

    if old, found := lang.manager_backend_named(&thor.lang_manager, "lsp"); found && old.destroy != nil {
        old.destroy(old.data)
    }

    thor.lsp_client = lsp.client_create(thor.workspace_dir)
    lsp_backend := lsp.client_backend(thor.lsp_client)
    odin_backend := odin.engine_backend(thor.odin_engine)
    // Registration order is precedence (lang.manager_register's contract) —
    // re-decided here exactly as thor_init decides it the first time, since
    // the new workspace's .thor/lsp.json can flip "override" for .odin.
    if lsp.client_overrides(thor.lsp_client, ".odin") {
        lang.manager_set_backends(&thor.lang_manager, lsp_backend, odin_backend)
    } else {
        lang.manager_set_backends(&thor.lang_manager, odin_backend, lsp_backend)
    }
    // The freshly built Client's servers all start admin_enabled == true
    // (server_create's default), so the settings-driven per-backend toggle has
    // to be re-pushed now; thor_reload_settings already pushed it once earlier
    // in the same workspace-switch sequence, but against the Client this just
    // replaced.
    thor_apply_language_settings(thor)
}

// Document sync: what a backend that mirrors the editor's buffers (a subprocess
// LSP client) needs to stay in step. The in-client engine defines `notify` only
// for a save, and every other backend that defines nothing sees none of this.
//
// The mirror runs on `Open_File.lang_open`, which the host owns: `.Opened` needs
// loaded text, `.Changed` and `.Saved` need a mirror already, `.Closed` ends it.
// A save sends the pending text first, so the server saves what it last saw.
thor_lang_notify :: proc(thor: ^Thor, file: ^Open_File, event: lang.Doc_Event) {
    ext := thor_file_extension(file.name)
    switch event {
    case .Opened:
        if file.lang_open || !file.loaded {
            return
        }
        file.lang_open = true
        file.lang_revision = file.state.revision
        // textedit.text borrows the buffer snapshot; manager_notify copies what
        // it keeps before returning, so the slice never outlives this call.
        lang.manager_notify(
            &thor.lang_manager,
            .Opened,
            file.path,
            ext,
            textedit.text(&file.state),
            file.state.revision,
        )
    case .Changed:
        if !file.lang_open || file.lang_revision == file.state.revision {
            return
        }
        file.lang_revision = file.state.revision
        lang.manager_notify(
            &thor.lang_manager,
            .Changed,
            file.path,
            ext,
            textedit.text(&file.state),
            file.state.revision,
        )
    case .Saved:
        if !file.lang_open {
            return
        }
        thor_lang_notify(thor, file, .Changed)
        lang.manager_notify(&thor.lang_manager, .Saved, file.path, ext, "", file.state.revision)
    case .Closed:
        if !file.lang_open {
            return
        }
        file.lang_open = false
        lang.manager_notify(&thor.lang_manager, .Closed, file.path, ext, "", file.state.revision)
    }
}

// One pass over the open buffers, once per frame: at most one change
// notification per file, so a burst of keystrokes in one frame costs one.
thor_sync_lang_documents :: proc(thor: ^Thor) {
    for file in thor.open_files {
        thor_lang_notify(thor, file, .Changed)
    }
}

// Go-to-definition and (later) hover wiring between the editor and the language
// intelligence manager. Requests are dispatched from the caret (Alt+Enter) or a
// Ctrl+Click; results arrive asynchronously and are applied in thor_on_lang_result.
//
// Every dispatch here goes through manager_request_latest (or, for the triggers
// that fire while typing, manager_request_debounced): each kind has exactly one
// consumer slot on Thor (a `*_request_id`), so an older request of the same kind
// can never be wanted again. Cancelling it stops the backend mid-scan instead of
// letting it finish work the id check would throw away — the difference between
// a wasted workspace parse per keystroke and none. Debouncing goes one further
// for completion and auto signature help: a burst of keystrokes queues a single
// request rather than one thread and buffer clone per key.

// Alt+Enter: resolve the symbol under the caret in the active file.
thor_goto_definition :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    thor_dispatch_goto(thor, file, textedit.primary_cursor(&file.state).caret)
}

// Ctrl+Click: the editor hands back the buffer it was clicked in and the byte
// offset under the cursor. Match the buffer to its open file and dispatch.
thor_editor_goto_definition :: proc(data: rawptr, state: ^textedit.State, offset: int) {
    thor := cast(^Thor) data
    for file in thor.open_files {
        if &file.state == state {
            thor_dispatch_goto(thor, file, offset)
            return
        }
    }
}

// Sends a Definition request for `file` at `offset`. A snapshot of the buffer
// goes with it, so the worker never races later edits; the manager clones the
// strings, so the temp source is fine to hand over.
@(private = "file")
thor_dispatch_goto :: proc(thor: ^Thor, file: ^Open_File, offset: int) {
    if !file.loaded {
        return
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    source := textedit.text(&file.state)
    lang.manager_request_latest(
        &thor.lang_manager,
        .Definition,
        file.path,
        ext,
        source,
        offset,
        file.state.revision,
        thor.workspace_dir,
    )
}

// A row's jump target in the Go to Symbol picker: the file and byte offset to
// jump to when the row is chosen. Kept in the same order as the picker items, so
// the pick callback maps the chosen index straight to it.
Doc_Symbol :: struct {
    path:   string, // owned
    offset: int,
}

// Ctrl+Shift+O: list the active file's top-level symbols in a fuzzy picker. The
// request is async; thor_on_lang_result opens the picker when it lands.
thor_goto_symbol :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    source := textedit.text(&file.state)
    lang.manager_request_latest(
        &thor.lang_manager,
        .Document_Symbols,
        file.path,
        ext,
        source,
        0,
        file.state.revision,
        thor.workspace_dir,
    )
}

// Shared by thor_goto_workspace_symbol and thor_workspace_symbol_query_changed:
// the active buffer's ext/path/source/revision when it names a language Thor
// covers, or a bare ".odin" scope with no active file so Ctrl+Q still works.
// `source` is a fresh textedit borrow each call, never held past it.
@(private = "file")
thor_workspace_symbol_scope :: proc(thor: ^Thor) -> (ext, path, source: string, revision: u64) {
    ext = ".odin"
    if file := thor_active_open_file(thor); file != nil && file.loaded {
        if e := thor_file_extension(file.name); lang.manager_allows(&thor.lang_manager, e, .Workspace_Symbols) {
            ext = e
            path = file.path
            source = textedit.text(&file.state)
            revision = file.state.revision
        }
    }
    return
}

// Ctrl+Q: list every top-level symbol across the workspace in a fuzzy picker.
// The active buffer (if it's an Odin file) seeds the request with its unsaved
// source and path; otherwise the scan runs over the workspace's .odin files with
// a bare ".odin" extension so it works even with no Odin file focused.
thor_goto_workspace_symbol :: proc(thor: ^Thor) {
    ext, path, source, revision := thor_workspace_symbol_scope(thor)
    if !lang.manager_allows(&thor.lang_manager, ext, .Workspace_Symbols) {
        return
    }
    thor.workspace_symbols_typing = false
    thor.workspace_symbols_needs_query = ext != ".odin"

    id: u64
    if !thor.workspace_symbols_needs_query {
        // The scan reads and parses every .odin file off-thread, which takes a
        // beat on a big workspace; the loading picker below keeps the chord
        // instant regardless.
        id = lang.manager_request_latest(
            &thor.lang_manager,
            .Workspace_Symbols,
            path,
            ext,
            source,
            0,
            revision,
            thor.workspace_dir,
        )
        if id == 0 {
            return
        }
    }
    thor.workspace_symbols_request_id = id
    widgets.command_palette_pick_rich_loading(
        thor.command_palette,
        &thor.ui_context,
        "Go to symbol...",
        thor_pick_symbol,
        thor,
        thor_workspace_symbol_query_changed,
        thor,
    )
    if thor.workspace_symbols_needs_query {
        // A server-backed workspace/symbol answers an empty query with nothing
        // (pyright, gopls, clangd): skip that round trip entirely and land the
        // picker straight in its "type to search" state; on_query_changed
        // dispatches the first real request once the user types.
        widgets.command_palette_pick_rich_set(thor.command_palette, {}, "Type to search workspace symbols…")
    }
}

// The palette's on_query_changed hook: re-dispatches Workspace_Symbols with the
// typed text as `req.query`. Both backends filter on it, so a keystroke on a
// large workspace carries back the matches instead of every symbol; the picker
// still ranks and re-filters what it gets. The first, pre-typing dispatch sends
// no query and gets the whole list, which is what makes the chord instant.
// Debounced like completion, so a burst of keystrokes costs one dispatch; the
// picker keeps showing its current rows (re-marked loading) until the new ones
// land.
@(private = "file")
thor_workspace_symbol_query_changed :: proc(data: rawptr, query: string) {
    thor := cast(^Thor)data
    ext, path, source, revision := thor_workspace_symbol_scope(thor)
    if !lang.manager_allows(&thor.lang_manager, ext, .Workspace_Symbols) {
        return
    }
    id := lang.manager_request_debounced(
        &thor.lang_manager,
        .Workspace_Symbols,
        path,
        ext,
        source,
        0,
        revision,
        thor.workspace_dir,
        lang.DEBOUNCE_TYPING,
        "",
        query,
    )
    if id == 0 {
        return
    }
    thor.workspace_symbols_request_id = id
    thor.workspace_symbols_typing = true
    widgets.command_palette_set_loading(thor.command_palette)
}

// F10: list every usage of the symbol under the caret in a fuzzy picker — its
// uses, not its declaration. A local/parameter is confined to its scope; a
// top-level symbol reaches its package and every file qualifying it, so the scan
// re-parses workspace files off-thread — the picker opens immediately in a
// loading state and thor_update_references fills it when the result lands.
thor_find_references :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    source := textedit.text(&file.state)
    id := lang.manager_request_latest(
        &thor.lang_manager,
        .References,
        file.path,
        ext,
        source,
        textedit.primary_cursor(&file.state).caret,
        file.state.revision,
        thor.workspace_dir,
    )
    if id == 0 {
        return
    }
    thor.references_request_id = id
    widgets.command_palette_pick_rich_loading(
        thor.command_palette,
        &thor.ui_context,
        "References...",
        thor_pick_symbol,
        thor,
    )
}

// Ctrl+R: rename the symbol under the caret across the workspace. Prompts for the
// new name (prefilled with the current one) in the palette; thor_prompt_rename
// dispatches the request once it is confirmed. Reports whether the prompt opened,
// so the chord can fall back to find/replace when there is no symbol to rename.
thor_rename_symbol :: proc(thor: ^Thor) -> bool {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return false
    }
    // manager_allows, not manager_supports: with rename gated off the chord must
    // fall back to find and replace rather than answer nothing.
    if !lang.manager_allows(&thor.lang_manager, thor_file_extension(file.name), .Rename) {
        return false
    }
    cursor := textedit.primary_cursor(&file.state)
    source := textedit.text(&file.state)
    lo, hi, ok := textedit.word_range_at(source, cursor.caret)
    if !ok {
        return false
    }
    // A selection that is not exactly this word — part of one, or a span across
    // several — means a text replace is wanted, not a symbol rename. Selecting
    // the word itself (a double-click) is how a symbol gets picked, so that one
    // still renames.
    if textedit.has_selection(cursor) {
        sel_lo, sel_hi := textedit.selection_range(cursor)
        if sel_lo != lo || sel_hi != hi {
            return false
        }
    }
    widgets.command_palette_prompt(
        thor.command_palette,
        &thor.ui_context,
        "Rename symbol",
        thor_prompt_rename,
        thor,
        source[lo:hi],
    )
    return true
}

// Dispatches the Rename request once the user confirms a new name. The caret is
// re-read here (the prompt held focus, so the buffer has not moved) and the
// buffer's path and revision are remembered, so thor_apply_rename can tell the
// file the edits were computed against from the others they touch.
@(private = "file")
thor_prompt_rename :: proc(data: rawptr, input: string) {
    thor := cast(^Thor) data
    new_name := strings.trim_space(input)
    if new_name == "" {
        return
    }
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    source := textedit.text(&file.state)
    // Picking the symbol by double-clicking it leaves the caret on the word's
    // trailing boundary, where the node the backend reads is whichever token the
    // parse tree hands back; its start is unambiguously inside the identifier.
    offset := textedit.primary_cursor(&file.state).caret
    if lo, _, ok := textedit.word_range_at(source, offset); ok {
        offset = lo
    }
    id := lang.manager_request_latest(
        &thor.lang_manager,
        .Rename,
        file.path,
        ext,
        source,
        offset,
        file.state.revision,
        thor.workspace_dir,
        new_name,
    )
    if id == 0 {
        return
    }
    thor.rename_request_id = id
    delete(thor.rename_path)
    thor.rename_path = strings.clone(file.path)
}

// One file a set of edits touches, gathered while they are validated: the file's
// current content (its buffer when open, its bytes on disk when not) and the
// edits landing in it.
@(private)
Edit_Target :: struct {
    path:      string,     // canonical; temp-allocated
    file:      ^Open_File, // nil when the file is not open in the editor
    text:      string,     // current content with CRLF collapsed — the space engine offsets are in
    // A file that is not open is rewritten on disk: `disk_text` is what it holds
    // byte for byte (what an undo restores) and `ending` is what a rewrite emits.
    disk_text: string,
    ending:    Line_Ending,
    edits:     [dynamic]lang.Text_Edit, // temp-allocated; the edits borrow the caller's strings
}

// One file the last applied edit set touched, and what it takes to move it in
// either direction. An open file rides its own buffer entry: `revision` is what
// the buffer read after the last move, and matching it proves that entry is
// still the top of its stack. A file that was not open was rewritten on disk
// with no history of its own, so it carries both sides — `before` to undo to and
// `after` to redo to. A copy that changed since matches neither and is refused
// rather than clobbered.
@(private)
Edit_Undo_File :: struct {
    path:     string, // owned, canonical
    open:     bool,
    revision: u64,    // open files: the buffer revision the last move left behind
    before:   string, // owned; closed files: the content from before the edits
    after:    string, // owned; closed files: the content the edits wrote
}

// Applies a backend's edits — all of them, or none. Validates every edit against
// the content it will land in first and refuses the whole set on any mismatch
// rather than half-applying it: edits that land in some files and not others
// break a build silently, and the engine read the unopened files from disk, so an
// open buffer with unsaved changes is not what it measured. Open files are edited
// through the buffer (one undo entry each, saved by the user); closed ones are
// rewritten in place.
//
// `origin` is the buffer the edits were computed against — the one file allowed
// to differ from its saved copy — and `snapshot` the revision it was at. Returns
// how many edits landed, across how many files, and why none did. A false `ok`
// with `applied > 0` is the one partial case: a file could not be written after
// earlier ones already had.
//
// `resource_ops` runs in a fixed phase order around the text edits — Create,
// then the edits above, then Rename, then Delete — rather than replaying its
// own array position; see lang.Resource_Op for why. Create runs first because
// an edit in the same set may target a file it just made; Rename and Delete run
// last, and only once the edits committed. Neither joins the edits' Ctrl+Z
// record — same as the explorer's own rename/delete, which have no undo either.
@(private)
thor_apply_edits :: proc(
    thor: ^Thor,
    edits: []lang.Text_Edit,
    origin: string,
    snapshot: u64,
    resource_ops: []lang.Resource_Op = nil,
) -> (applied: int, files: int, ok: bool, reason: string) {
    for op in resource_ops {
        if op.kind != .Create {
            continue
        }
        if cok, creason := thor_create_resource(op.path, op.overwrite, op.ignore_if_exists); !cok {
            return 0, 0, false, creason
        }
    }

    targets := make([dynamic]Edit_Target, context.temp_allocator)
    for edit in edits {
        index, found := thor_edit_target(thor, &targets, edit.path, origin, snapshot)
        if !found {
            return 0, 0, false, "save the affected files first"
        }
        target := &targets[index]
        if edit.start < 0 || edit.end > len(target.text) || target.text[edit.start:edit.end] != edit.old_text {
            return 0, 0, false, "the files changed under it"
        }
        append(&target.edits, edit)
    }

    // What it takes to reverse each file, gathered as it is written; handed to
    // thor_set_edit_undo below so ctrl+z can take the whole set back.
    record := make([dynamic]Edit_Undo_File)
    committed := false
    defer if !committed {
        thor_free_edit_undo(record[:])
        delete(record)
    }

    for &target in targets {
        if len(target.edits) == 0 {
            continue
        }
        if target.file != nil {
            ranges := make([dynamic]textedit.Replace, context.temp_allocator)
            for edit in target.edits {
                append(&ranges, textedit.Replace {start = edit.start, end = edit.end, text = edit.new_text})
            }
            // No undo entry is pushed when nothing lands, so nothing to reverse.
            if n := textedit.replace_ranges(&target.file.state, ranges[:]); n > 0 {
                applied += n
                append(&record, Edit_Undo_File {
                    path     = strings.clone(target.path),
                    open     = true,
                    revision = target.file.state.revision,
                })
            }
            continue
        }
        // Not open: splice the edits (ascending, non-overlapping) into the file's
        // bytes and write it back. The watcher picks the change up from there.
        b := strings.builder_make(context.temp_allocator)
        last := 0
        for edit in target.edits {
            strings.write_string(&b, target.text[last:edit.start])
            strings.write_string(&b, edit.new_text)
            last = edit.end
        }
        strings.write_string(&b, target.text[last:])
        // The splice works in LF; the file goes back with the endings it had.
        written := thor_to_disk_text(strings.to_string(b), target.ending, context.temp_allocator)
        if werr := os.write_entire_file(target.path, transmute([]byte) written); werr != nil {
            // Whatever landed before this file stays undoable.
            thor_set_edit_undo(thor, record)
            committed = true
            return applied, len(targets), false, "a file could not be written"
        }
        append(&record, Edit_Undo_File {
            path   = strings.clone(target.path),
            before = strings.clone(target.disk_text),
            after  = strings.clone(written),
        })
        applied += len(target.edits)
    }
    if len(record) > 0 {
        thor_set_edit_undo(thor, record)
        committed = true
    }

    for op in resource_ops {
        if op.kind != .Rename {
            continue
        }
        if rok, rreason := thor_rename_resource(thor, op.path, op.new_path, op.overwrite); !rok {
            return applied, len(targets), false, rreason
        }
    }
    for op in resource_ops {
        if op.kind != .Delete {
            continue
        }
        if dok, dreason := thor_delete_resource(thor, op.path); !dok {
            return applied, len(targets), false, dreason
        }
    }
    if len(resource_ops) > 0 {
        widgets.tree_refresh(thor.tree)
        thor_refresh_git_status(thor)
    }
    return applied, len(targets), true, ""
}

// Replaces the reversal record, freeing the one it supersedes: only the most
// recent edit set is undoable this way. A fresh edit set also makes the redo
// chain moot, the way a buffer edit clears its own redo stack.
@(private = "file")
thor_set_edit_undo :: proc(thor: ^Thor, record: [dynamic]Edit_Undo_File) {
    thor_clear_edit_undo(thor)
    thor_clear_edit_redo(thor)
    thor.edit_undo = record
}

@(private)
thor_clear_edit_undo :: proc(thor: ^Thor) {
    thor_free_edit_undo(thor.edit_undo[:])
    delete(thor.edit_undo)
    thor.edit_undo = nil
}

@(private)
thor_clear_edit_redo :: proc(thor: ^Thor) {
    thor_free_edit_undo(thor.edit_redo[:])
    delete(thor.edit_redo)
    thor.edit_redo = nil
}

@(private = "file")
thor_free_edit_undo :: proc(entries: []Edit_Undo_File) {
    for entry in entries {
        delete(entry.path)
        delete(entry.before)
        delete(entry.after)
    }
}

// Reverses the last applied edit set (a rename's occurrences, a code action's
// fix) across every file it touched, buffers and on-disk copies alike. Returns
// false — touching nothing — when any of those files has moved on since: a
// buffer that was edited (its undo entry is no longer on top), one that was
// closed, or an on-disk copy that no longer holds what was written. Ctrl+Z falls
// through to the focused buffer's own undo then.
thor_undo_last_edits :: proc(thor: ^Thor) -> bool {
    if !thor_edits_still_apply(thor, thor.edit_undo[:], forward = true) {
        return false
    }

    failed := false
    for &entry in thor.edit_undo {
        if entry.open {
            file := thor_open_file_at(thor, entry.path)
            textedit.undo(&file.state)
            entry.revision = file.state.revision // what a redo has to still find
            continue
        }
        if werr := os.write_entire_file(entry.path, transmute([]byte) entry.before); werr != nil {
            thor_flash_status(thor, "Undo incomplete: a file could not be written", is_error = true)
            failed = true
            break
        }
    }

    files := len(thor.edit_undo)
    record := thor.edit_undo
    thor.edit_undo = nil
    if failed {
        // Half reversed: there is no consistent state left to redo back to.
        thor_free_edit_undo(record[:])
        delete(record)
    } else {
        thor_clear_edit_redo(thor)
        thor.edit_redo = record
    }
    thor_flash_status(thor, fmt.tprintf("Undid the edits in %d files", files))
    return true
}

// Re-applies the edit set the last cross-file undo took back, across every file
// it touched. Refuses the whole thing on the same terms thor_undo_last_edits
// does, so ctrl+shift+z falls through to the focused buffer when the set no
// longer fits.
thor_redo_last_edits :: proc(thor: ^Thor) -> bool {
    if !thor_edits_still_apply(thor, thor.edit_redo[:], forward = false) {
        return false
    }

    failed := false
    for &entry in thor.edit_redo {
        if entry.open {
            file := thor_open_file_at(thor, entry.path)
            textedit.redo(&file.state)
            entry.revision = file.state.revision // what a later undo has to find
            continue
        }
        if werr := os.write_entire_file(entry.path, transmute([]byte) entry.after); werr != nil {
            thor_flash_status(thor, "Redo incomplete: a file could not be written", is_error = true)
            failed = true
            break
        }
    }

    files := len(thor.edit_redo)
    record := thor.edit_redo
    thor.edit_redo = nil
    if failed {
        thor_free_edit_undo(record[:])
        delete(record)
    } else {
        thor_clear_edit_undo(thor)
        thor.edit_undo = record
    }
    thor_flash_status(thor, fmt.tprintf("Redid the edits in %d files", files))
    return true
}

// True when every file in `record` still holds what the move expects, so the
// whole set can be applied. Checked before any of it is touched: a half-reversed
// rename is worse than one that was left alone. `forward` picks the side each
// closed file must currently hold — `after` to undo from, `before` to redo from.
@(private = "file")
thor_edits_still_apply :: proc(thor: ^Thor, record: []Edit_Undo_File, forward: bool) -> bool {
    if len(record) == 0 {
        return false
    }
    for entry in record {
        file := thor_open_file_at(thor, entry.path)
        if entry.open {
            // The revision proves the buffer entry is still on top: textedit
            // bumps it on every edit, undo and redo alike.
            if file == nil || file.state.revision != entry.revision {
                return false
            }
            continue
        }
        data, err := os.read_entire_file(entry.path, context.temp_allocator)
        if err != nil || string(data) != (forward ? entry.after : entry.before) {
            return false
        }
        // Opened since it was rewritten: the reload that the write triggers must
        // not be able to drop unsaved work.
        if file != nil && (!file.loaded || file.state.revision != file.saved_revision) {
            return false
        }
    }
    return true
}

// The open buffer for `path`, or nil when the file is not open.
@(private = "file")
thor_open_file_at :: proc(thor: ^Thor, path: string) -> ^Open_File {
    for file in thor.open_files {
        if !file.closed && thor_same_path(file.path, path) {
            return file
        }
    }
    return nil
}

// Applies a rename's edits once they land.
@(private = "file")
thor_apply_rename :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.rename_request_id {
        return
    }
    thor.rename_request_id = 0
    if !res.ok || (len(res.edits) == 0 && len(res.resource_ops) == 0) {
        thor_flash_status(thor, "Nothing to rename here", is_error = true)
        return
    }
    applied, files, ok, reason := thor_apply_edits(thor, res.edits[:], thor.rename_path, res.revision, res.resource_ops[:])
    if !ok {
        verb := applied > 0 ? "incomplete" : "aborted"
        thor_flash_status(thor, fmt.tprintf("Rename %s: %s", verb, reason), is_error = true)
        return
    }
    thor_flash_status(thor, fmt.tprintf("Renamed %d occurrences in %d files", applied, files))
}

// Finds (or creates) the target entry for `path`, reading the file's current
// content once. False refuses the whole edit set: the file is open with unsaved
// changes the engine's on-disk scan never saw, the `origin` buffer has been
// edited since the request was made (`snapshot` is its revision), or the file
// can't be read.
@(private = "file")
thor_edit_target :: proc(
    thor: ^Thor,
    targets: ^[dynamic]Edit_Target,
    path: string,
    origin: string,
    snapshot: u64,
) -> (int, bool) {
    canonical := path
    if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
        canonical = abs
    }
    for target, index in targets^ {
        if thor_same_path(target.path, canonical) {
            return index, true
        }
    }

    for file in thor.open_files {
        if !thor_same_path(file.path, canonical) {
            continue
        }
        if !file.loaded {
            return 0, false
        }
        if thor_same_path(canonical, origin) {
            // The buffer the edits were computed against: its offsets only hold
            // while it is still at the revision that was snapshotted.
            if file.state.revision != snapshot {
                return 0, false
            }
        } else if file.state.revision != file.saved_revision {
            return 0, false // unsaved changes; the engine measured the disk copy
        }
        append(targets, Edit_Target {
            path  = canonical,
            file  = file,
            // A copy: the targets are collected first and edited after, so this
            // one outlives edits made to another buffer in the same set.
            text  = textedit.text_clone(&file.state, context.temp_allocator),
            edits = make([dynamic]lang.Text_Edit, context.temp_allocator),
        })
        return len(targets) - 1, true
    }

    data, rerr := os.read_entire_file(canonical, context.temp_allocator)
    if rerr != nil {
        return 0, false
    }
    disk := string(data)
    text, _ := thor_to_buffer_text(disk)
    append(targets, Edit_Target {
        path      = canonical,
        text      = text,
        disk_text = disk,
        ending    = thor_detect_line_ending(disk),
        edits     = make([dynamic]lang.Text_Edit, context.temp_allocator),
    })
    return len(targets) - 1, true
}

// Ctrl+Shift+Space: resolve the call the caret is inside and show its signature,
// with the active argument bracketed, in a popup above the caret. Async; the
// result is shown by thor_show_signature. The explicit keybind flashes when the
// caret is not in a call.
thor_signature_help :: proc(thor: ^Thor) {
    editor := thor.active_pane == 0 ? thor.editor : thor.editor2
    file := thor_active_open_file(thor)
    thor_request_signature(thor, editor, file, auto = false)
}

// Editor auto-trigger: as the caret moves inside a call (typing `(`/`,`, editing
// arguments), resolve the enclosing call silently — no flash when the caret is
// not in one, and any live popup is dismissed instead.
thor_editor_signature_help :: proc(data: rawptr, editor: ^widgets.Editor, state: ^textedit.State, offset: int) {
    thor := cast(^Thor) data
    for file in thor.open_files {
        if &file.state != state {
            continue
        }
        thor_request_signature(thor, editor, file, auto = true)
        return
    }
}

// Editor auto-trigger: fired by the widget after a character is typed. Finds
// the file bound to `state`, exactly like thor_editor_signature_help, and asks
// thor_format_on_type whether it applies.
thor_editor_on_type :: proc(data: rawptr, editor: ^widgets.Editor, state: ^textedit.State, offset: int, char: string) {
    thor := cast(^Thor) data
    for file in thor.open_files {
        if &file.state != state {
            continue
        }
        thor_format_on_type(thor, file, offset, char)
        return
    }
}

// Dispatches a Signature_Help request for `file`'s caret and binds the result to
// `editor` at dispatch time — a plain tab/pane switch before the result lands
// dispatches no new request, so the pane must be fixed now rather than
// re-derived from whatever is active when thor_show_signature runs. `auto`
// distinguishes the typing-driven trigger (silent on miss, and debounced so a
// burst of argument keystrokes resolves the call once) from the explicit keybind
// (flashes on miss, dispatched immediately — the user is waiting on it); it
// rides along to thor_show_signature via signature_auto.
@(private = "file")
thor_request_signature :: proc(thor: ^Thor, editor: ^widgets.Editor, file: ^Open_File, auto: bool) {
    if editor == nil || file == nil || !file.loaded {
        return
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    source := textedit.text(&file.state)
    caret := textedit.primary_cursor(&file.state).caret
    id: u64
    if auto {
        id = lang.manager_request_debounced(
            &thor.lang_manager,
            .Signature_Help,
            file.path,
            ext,
            source,
            caret,
            file.state.revision,
            thor.workspace_dir,
        )
    } else {
        id = lang.manager_request_latest(
            &thor.lang_manager,
            .Signature_Help,
            file.path,
            ext,
            source,
            caret,
            file.state.revision,
            thor.workspace_dir,
        )
    }
    if id == 0 {
        return
    }
    thor.signature_editor = editor
    thor.signature_request_id = id
    thor.signature_auto = auto
}

// F3: render the documentation for the package the caret refers to (an import,
// a `pkg.Symbol` operand, or — failing that — the file's own package). Async;
// thor_show_package_doc opens the rendered page in the other editor pane when it
// lands. A superseded result (a newer F3) is dropped by id.
thor_package_doc :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    source := textedit.text(&file.state)
    id := lang.manager_request_latest(
        &thor.lang_manager,
        .Package_Doc,
        file.path,
        ext,
        source,
        textedit.primary_cursor(&file.state).caret,
        file.state.revision,
        thor.workspace_dir,
    )
    if id == 0 {
        return
    }
    thor.package_doc_request_id = id
}

// Shows a rendered package-doc page in the pane the user is not editing in (the
// "other" window), opening the split if it was closed so their code stays
// visible beside it. Drops a superseded result by id and flashes when nothing
// resolved. The page is written to a per-package temp file (outside the
// workspace, so the analyzer never indexes it) that gets Odin highlighting and
// is reused on repeat presses.
@(private = "file")
thor_show_package_doc :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.package_doc_request_id {
        return
    }
    thor.package_doc_request_id = 0
    if !res.ok || res.doc.text == "" {
        thor_flash_status(thor, "No package documentation here", is_error = true)
        return
    }

    dir := thor_docs_dir()
    if dir == "" {
        return
    }
    if !os.exists(dir) {
        if err := os.make_directory(dir); err != nil {
            log.errorf("Could not create doc directory %q: %v", dir, err)
            thor_flash_status(thor, "Could not create the documentation folder", is_error = true)
            return
        }
    }
    stem := thor_doc_file_stem(strings.trim_prefix(res.doc.title, "package "))
    // A .md doc so it renders as Markdown documentation (OLS-style: fenced
    // signatures + doc prose), not as an Odin source tab.
    file_name := strings.concatenate({stem, ".md"}, context.temp_allocator)
    path, _ := filepath.join({dir, file_name}, context.temp_allocator)

    // The doc goes in the pane the user is not editing in.
    thor_render_doc_in_pane(thor, path, res.doc.text, 1 - thor.active_pane)
}

// The per-session directory package-doc pages are written to: a `thor-docs`
// folder under the OS temp dir, deliberately outside any workspace so the Odin
// analyzer's workspace scan never picks the pages up as source. "" when no temp
// dir is known (then the doc is silently skipped rather than written to the CWD).
@(private = "file")
thor_docs_dir :: proc() -> string {
    base := os.get_env("TEMP", context.temp_allocator)
    if base == "" {
        base = os.get_env("TMP", context.temp_allocator)
    }
    when ODIN_OS != .Windows {
        // TEMP and TMP are Windows names; POSIX uses TMPDIR and falls back to /tmp.
        if base == "" {
            base = os.get_env("TMPDIR", context.temp_allocator)
        }
        if base == "" {
            base = "/tmp"
        }
    }
    if base == "" {
        return ""
    }
    joined, _ := filepath.join({base, "thor-docs"}, context.temp_allocator)
    return joined
}

// A filesystem-safe stem for a package's doc file: keeps identifier bytes,
// replaces anything else with '_'. Temp-allocated.
@(private = "file")
thor_doc_file_stem :: proc(name: string) -> string {
    if name == "" {
        return "package"
    }
    b := strings.builder_make(context.temp_allocator)
    for i in 0 ..< len(name) {
        c := name[i]
        if c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
            strings.write_byte(&b, c)
        } else {
            strings.write_byte(&b, '_')
        }
    }
    return strings.to_string(b)
}

// Writes `text` to `path` and shows it in editor pane `pane`, opening the split
// when the target is the second pane. An already-open doc buffer is refreshed in
// place (and kept clean so autosave never fires); a new one is opened into the
// pane without moving keyboard focus off the user's code.
@(private = "file")
thor_render_doc_in_pane :: proc(thor: ^Thor, path, text: string, pane: int) {
    if werr := os.write_entire_file(path, transmute([]byte) text); werr != nil {
        return
    }
    canonical := path
    if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
        canonical = abs
    }

    if pane == 1 && !thor.split_visible {
        thor.split_visible = true
        thor_apply_split(thor)
    }

    for file, index in thor.open_files {
        if file.path == canonical {
            if file.loaded {
                textedit.set_text(&file.state, text)
                file.saved_revision = file.state.revision
            }
            thor.pane_file[pane] = index
            thor_bind_pane(thor, pane)
            thor_sync_active_signal(thor)
            return
        }
    }

    // Not open yet: thor_open_file routes to the active pane, so borrow it
    // briefly to land the doc in `pane`, then restore focus/active state.
    prev := thor.active_pane
    thor.active_pane = pane
    thor_open_file(thor, canonical)
    thor.active_pane = prev
    thor_sync_active_signal(thor)
}

// Editor auto-trigger: as a word is typed the editor asks the owner to resolve
// semantic completions at `offset`. Matches the buffer to its open file and
// dispatches a Completion request; the pane is remembered so the async result
// routes back to it. Returns true when a request was dispatched, so the editor
// can hold off on its buffer-word fallback for this keystroke.
thor_editor_completion :: proc(data: rawptr, editor: ^widgets.Editor, state: ^textedit.State, offset: int) -> bool {
    thor := cast(^Thor) data
    for file in thor.open_files {
        if &file.state != state {
            continue
        }
        if !file.loaded {
            return false
        }
        ext := thor_file_extension(file.name)
        if !lang.manager_supports(&thor.lang_manager, ext) {
            return false
        }
        source := textedit.text(&file.state)
        // Debounced: a fast typist would otherwise spawn a worker and clone the
        // whole buffer per keystroke, only for the next key to cancel it.
        id := lang.manager_request_debounced(
            &thor.lang_manager,
            .Completion,
            file.path,
            ext,
            source,
            offset,
            file.state.revision,
            thor.workspace_dir,
        )
        if id == 0 {
            return false
        }
        thor.completion_editor = editor
        thor.completion_request_id = id
        return true
    }
    return false
}

// Fills the completion popup once its request lands. Drops a superseded result
// (a later keystroke fired a newer request) by id, and one whose buffer snapshot
// is stale, then hands the candidates to the editor tinted by kind.
@(private = "file")
thor_update_completion :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.completion_request_id || thor.completion_editor == nil {
        return
    }
    thor.completion_request_id = 0
    editor := thor.completion_editor
    if !res.ok || len(res.symbols) == 0 || editor.state == nil || editor.state.revision != res.revision {
        return
    }
    items := make([dynamic]widgets.Completion_Item, context.temp_allocator)
    for sym in res.symbols {
        append(&items, widgets.Completion_Item {
            text  = sym.name,
            color = thor_symbol_color(thor, sym.kind),
        })
    }
    widgets.editor_set_completions(editor, items[:])
}

// Asks the analyzer what every identifier in `file` actually is, so the
// highlighter can color the names the grammar cannot tell apart — a parameter, a
// local, a package and an undeclared typo all parse as a bare identifier. Driven
// by the highlight pass rather than by the caret: this classifies the whole
// buffer and nothing is waiting on the answer.
//
// One request runs at a time. The classification is a full-file walk, and
// holding the slot until the last one lands paces it to its own round trip
// instead of firing one per keystroke; the highlight pass re-asks on the next
// frame, so a file left behind by a burst of typing catches up on its own.
thor_request_semantic :: proc(thor: ^Thor, file: ^Open_File) {
    if thor.semantic_request_id != 0 || !file.loaded {
        return
    }
    if file.semantic_ready && file.semantic_revision == file.state.revision {
        return
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    source := textedit.text(&file.state)
    // Debounced as well as serialized: a fast typist would otherwise have a
    // classification in flight continuously, each one obsolete before it lands.
    id := lang.manager_request_debounced(
        &thor.lang_manager,
        .Semantic_Tokens,
        file.path,
        ext,
        source,
        0, // whole-buffer request; there is no caret to answer about
        file.state.revision,
        thor.workspace_dir,
    )
    if id == 0 {
        return
    }
    thor.semantic_request_id = id
    delete(thor.semantic_path)
    thor.semantic_path = strings.clone(file.path)
}

// Stores a classification once it lands and marks the file's highlights stale,
// so the per-frame pass merges the overlay into them. The file is looked up by
// path: its tab may have been closed (and the record freed) while the request
// was in flight.
//
// Applied even when the buffer has moved past the revision it was computed at.
// The offsets are then a keystroke or two behind, which is a far smaller lie
// than dropping every analyzer color until the next result — that would flash
// the file back to plain syntax colors on each keystroke. A result carrying
// nothing still advances the revision, so a file the analyzer has nothing to say
// about is not re-asked every frame.
@(private = "file")
thor_update_semantic :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.semantic_request_id {
        return
    }
    thor.semantic_request_id = 0
    file := thor_open_file_at(thor, thor.semantic_path)
    delete(thor.semantic_path)
    thor.semantic_path = ""
    if file == nil {
        return
    }
    clear(&file.semantic)
    append(&file.semantic, ..res.tokens[:])
    file.semantic_revision = res.revision
    file.semantic_ready = true
    file.highlighted = false // re-merged by the per-frame highlight pass
}

// Frees the jump targets kept from the last symbol picker.
thor_clear_doc_symbols :: proc(thor: ^Thor) {
    for sym in thor.doc_symbols {
        delete(sym.path)
    }
    clear(&thor.doc_symbols)
}

// Mouse dwell: the editor asks the owner to resolve a hover at `offset`. The
// pane is remembered so the async result routes back to it. A snapshot of the
// buffer goes with the request, so the worker never races later edits.
thor_editor_hover :: proc(data: rawptr, editor: ^widgets.Editor, state: ^textedit.State, offset: int) {
    thor := cast(^Thor) data
    for file in thor.open_files {
        if &file.state != state {
            continue
        }
        if !file.loaded {
            return
        }
        ext := thor_file_extension(file.name)
        if !lang.manager_supports(&thor.lang_manager, ext) {
            return
        }
        source := textedit.text(&file.state)
        id := lang.manager_request_latest(
            &thor.lang_manager,
            .Hover,
            file.path,
            ext,
            source,
            offset,
            file.state.revision,
            thor.workspace_dir,
        )
        thor.hover_editor = editor
        thor.hover_request_id = id
        return
    }
}

// Reaped on the main thread once per frame (see the run loop). Applies whatever
// the backend resolved; a failed go-to-definition flashes the statusline.
thor_on_lang_result :: proc(user: rawptr, res: ^lang.Result) {
    thor := cast(^Thor) user
    #partial switch res.kind {
    case .Definition:
        if !res.ok {
            thor_flash_status(thor, "No definition found", is_error = true)
        } else if len(res.symbols) > 1 {
            // Several workspace files declare the name; let the user pick.
            thor_show_definition_candidates(thor, res)
        } else {
            thor_goto_location(thor, res.location.path, res.location.start)
        }
    case .Hover:
        // Drop superseded results; only the latest request's answer may show,
        // and only while its buffer snapshot is still current.
        if res.id != thor.hover_request_id || thor.hover_editor == nil {
            return
        }
        editor := thor.hover_editor
        if res.ok && editor.state != nil && editor.state.revision == res.revision {
            widgets.editor_show_hover(editor, res.hover.text, res.hover.start, res.hover.end)
        }
    case .Document_Symbols:
        thor_show_symbols(thor, res, "No symbols in file")
    case .Workspace_Symbols:
        thor_update_workspace_symbols(thor, res)
    case .References:
        thor_update_references(thor, res)
    case .Signature_Help:
        thor_show_signature(thor, res)
    case .Completion:
        thor_update_completion(thor, res)
    case .Package_Doc:
        thor_show_package_doc(thor, res)
    case .Rename:
        thor_apply_rename(thor, res)
    case .Diagnostics:
        thor_apply_diagnostics(thor, res)
    case .Code_Actions:
        thor_show_code_actions(thor, res)
    case .Semantic_Tokens:
        thor_update_semantic(thor, res)
    case .Format:
        thor_apply_format(thor, res)
    case .Format_Range:
        thor_apply_format_range(thor, res)
    case .Format_On_Type:
        thor_apply_on_type_format(thor, res)
    case .Progress:
        thor_apply_progress(thor, res)
    case .Apply_Edit:
        thor_apply_pushed_edit(thor, res)
    }
}

// Applies a server-initiated workspace/applyEdit, then answers the reply the
// server is blocked on. Unlike Rename there is no one buffer the edit was
// computed against — the server may push this unprompted — so this reuses
// thor_apply_edits' generic per-file snapshot check (thor_edit_target) rather
// than a single-file revision check: an empty `origin` never matches a real
// path, so every file is validated against its own current content.
@(private = "file")
thor_apply_pushed_edit :: proc(thor: ^Thor, res: ^lang.Result) {
    _, _, ok, _ := thor_apply_edits(thor, res.edits[:], "", 0, res.resource_ops[:])
    if res.on_applied != nil {
        res.on_applied(res.token, ok)
    }
}

// Applies a server's $/progress push to the statusline. A "begin"/"report"
// step replaces the shown message; "end" clears it, so the indicator goes
// away with the work instead of freezing on its last message.
@(private = "file")
thor_apply_progress :: proc(thor: ^Thor, res: ^lang.Result) {
    delete(thor.lsp_progress_message)
    thor.lsp_progress_message = res.progress.done ? "" : strings.clone(res.progress.message)
}

// Shows the resolved signature in a popup above the caret once its request lands.
// Drops a superseded result (the caret has since moved to another call) by id, and
// brackets the active argument so the caller can see which parameter it is on.
// A procedure group answers with one entry per member: they are drawn one per
// line with the one the arguments match marked, so the alternatives stay visible
// while the call is being typed.
@(private = "file")
thor_show_signature :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.signature_request_id || thor.signature_editor == nil {
        return
    }
    thor.signature_request_id = 0
    auto := thor.signature_auto
    editor := thor.signature_editor
    if !res.ok || len(res.signature.entries) == 0 {
        // An auto request that finds no call just dismisses whatever popup was up
        // (the caret has moved out of the call); only the explicit keybind flashes.
        if auto {
            widgets.editor_clear_signature(editor)
        } else {
            thor_flash_status(thor, "No signature found")
        }
        return
    }
    if editor.state == nil || editor.state.revision != res.revision {
        return
    }
    widgets.editor_show_signature(
        editor,
        thor_signature_text(res.signature),
        textedit.primary_cursor(editor.state).caret,
    )
}

// Lays the signature entries out for the popup. A lone signature is drawn bare,
// exactly as before — the overload machinery must not put a marker column in
// front of every ordinary call. Two or more are one per line, the matched entry
// marked with `>` so it reads as the one in effect, and only that entry brackets
// its active parameter: the caret is in one argument slot, and bracketing the
// same slot on candidates that do not have it would claim a match that was never
// made. Returned in the temp allocator; editor_show_signature clones it.
@(private = "file")
thor_signature_text :: proc(sig: lang.Signature_Info) -> string {
    if len(sig.entries) == 1 {
        return thor_signature_line(sig.entries[0], active = true)
    }
    b := strings.builder_make(context.temp_allocator)
    for entry, i in sig.entries {
        if i > 0 {
            strings.write_byte(&b, '\n')
        }
        active := i == sig.active
        strings.write_string(&b, active ? "> " : "  ")
        strings.write_string(&b, thor_signature_line(entry, active))
    }
    return strings.to_string(b)
}

// One entry's label, with its active parameter bracketed when the entry is the
// matched one and the backend reported a span for it.
@(private = "file")
thor_signature_line :: proc(entry: lang.Signature_Entry, active: bool) -> string {
    label := entry.label
    if !active || entry.active_end <= entry.active_start {
        return label
    }
    if entry.active_start < 0 || entry.active_end > len(label) {
        return label
    }
    return fmt.tprintf(
        "%s[%s]%s",
        label[:entry.active_start],
        label[entry.active_start:entry.active_end],
        label[entry.active_end:],
    )
}

// Fills the already-open (loading) references picker once its scan lands. Drops
// a superseded (or already-replaced/closed) result the same way workspace
// symbols does, and closes the loading picker with a flash when nothing matched.
@(private = "file")
thor_update_references :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.references_request_id {
        return
    }
    thor.references_request_id = 0
    if !widgets.command_palette_pick_loading(thor.command_palette) {
        return // picker closed or replaced by another pick; drop the result
    }
    if !res.ok || len(res.symbols) == 0 {
        widgets.command_palette_close(thor.command_palette, &thor.ui_context)
        thor_flash_status(thor, "No references found")
        return
    }
    items := thor_build_reference_items(thor, res)
    widgets.command_palette_pick_rich_set(thor.command_palette, items)
}

// Builds the references picker rows from a references result: each row is the
// source line the usage sits on (its code context, no name tint) with a
// "path:line" preview under the selected row. Rebuilds the jump targets
// (doc_symbols) in the same order, so the shared pick callback maps a chosen row
// to its file and offset.
@(private = "file")
thor_build_reference_items :: proc(thor: ^Thor, res: ^lang.Result) -> []widgets.Pick_Item {
    thor_clear_doc_symbols(thor)
    items := make([dynamic]widgets.Pick_Item, context.temp_allocator)
    for sym in res.symbols {
        append(&thor.doc_symbols, Doc_Symbol {path = strings.clone(sym.path), offset = sym.offset})
        append(&items, widgets.Pick_Item {
            text     = sym.signature,
            name_len = 0,
            color    = thor.theme.primary_text_color,
            detail   = thor_symbol_detail(thor, sym),
        })
    }
    return items[:]
}

// Fills the already-open (loading) workspace-symbol picker once its scan lands.
// Drops the result if it's superseded by a newer Ctrl+Q or the picker has since
// been closed or replaced (command_palette_pick_rich_set is a no-op then). A
// server-backed extension never dispatches its initial empty-query scan
// (thor_goto_workspace_symbol skips it and shows the hint directly), so any
// result landing here is either the native Odin engine's always-full scan or a
// re-dispatch from typing — an empty native scan means the workspace really has
// none and closes the picker with a flash; an empty typed result just empties
// the list, since "no symbols match this text" is not "nothing to show".
@(private = "file")
thor_update_workspace_symbols :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.workspace_symbols_request_id {
        return
    }
    thor.workspace_symbols_request_id = 0
    if !widgets.command_palette_pick_loading(thor.command_palette) {
        return // picker closed or replaced by another pick; drop the result
    }
    if !res.ok || len(res.symbols) == 0 {
        if thor.workspace_symbols_typing {
            widgets.command_palette_pick_rich_set(thor.command_palette, {})
            return
        }
        widgets.command_palette_close(thor.command_palette, &thor.ui_context)
        thor_flash_status(thor, "No symbols in workspace")
        return
    }
    items := thor_build_symbol_items(thor, res)
    widgets.command_palette_pick_rich_set(thor.command_palette, items)
}

// Builds the rich symbol picker from a symbol result and opens it. Each row is
// the real Odin declaration ("add :: proc(...) -> int"), its name tinted by kind
// and a "path:line" preview under the selected row. The result's memory is freed
// right after this returns (see manager_dispatch), so each row's jump target is
// cloned into Thor-owned storage the pick callback reads on a later frame; the
// palette deep-copies the display strings itself.
@(private = "file")
thor_show_symbols :: proc(thor: ^Thor, res: ^lang.Result, empty_message: string) {
    if !res.ok || len(res.symbols) == 0 {
        thor_flash_status(thor, empty_message)
        return
    }
    items := thor_build_symbol_items(thor, res)
    widgets.command_palette_pick_rich(
        thor.command_palette,
        &thor.ui_context,
        "Go to symbol...",
        items,
        thor_pick_symbol,
        thor,
    )
}

// A go-to-definition that resolved to several workspace declarations (the flat
// cross-file match ignores package boundaries, so the same name can live in more
// than one package): list the candidates in the rich picker instead of silently
// jumping to the first. Reuses the symbol picker's rows and jump targets, so
// choosing one jumps there.
@(private = "file")
thor_show_definition_candidates :: proc(thor: ^Thor, res: ^lang.Result) {
    items := thor_build_symbol_items(thor, res)
    widgets.command_palette_pick_rich(
        thor.command_palette,
        &thor.ui_context,
        "Multiple definitions...",
        items,
        thor_pick_symbol,
        thor,
    )
}

// Rebuilds the picker's jump targets (doc_symbols) from a symbol result and
// returns the matching rich rows in the same order, temp-allocated (the palette
// deep-copies them). Shared by the document-symbol and workspace-symbol pickers.
@(private = "file")
thor_build_symbol_items :: proc(thor: ^Thor, res: ^lang.Result) -> []widgets.Pick_Item {
    thor_clear_doc_symbols(thor)
    items := make([dynamic]widgets.Pick_Item, context.temp_allocator)
    for sym in res.symbols {
        append(&thor.doc_symbols, Doc_Symbol {path = strings.clone(sym.path), offset = sym.offset})
        // A server-backed symbol carries no signature when it could not read the
        // declaring line (SymbolInformation has no `detail` field at all, and a
        // cross-file workspace scan needs a disk read the native engine never
        // does): fall back to the bare name rather than a row with no text.
        text := sym.signature != "" ? sym.signature : sym.name
        append(&items, widgets.Pick_Item {
            text     = text,
            name_len = min(len(sym.name), len(text)),
            color    = thor_symbol_color(thor, sym.kind),
            detail   = thor_symbol_detail(thor, sym),
        })
    }
    return items[:]
}

// Pick callback: jumps to the chosen row's file and offset. The index is into
// doc_symbols, which the palette kept in the order it was handed the items.
thor_pick_symbol :: proc(data: rawptr, index: int) {
    thor := cast(^Thor) data
    if index < 0 || index >= len(thor.doc_symbols) {
        return
    }
    sym := thor.doc_symbols[index]
    thor_goto_location(thor, sym.path, sym.offset)
}

// The preview line for a symbol row: its file path (workspace-relative, forward
// slashes) and 1-based line. Temp-allocated; the palette copies it.
@(private = "file")
thor_symbol_detail :: proc(thor: ^Thor, sym: lang.Symbol) -> string {
    rel := strings.trim_prefix(sym.path, thor.workspace_dir)
    rel = strings.trim_left(rel, "/\\")
    slash, _ := strings.replace_all(rel, "\\", "/", context.temp_allocator)
    return fmt.tprintf("%s:%d", slash, sym.line)
}

// Tints a symbol name by its kind, reusing the theme's syntax colors so the
// picker reads like code.
@(private)
thor_symbol_color :: proc(thor: ^Thor, kind: string) -> rl.Color {
    switch kind {
    case "function": return thor.theme.functions_color
    case "type":     return thor.theme.keywords_color
    case "enum":     return thor.theme.keywords_color
    case "constant": return thor.theme.numbers_color
    case "var":      return thor.theme.variables_color
    case "keyword":  return thor.theme.keywords_color
    case "namespace": return thor.theme.functions_color
    case "field":    return thor.theme.variables_color
    case "enum_member": return thor.theme.numbers_color
    }
    return thor.theme.primary_text_color
}

// Posts a transient statusline notice, shown for STATUS_MESSAGE_SECS. Errors
// (is_error) are drawn in the theme's error color, other notices accented.
thor_flash_status :: proc(thor: ^Thor, message: string, is_error := false) {
    delete(thor.status_message)
    thor.status_message = strings.clone(message)
    thor.status_message_time = rl.GetTime()
    thor.status_message_error = is_error
}

// Jumps to `offset` in the file at `path`, opening it if needed. When the target
// is still loading, the jump is deferred to thor_apply_pending_goto.
@(private = "file")
thor_goto_location :: proc(thor: ^Thor, path: string, offset: int) {
    thor_jump_record(thor)
    canonical := path
    if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
        canonical = abs
    }

    for file, index in thor.open_files {
        if thor_same_path(file.path, canonical) {
            thor_set_active_file(thor, index)
            if file.loaded {
                thor_place_caret(thor, file, offset)
            } else {
                thor_set_pending_goto(thor, canonical, offset)
            }
            return
        }
    }

    // Not open: open it, then finish the jump once its buffer lands.
    thor_set_pending_goto(thor, canonical, offset)
    thor_open_file(thor, path)
}

// Jumps to LINE:COL (1-based) in the file at `path`, opening it if needed. Like
// thor_goto_location but for callers that have a line/column (console error
// output) rather than a byte offset; the offset is resolved against the buffer
// once it has loaded.
thor_goto_file_line_col :: proc(thor: ^Thor, path: string, line, col: int) {
    thor_jump_record(thor)
    canonical := path
    if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
        canonical = abs
    }

    for file, index in thor.open_files {
        if thor_same_path(file.path, canonical) {
            thor_set_active_file(thor, index)
            if file.loaded {
                thor_place_caret(thor, file, offset_for_line_col(file, line, col))
            } else {
                thor_set_pending_goto_line_col(thor, canonical, line, col)
            }
            return
        }
    }

    thor_set_pending_goto_line_col(thor, canonical, line, col)
    thor_open_file(thor, path)
}

// Byte offset of the (1-based) line/column within a loaded file's buffer.
@(private = "file")
offset_for_line_col :: proc(file: ^Open_File, line, col: int) -> int {
    text := textedit.text(&file.state)
    start := textedit.state_line_start(&file.state, max(line - 1, 0)) + max(col - 1, 0)
    return clamp(start, 0, len(text))
}

// Applies a deferred jump once its file has loaded. Called each frame from
// thor_update_files, after the I/O reap that may have completed the load.
thor_apply_pending_goto :: proc(thor: ^Thor) {
    if !thor.pending_goto_active {
        return
    }
    for file, index in thor.open_files {
        if file.path != thor.pending_goto_path {
            continue
        }
        if file.load_failed {
            break // give up on this jump
        }
        if !file.loaded {
            return // still loading; retry next frame
        }
        thor_set_active_file(thor, index)
        offset := thor.pending_goto_offset
        if thor.pending_goto_line > 0 {
            offset = offset_for_line_col(file, thor.pending_goto_line, thor.pending_goto_col)
        }
        thor_place_caret(thor, file, offset)
        break
    }
    thor_clear_pending_goto(thor)
}

// Puts the caret at `offset` and centers the view on it; the one place every
// jump lands.
@(private = "file")
thor_place_caret :: proc(thor: ^Thor, file: ^Open_File, offset: int) {
    textedit.set_single_cursor(&file.state, offset)
    editor := thor.active_pane == 0 ? thor.editor : thor.editor2
    widgets.editor_center_on_caret(editor)
}

@(private = "file")
thor_set_pending_goto :: proc(thor: ^Thor, path: string, offset: int) {
    delete(thor.pending_goto_path)
    thor.pending_goto_path = strings.clone(path)
    thor.pending_goto_offset = offset
    thor.pending_goto_line = 0
    thor.pending_goto_active = true
}

// Like thor_set_pending_goto but defers with a 1-based line/column, resolved to
// an offset against the buffer once it loads.
@(private = "file")
thor_set_pending_goto_line_col :: proc(thor: ^Thor, path: string, line, col: int) {
    delete(thor.pending_goto_path)
    thor.pending_goto_path = strings.clone(path)
    thor.pending_goto_line = line
    thor.pending_goto_col = col
    thor.pending_goto_active = true
}

@(private = "file")
thor_clear_pending_goto :: proc(thor: ^Thor) {
    delete(thor.pending_goto_path)
    thor.pending_goto_path = ""
    thor.pending_goto_active = false
    thor.pending_goto_line = 0
}

// File extension including the dot (".odin"), or "" when the name has none.
thor_file_extension :: proc(name: string) -> string {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return ""
    }
    return name[dot:]
}
