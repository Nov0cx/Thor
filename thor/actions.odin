package thor

import rl "vendor:raylib"

import "../plugin"
import "../setting"
import "../ui"
import "../widgets"

thor_minimize_window :: proc(_: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    rl.MinimizeWindow()
}

thor_toggle_maximize :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    // IsWindowMaximized() can report false after MaximizeWindow() on an
    // undecorated window, so track the state ourselves to keep the toggle symmetric.
    if thor.window_maximized {
        rl.RestoreWindow()
    } else {
        rl.MaximizeWindow()
    }
    thor.window_maximized = !thor.window_maximized
}

thor_close_window :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    thor.should_close = true
}

thor_toggle_fullscreen :: proc(_: ^Thor) {
    rl.ToggleBorderlessWindowed()
}

// App-level shortcuts, dispatched before widget focus (see
// ui.context_set_global_key): they work no matter what is focused.
thor_global_key :: proc(data: rawptr, event: ^ui.Event) -> bool {
    thor := cast(^Thor) data

    // While the Settings modal is open it owns the keyboard (Escape closes it,
    // and a keybinding row may be capturing a chord), so no global shortcut fires.
    if widgets.settings_view_is_open(thor.settings_view) {
        return false
    }

    chord := setting.keybind_to_string(
        setting.Keybind{key = event.key, mods = event.mods},
        context.temp_allocator,
    )

    // A release only reaches the plugins: every shortcut here acts on the press.
    if event.kind == .Key_Release {
        if chord == "" {
            return false
        }
        return plugin.manager_dispatch_key_up(&thor.plugins, chord, event.mods)
    }

    // A held key only continues the undo/redo trail; every other shortcut here
    // is a one-shot that must not fire once per repeat tick.
    if event.repeat {
        return thor_global_undo_redo(thor, event)
    }

    // Let plugins observe every key press. The chord matches thor.keybind's
    // format; observing without consuming lets the real action below still run.
    if chord != "" {
        if plugin.manager_dispatch_key(&thor.plugins, chord, event.mods) {
            return true
        }
    }

    // The command palette toggle works no matter what is focused.
    if setting.keybind_matches(thor.command_palette_key, event.key, event.mods) {
        thor_toggle_command_palette(thor)
        return true
    }
    // Quick-open (file search) works no matter what is focused, and re-triggers
    // into file mode even if the palette is already open on the command list.
    if setting.keybind_matches(thor.quick_open_key, event.key, event.mods) {
        thor_quick_open(thor)
        return true
    }
    // Find opens on ctrl+f (works regardless of focus).
    if setting.keybind_matches(thor.find_key, event.key, event.mods) {
        thor_open_find(thor, false)
        return true
    }
    // Ctrl+R renames the symbol under the caret when the language backend can,
    // and opens find/replace otherwise. With an overlay open it always means
    // replace: ctrl+r in the find bar is how the replace field is revealed.
    if setting.keybind_matches(thor.replace_key, event.key, event.mods) {
        overlay :=
            widgets.command_palette_is_open(thor.command_palette) ||
            widgets.find_replace_is_open(thor.find_replace)
        if overlay || !thor_rename_symbol(thor) {
            thor_open_find(thor, true)
        }
        return true
    }
    // Go to line opens the palette in line mode regardless of focus.
    if setting.keybind_matches(thor.goto_line_key, event.key, event.mods) {
        widgets.command_palette_open_line(thor.command_palette, &thor.ui_context)
        return true
    }
    // Go to definition (Alt+Enter) resolves the symbol under the caret.
    if setting.keybind_matches(thor.goto_def_key, event.key, event.mods) {
        thor_goto_definition(thor)
        return true
    }
    // Go to symbol (Ctrl+Shift+O) lists the active file's top-level symbols.
    if setting.keybind_matches(thor.goto_symbol_key, event.key, event.mods) {
        thor_goto_symbol(thor)
        return true
    }
    // Go to symbol in workspace (Ctrl+Q) lists every top-level symbol in the tree.
    if setting.keybind_matches(thor.goto_workspace_symbol_key, event.key, event.mods) {
        thor_goto_workspace_symbol(thor)
        return true
    }
    // Go back / forward (Ctrl+Alt+Left / Ctrl+Alt+Right) walk the jump trail.
    if setting.keybind_matches(thor.jump_back_key, event.key, event.mods) {
        thor_jump_back(thor)
        return true
    }
    if setting.keybind_matches(thor.jump_forward_key, event.key, event.mods) {
        thor_jump_forward(thor)
        return true
    }
    // Find references (F10) lists every usage of the symbol under the caret.
    if setting.keybind_matches(thor.find_references_key, event.key, event.mods) {
        thor_find_references(thor)
        return true
    }
    // Signature help (Ctrl+Shift+Space) flashes the signature of the enclosing call.
    if setting.keybind_matches(thor.signature_help_key, event.key, event.mods) {
        thor_signature_help(thor)
        return true
    }
    // Package documentation (F3) renders the package under the caret in the other pane.
    if setting.keybind_matches(thor.package_doc_key, event.key, event.mods) {
        thor_package_doc(thor)
        return true
    }
    // Code actions (Ctrl+.) offer the fixes available at the caret.
    if setting.keybind_matches(thor.code_actions_key, event.key, event.mods) {
        thor_code_actions(thor)
        return true
    }
    // Flip to the previously active file (ctrl+e), like vim's Ctrl-^.
    if setting.keybind_matches(thor.last_file_key, event.key, event.mods) {
        thor_flip_last_file(thor)
        return true
    }
    // Toggle the editor split. split_key is KEY_NULL unless the user bound it,
    // so this never matches a real press until "toggle_split" is set.
    if setting.keybind_matches(thor.split_key, event.key, event.mods) {
        thor_toggle_split(thor)
        return true
    }

    // While an overlay is open it owns the keyboard (dispatched via focus),
    // so app shortcuts below are suppressed.
    if widgets.command_palette_is_open(thor.command_palette) || widgets.find_replace_is_open(thor.find_replace) {
        return false
    }

    // Escape closes the tip of the day before anything else reads it.
    if event.key == .ESCAPE && event.mods == {} && thor_tip_close_on_escape(thor) {
        return true
    }

    // User-bound app/file/view commands (unbound by default). Checked here so a
    // bound chord fires regardless of focus, like the built-in binds below.
    if thor_dispatch_app_bind(thor, event) {
        return true
    }

    // Fullscreen toggle is a bare key (no ctrl), so it is matched before the
    // ctrl-only guard below.
    if setting.keybind_matches(thor.fullscreen_key, event.key, event.mods) {
        thor_toggle_fullscreen(thor)
        return true
    }
    if setting.keybind_matches(thor.console_toggle_key, event.key, event.mods) {
        thor_toggle_console(thor, nil, nil)
        return true
    }

    // Focus shortcuts: open the target panel if it is collapsed, then move
    // keyboard focus to it.
    if setting.keybind_matches(thor.focus_editor_key, event.key, event.mods) {
        thor_focus_editor(thor)
        return true
    }
    if setting.keybind_matches(thor.focus_explorer_key, event.key, event.mods) {
        thor_focus_explorer(thor)
        return true
    }
    if setting.keybind_matches(thor.focus_terminal_key, event.key, event.mods) {
        thor_focus_terminal(thor)
        return true
    }
    if setting.keybind_matches(thor.trim_whitespace_key, event.key, event.mods) {
        thor_cmd_trim_whitespace(thor)
        return true
    }
    if setting.keybind_matches(thor.format_key, event.key, event.mods) {
        thor_format_document(thor)
        return true
    }
    if setting.keybind_matches(thor.format_selection_key, event.key, event.mods) {
        thor_format_selection_command(thor)
        return true
    }
    if setting.keybind_matches(thor.align_char_key, event.key, event.mods) {
        thor_cmd_align_at_char(thor)
        return true
    }
    if setting.keybind_matches(thor.close_tab_key, event.key, event.mods) {
        thor_close_file(thor, ui.signal_get(&thor.active_file))
        return true
    }
    if setting.keybind_matches(thor.next_tab_key, event.key, event.mods) {
        thor_cycle_tab(thor, 1)
        return true
    }
    if setting.keybind_matches(thor.previous_tab_key, event.key, event.mods) {
        thor_cycle_tab(thor, -1)
        return true
    }
    if setting.keybind_matches(thor.toggle_explorer_key, event.key, event.mods) {
        thor_toggle_explorer(thor, nil, nil)
        return true
    }

    return thor_global_undo_redo(thor, event)
}

// A rename or code action that touched other files moves whole, ahead of the
// focused buffer's own history. Once the set no longer applies (the files moved
// on), these fall through to that buffer as usual — a true return here breaks
// the dispatch, so the editor never sees a claimed key and cannot move the same
// buffer twice.
@(private = "file")
thor_global_undo_redo :: proc(thor: ^Thor, event: ^ui.Event) -> bool {
    if !(.Ctrl in event.mods) || (.Alt in event.mods) {
        return false
    }

    #partial switch event.key {
    case .Z:
        if (.Shift in event.mods) {
            if thor_redo_last_edits(thor) {
                return true
            }
        } else if thor_undo_last_edits(thor) {
            return true
        }
    case .Y:
        if thor_redo_last_edits(thor) {
            return true
        }
    }
    return false
}

// Switches to the previously active file, if still open. Pressing twice toggles
// back, since thor_set_active_file records the file being left.
thor_flip_last_file :: proc(thor: ^Thor) {
    target := thor.last_active_file
    if target == nil {
        return
    }
    for file, index in thor.open_files {
        if file == target {
            thor_set_active_file(thor, index)
            return
        }
    }
    thor.last_active_file = nil
}

thor_cycle_tab :: proc(thor: ^Thor, direction: int) {
    count := len(thor.open_files)
    if count == 0 {
        return
    }
    active := ui.signal_get(&thor.active_file)
    thor_set_active_file(thor, ((active + direction) % count + count) % count)
}

// Moves keyboard focus to the editor. The editor pane is always present, so no
// panel needs opening.
thor_focus_editor :: proc(thor: ^Thor) {
    thor.ui_context.focused = &thor.editor.widget
}

// Reveals the explorer panel if collapsed, then focuses the file tree so it can
// be driven with the arrow keys.
thor_focus_explorer :: proc(thor: ^Thor) {
    if !ui.signal_get(&thor.explorer_visible) {
        ui.signal_set(&thor.explorer_visible, true)
    }
    widgets.tree_focus(thor.tree)
    thor.ui_context.focused = &thor.tree.widget
}

// Reveals the console panel if collapsed, then focuses it for command input.
thor_focus_terminal :: proc(thor: ^Thor) {
    if !ui.signal_get(&thor.console_visible) {
        ui.signal_set(&thor.console_visible, true)
    }
    if thor.console != nil {
        thor.ui_context.focused = &thor.console.widget
    }
}

thor_toggle_explorer :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    ui.signal_set(&thor.explorer_visible, !ui.signal_get(&thor.explorer_visible))
}

thor_toggle_console :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    ui.signal_set(&thor.console_visible, !ui.signal_get(&thor.console_visible))
}

// Shows/hides the second editor pane and sizes both from split_ratio. The
// panes share the active file's buffer; the ratio is pane 1's width share.
thor_apply_split :: proc(thor: ^Thor) {
    thor.editor2.visible = thor.split_visible
    thor.editor_split_splitter.visible = thor.split_visible
    thor.editor.grow = thor.split_ratio
    thor.editor2.grow = 1 - thor.split_ratio
    if thor.split_visible {
        // Match pane 2's zoom to pane 1 when the split opens; afterwards each
        // pane zooms independently (ctrl+scroll targets the hovered pane).
        widgets.editor_set_font_size(thor.editor2, thor.editor.font_size)
    }
}

thor_toggle_split :: proc(thor: ^Thor) {
    thor.split_visible = !thor.split_visible
    if thor.split_visible {
        // Start pane 2 on a distinct file when possible (the ctrl+e target),
        // else mirror pane 1 so there is always something to show.
        if thor.pane_file[1] < 0 || thor.pane_file[1] >= len(thor.open_files) {
            thor.pane_file[1] = thor_second_pane_default(thor)
        }
        thor_apply_split(thor)
        thor_bind_pane(thor, 1)
        thor.active_pane = 1
        thor.ui_context.focused = &thor.editor2.widget
    } else {
        thor_apply_split(thor)
        thor.active_pane = 0
        thor.ui_context.focused = &thor.editor.widget
    }
    thor_sync_active_signal(thor)
}

// Index the split pane opens on: the previously active file if it is still open
// and not already in pane 1, otherwise whatever pane 1 shows.
@(private = "file")
thor_second_pane_default :: proc(thor: ^Thor) -> int {
    if thor.last_active_file != nil {
        for file, index in thor.open_files {
            if file == thor.last_active_file && index != thor.pane_file[0] {
                return index
            }
        }
    }
    return thor.pane_file[0]
}

// Splitter drag: shift the pane-1 width share by the dragged fraction of the
// row, clamped so neither pane collapses.
thor_resize_split :: proc(data: rawptr, delta: f32) {
    thor := cast(^Thor) data
    width := thor.editor_split_row.bounds.width
    if width <= 0 {
        return
    }
    thor.split_ratio = clamp(thor.split_ratio + delta / width, 0.15, 0.85)
    thor_apply_split(thor)
}

thor_resize_explorer :: proc(data: rawptr, delta: f32) {
    thor := cast(^Thor) data
    thor.explorer_width += delta
    if thor.explorer_width < 160 {
        thor.explorer_width = 160
    }
    if thor.explorer_width > 520 {
        thor.explorer_width = 520
    }
    thor_apply_layout_state(thor)
}

thor_resize_console :: proc(data: rawptr, delta: f32) {
    thor := cast(^Thor) data
    thor.console_height -= delta
    if thor.console_height < 120 {
        thor.console_height = 120
    }
    if thor.console_height > 420 {
        thor.console_height = 420
    }
    thor_apply_layout_state(thor)
}
