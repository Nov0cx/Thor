// Code actions: the quick fixes the language engine offers at the caret. Ctrl+.
// asks for them, the answers land in the rich picker, and choosing one applies
// its edits through thor_apply_edits — the same all-or-nothing applier a rename
// goes through, so a fix is one undo entry and never half-lands.
package thor

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

import "../lang"
import "../textedit"
import "../widgets"

// A fix held between the offer and the pick. The Result its edits came from is
// freed as soon as the handler returns (see manager_dispatch), so both the title
// and the edits are cloned into Thor-owned storage the pick callback reads on a
// later frame — the same reason the symbol picker clones its jump targets.
Pending_Action :: struct {
    title: string, // owned
    edits: [dynamic]lang.Text_Edit, // owned
}

// Ctrl+.: ask the engine what it can fix at the caret. Async; thor_show_code_actions
// opens the picker when the result lands, so nothing is shown until there is
// something to show.
thor_code_actions :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    ext := thor_file_extension(file.name)
    // manager_allows, not manager_supports: a backend that gates code actions
    // off must leave Ctrl+. doing nothing, not answering an error.
    if !lang.manager_allows(&thor.lang_manager, ext, .Code_Actions) {
        return
    }
    source := textedit.text(&file.state)
    id := lang.manager_request_latest(
        &thor.lang_manager,
        .Code_Actions,
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
    thor.code_action_request_id = id
    thor.code_action_revision = file.state.revision
    delete(thor.code_action_path)
    thor.code_action_path = strings.clone(file.path)
}

// Opens the picker once the offers land. A superseded request (the caret moved
// and a newer Ctrl+. went out) is dropped by id.
@(private)
thor_show_code_actions :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.code_action_request_id {
        return
    }
    thor.code_action_request_id = 0
    if !res.ok || len(res.actions) == 0 {
        thor_flash_status(thor, "No code actions here")
        return
    }

    thor_clear_code_actions(thor)
    items := make([dynamic]widgets.Pick_Item, context.temp_allocator)
    for action in res.actions {
        pending := Pending_Action{title = strings.clone(action.title)}
        for edit in action.edits {
            append(&pending.edits, lang.Text_Edit {
                path     = strings.clone(edit.path),
                start    = edit.start,
                end      = edit.end,
                old_text = strings.clone(edit.old_text),
                new_text = strings.clone(edit.new_text),
            })
        }
        append(&thor.code_actions, pending)
        append(&items, widgets.Pick_Item {
            text     = action.title,
            name_len = len(action.title),
            color    = thor_action_color(thor, action.kind),
            detail   = thor_action_detail(action),
        })
    }
    widgets.command_palette_pick_rich(
        thor.command_palette,
        &thor.ui_context,
        "Code actions...",
        items[:],
        thor_pick_code_action,
        thor,
    )
}

// Applies the chosen fix. The buffer may have moved since the offer — the user
// typed while the picker was open — and the applier catches that by validating
// every edit against the revision the request was made at, so a stale pick is
// refused rather than splicing text at offsets that no longer mean anything.
@(private = "file")
thor_pick_code_action :: proc(data: rawptr, index: int) {
    thor := cast(^Thor) data
    if index < 0 || index >= len(thor.code_actions) {
        return
    }
    action := thor.code_actions[index]
    applied, _, ok, reason := thor_apply_edits(
        thor,
        action.edits[:],
        thor.code_action_path,
        thor.code_action_revision,
    )
    if !ok {
        verb := applied > 0 ? "incomplete" : "aborted"
        thor_flash_status(thor, fmt.tprintf("%s %s: %s", action.title, verb, reason), is_error = true)
        return
    }
    thor_flash_status(thor, action.title)
}

// The preview line under the selected row: how much the fix changes, so a
// one-line insert reads differently from a three-file sweep before it is applied.
@(private = "file")
thor_action_detail :: proc(action: lang.Code_Action) -> string {
    if len(action.edits) == 1 {
        return "1 edit"
    }
    return fmt.tprintf("%d edits", len(action.edits))
}

// Tints an action row by its kind, reusing the theme's syntax colors so a fix
// reads apart from a refactor.
@(private = "file")
thor_action_color :: proc(thor: ^Thor, kind: string) -> rl.Color {
    switch kind {
    case "quickfix":
        return thor_symbol_color(thor, "function")
    case "refactor":
        return thor_symbol_color(thor, "type")
    }
    return thor_symbol_color(thor, "")
}

// Frees the fixes kept from the last code-action picker.
thor_clear_code_actions :: proc(thor: ^Thor) {
    for action in thor.code_actions {
        delete(action.title)
        for edit in action.edits {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        delete(action.edits)
    }
    clear(&thor.code_actions)
}
