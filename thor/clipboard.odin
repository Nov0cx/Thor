// Clipboard history: the texts the editor copied, cut or pasted, newest first,
// and the picker that pastes one of them again.
package thor

import "core:strings"

import "../editview"
import ui "../vendor/loom/loom"

CLIPBOARD_HISTORY_MAX :: 30
// Longest entry kept, in bytes. A bigger copy is not recorded.
CLIPBOARD_ENTRY_MAX :: 1 << 20
CLIPBOARD_LABEL_RUNES :: 60

// Records `text` as the newest entry. A text already in the list moves to the front.
thor_clipboard_note :: proc(data: rawptr, text: string) {
    thor := cast(^Thor) data
    if len(text) == 0 || len(text) > CLIPBOARD_ENTRY_MAX || strings.trim_space(text) == "" {
        return
    }
    history := &thor.clipboard_history
    if len(history) > 0 && history[0] == text {
        return
    }
    for entry, i in history {
        if entry == text {
            ordered_remove(history, i)
            inject_at(history, 0, entry)
            return
        }
    }
    for len(history) >= CLIPBOARD_HISTORY_MAX {
        delete(pop(history))
    }
    inject_at(history, 0, strings.clone(text))
}

thor_clipboard_history_destroy :: proc(thor: ^Thor) {
    for entry in thor.clipboard_history {
        delete(entry)
    }
    delete(thor.clipboard_history)
    thor.clipboard_history = nil
}

// One-line label of an entry: its first non-blank line, cut to CLIPBOARD_LABEL_RUNES,
// with the count of the other lines.
thor_clipboard_label :: proc(text: string, allocator := context.temp_allocator) -> string {
    first := ""
    lines := 0
    rest := text
    for line in strings.split_lines_iterator(&rest) {
        lines += 1
        if first == "" {
            first = strings.trim_space(line)
        }
    }

    b := strings.builder_make(allocator)
    runes := 0
    for r in first {
        if runes == CLIPBOARD_LABEL_RUNES {
            strings.write_string(&b, "…")
            break
        }
        strings.write_rune(&b, r == '\t' ? ' ' : r)
        runes += 1
    }
    if lines > 1 {
        strings.write_string(&b, "  (+")
        strings.write_int(&b, lines - 1)
        strings.write_string(&b, lines == 2 ? " line)" : " lines)")
    }
    return strings.to_string(b)
}

thor_cmd_clipboard_history :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor_active_editor(thor) == nil || thor_active_editor(thor).state == nil {
        thor_flash_status(thor, "Clipboard history: no file to paste into")
        return
    }
    if len(thor.clipboard_history) == 0 {
        thor_flash_status(thor, "Clipboard history is empty")
        return
    }
    labels := make([]string, len(thor.clipboard_history), context.temp_allocator)
    for entry, i in thor.clipboard_history {
        labels[i] = thor_clipboard_label(entry)
    }
    thor_select_open(
        thor,
        "Clipboard History",
        labels,
        thor.clipboard_history[0],
        nil,
        thor_clipboard_history_commit,
        thor,
        thor.clipboard_history[:],
    )
}

// Puts the chosen entry on the clipboard and pastes it into the active pane.
@(private = "file")
thor_clipboard_history_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    ui.set_clipboard_text(choice)
    editview.editor_paste(thor_active_editor(thor))
}
