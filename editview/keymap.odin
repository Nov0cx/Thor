// The editing keys of the editor as a table, so keybinds.json can move them.
// One table serves every editor: the chords are a user setting, not pane state.
package editview

import "../setting"
import "../textedit"
import ui "../vendor/loom/loom"

// An editing command a chord runs. action_name gives the keybinds.json name.
Action :: enum {
    None,
    Undo,
    Redo,
    Redo_Alt,
    Delete_Word_Left,
    Delete_Word_Right,
    Indent,
    Outdent,
    Insert_Line_Above,
    Insert_Line_Below,
    Move_Line_Up,
    Move_Line_Down,
    Duplicate_Line_Up,
    Duplicate_Line_Down,
    Delete_Line,
    Join_Lines,
    Uppercase,
    Lowercase,
    Capitalize,
    Toggle_Line_Comment,
    Toggle_Block_Comment,
    Word_Left,
    Word_Right,
    Line_Start,
    Line_End,
    Line_Start_Home,
    Line_End_Home,
    File_Start,
    File_End,
    File_Start_Up,
    File_End_Down,
    Page_Up,
    Page_Down,
    Matching_Bracket,
    Select_To_Matching_Bracket,
    Select_Between_Brackets,
    Add_Cursor_Above,
    Add_Cursor_Below,
    Collapse_Cursors,
    Select_Word,
    Select_Word_Substring,
    Select_Line,
    Select_All,
    Save,
    Copy,
    Cut,
    Paste,
    Zoom_In,
    Zoom_Out,
    Recenter,
}

@(private = "file")
Action_Info :: struct {
    name:    string, // the keybinds.json action
    key:     setting.Keybind, // the chord with no file to read
    // The chord with shift added runs the action too and extends the selection.
    extends: bool,
}

@(private = "file")
ACTIONS := [Action]Action_Info {
    .None                       = {},
    .Undo                       = {"undo", {.Z, {.Ctrl}}, false},
    .Redo                       = {"redo", {.Z, {.Ctrl, .Shift}}, false},
    .Redo_Alt                   = {"redo_alt", {.Y, {.Ctrl}}, false},
    .Delete_Word_Left           = {"delete_word_left", {.Backspace, {.Ctrl}}, false},
    .Delete_Word_Right          = {"delete_word_right", {.Delete, {.Ctrl}}, false},
    .Indent                     = {"indent", {.Tab, {}}, false},
    .Outdent                    = {"outdent", {.Tab, {.Shift}}, false},
    .Insert_Line_Above          = {"insert_line_above", {.Enter, {.Ctrl, .Shift}}, false},
    .Insert_Line_Below          = {"insert_line_below", {.Enter, {.Ctrl}}, false},
    .Move_Line_Up               = {"move_line_up", {.Up, {.Alt}}, false},
    .Move_Line_Down             = {"move_line_down", {.Down, {.Alt}}, false},
    .Duplicate_Line_Up          = {"duplicate_line_up", {.Up, {.Alt, .Shift}}, false},
    .Duplicate_Line_Down        = {"duplicate_line_down", {.Down, {.Alt, .Shift}}, false},
    .Delete_Line                = {"delete_line", {.K, {.Ctrl, .Shift}}, false},
    .Join_Lines                 = {"join_lines", {.J, {.Ctrl}}, false},
    .Uppercase                  = {"uppercase", {.U, {.Alt}}, false},
    .Lowercase                  = {"lowercase", {.L, {.Alt}}, false},
    .Capitalize                 = {"capitalize", {.C, {.Alt}}, false},
    .Toggle_Line_Comment        = {"toggle_line_comment", {.K, {.Ctrl}}, false},
    .Toggle_Block_Comment       = {"toggle_block_comment", {.A, {.Alt, .Shift}}, false},
    .Word_Left                  = {"word_left", {.Left, {.Ctrl}}, true},
    .Word_Right                 = {"word_right", {.Right, {.Ctrl}}, true},
    .Line_Start                 = {"line_start", {.Left, {.Alt}}, true},
    .Line_End                   = {"line_end", {.Right, {.Alt}}, true},
    .Line_Start_Home            = {"line_start_home", {.Home, {}}, true},
    .Line_End_Home              = {"line_end_home", {.End, {}}, true},
    .File_Start                 = {"file_start", {.Home, {.Ctrl}}, true},
    .File_End                   = {"file_end", {.End, {.Ctrl}}, true},
    .File_Start_Up              = {"file_start_up", {.Up, {.Ctrl}}, true},
    .File_End_Down              = {"file_end_down", {.Down, {.Ctrl}}, true},
    .Page_Up                    = {"page_up", {.Page_Up, {}}, true},
    .Page_Down                  = {"page_down", {.Page_Down, {}}, true},
    .Matching_Bracket           = {"matching_bracket", {.P, {.Ctrl}}, false},
    .Select_To_Matching_Bracket = {"select_to_matching_bracket", {.Backslash, {.Ctrl, .Shift}}, false},
    .Select_Between_Brackets    = {"select_between_brackets", {.P, {.Ctrl, .Shift}}, false},
    .Add_Cursor_Above           = {"add_cursor_above", {.Up, {.Ctrl, .Alt}}, false},
    .Add_Cursor_Below           = {"add_cursor_below", {.Down, {.Ctrl, .Alt}}, false},
    .Collapse_Cursors           = {"collapse_cursors", {.Escape, {}}, false},
    .Select_Word                = {"select_word", {.D, {.Ctrl}}, false},
    .Select_Word_Substring      = {"select_word_substring", {.D, {.Ctrl, .Shift}}, false},
    .Select_Line                = {"select_line", {.L, {.Ctrl}}, false},
    .Select_All                 = {"select_all", {.A, {.Ctrl}}, false},
    .Save                       = {"save", {.S, {.Ctrl}}, false},
    .Copy                       = {"copy", {.C, {.Ctrl}}, false},
    .Cut                        = {"cut", {.X, {.Ctrl}}, false},
    .Paste                      = {"paste", {.V, {.Ctrl}}, false},
    .Zoom_In                    = {"zoom_in", {.Pad_Add, {.Ctrl}}, false},
    .Zoom_Out                   = {"zoom_out", {.Pad_Subtract, {.Ctrl}}, false},
    .Recenter                   = {"recenter", {.J, {.Ctrl, .Shift}}, false},
}

// The chord of each action. A key of .None is an action with no chord.
@(private = "file")
g_keymap: [Action]setting.Keybind

@(private = "file")
g_keymap_ready: bool

// The keybinds.json name of an action.
action_name :: proc(action: Action) -> string {
    return ACTIONS[action].name
}

// Puts every action back on its built-in chord.
keymap_reset :: proc() {
    for info, action in ACTIONS {
        g_keymap[action] = info.key
    }
    g_keymap_ready = true
}

// Gives an action its chord. A chord with key .None takes the chord away.
keymap_bind :: proc(action: Action, chord: setting.Keybind) {
    if !g_keymap_ready {
        keymap_reset()
    }
    g_keymap[action] = chord
}

// The action a chord runs. `extend` is set when the chord is an action's chord
// with shift added, for the actions that extend a selection.
keymap_lookup :: proc(key: ui.Key, mods: ui.Mod_Set) -> (action: Action, extend: bool) {
    if !g_keymap_ready {
        keymap_reset()
    }
    if key == .None {
        return .None, false
    }
    for chord, candidate in g_keymap {
        if candidate != .None && chord.key == key && chord.mods == mods {
            return candidate, false
        }
    }
    if .Shift not_in mods {
        return .None, false
    }
    plain := mods - {.Shift}
    for chord, candidate in g_keymap {
        if ACTIONS[candidate].extends && chord.key == key && chord.mods == plain {
            return candidate, true
        }
    }
    return .None, false
}

// Runs one action on the editor. False when the action does not apply, so the
// key goes on to the fixed keys.
@(private)
editor_run_action :: proc(editor: ^Editor, action: Action, extend: bool) -> bool {
    state := editor.state
    switch action {
    case .None:
        return false
    case .Undo:
        textedit.undo(state)
    case .Redo, .Redo_Alt:
        textedit.redo(state)
    case .Delete_Word_Left:
        textedit.delete_word_backward(state)
        editor_dismiss_completion(editor)
        editor_refresh_signature(editor)
    case .Delete_Word_Right:
        textedit.delete_word_forward(state)
        editor_dismiss_completion(editor)
        editor_refresh_signature(editor)
    case .Indent:
        if textedit.has_any_selection(state) {
            textedit.indent_lines(state)
        } else {
            textedit.insert_tab(state)
        }
    case .Outdent:
        textedit.outdent_lines(state)
    case .Insert_Line_Above:
        textedit.insert_line_above(state)
    case .Insert_Line_Below:
        textedit.insert_line_below(state)
    case .Move_Line_Up:
        textedit.move_lines(state, -1)
    case .Move_Line_Down:
        textedit.move_lines(state, 1)
    case .Duplicate_Line_Up:
        textedit.duplicate_lines(state, -1)
    case .Duplicate_Line_Down:
        textedit.duplicate_lines(state, 1)
    case .Delete_Line:
        textedit.delete_lines(state)
    case .Join_Lines:
        textedit.join_lines(state)
    case .Uppercase:
        textedit.transform_case(state, .Upper)
    case .Lowercase:
        textedit.transform_case(state, .Lower)
    case .Capitalize:
        textedit.transform_case(state, .Title)
    case .Toggle_Line_Comment:
        editor_toggle_comment(editor)
    case .Toggle_Block_Comment:
        textedit.toggle_block_comment(state, editor.comment_block[0], editor.comment_block[1])
    case .Word_Left:
        textedit.move_word(state, -1, extend)
        editor_refresh_signature(editor)
    case .Word_Right:
        textedit.move_word(state, 1, extend)
        editor_refresh_signature(editor)
    case .Line_Start, .Line_Start_Home:
        textedit.move_line_start(state, extend)
        editor_refresh_signature(editor)
    case .Line_End, .Line_End_Home:
        textedit.move_line_end(state, extend)
        editor_refresh_signature(editor)
    case .File_Start, .File_Start_Up:
        textedit.move_document_start(state, extend)
    case .File_End, .File_End_Down:
        textedit.move_document_end(state, extend)
    case .Page_Up:
        editor_page(editor, -1, extend)
        return true
    case .Page_Down:
        editor_page(editor, 1, extend)
        return true
    case .Matching_Bracket:
        textedit.move_to_matching_bracket(state, false)
    case .Select_To_Matching_Bracket:
        textedit.move_to_matching_bracket(state, true)
    case .Select_Between_Brackets:
        textedit.select_between_brackets(state)
    case .Add_Cursor_Above:
        textedit.add_cursor_vertical(state, -1)
    case .Add_Cursor_Below:
        textedit.add_cursor_vertical(state, 1)
    case .Collapse_Cursors:
        textedit.clear_selections(state)
        return true
    case .Select_Word:
        textedit.select_word_or_next(state, true)
    case .Select_Word_Substring:
        textedit.select_word_or_next(state, false)
    case .Select_Line:
        textedit.select_line(state)
    case .Select_All:
        textedit.select_all(state)
        return true
    case .Save:
        if editor.on_save == nil {
            return false
        }
        editor.on_save(editor.save_data)
        return true
    case .Copy:
        editor_copy(editor)
        return true
    case .Cut:
        editor_cut(editor)
    case .Paste:
        editor_paste(editor)
    case .Zoom_In:
        editor_zoom(editor, 1)
        return true
    case .Zoom_Out:
        editor_zoom(editor, -1)
        return true
    case .Recenter:
        editor_recenter(editor)
        return true
    }
    editor_scroll_to_caret(editor)
    return true
}

// Asks for the signature again when its popup is up: the caret moved in the call.
@(private)
editor_refresh_signature :: proc(editor: ^Editor) {
    if editor.signature_active {
        editor_request_signature(editor)
    }
}
