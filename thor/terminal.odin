package thor

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"

import "../setting"
import "../shell"
import "../ui"
import "../widgets"

// One console widget bound to one persistent shell. The shell outlives the
// commands run in it, so a `cd` sticks and a developer environment loaded once
// stays loaded; a reader thread pushes its output into `pending` and the main
// thread turns that into scrollback.
Terminal :: struct {
    owner:     ^Thor,
    console:   ^widgets.Console, // owned widget, a child of console_stack
    profile:   shell.Profile,    // borrowed from owner.shell_profiles
    session:   ^shell.Session,   // owned; nil once the shell is gone
    reader:    ^thread.Thread,   // owned
    allocator: runtime.Allocator,
    token:     string,           // owned, the end marker the shell echoes
    end_cmd:   string,           // owned, the command that writes the marker
    // Raw shell output the reader has not handed over. Guarded by owner.io_mutex.
    pending:   [dynamic]u8,
    // The reader reached the end of the stream. Guarded by owner.io_mutex.
    ended:     bool,
    // Output that is not yet a whole line, or is a partial end marker.
    carry:     [dynamic]u8,
    // A command's output is wanted. Cleared by its end marker, so the prompt the
    // shell writes next lands nowhere.
    capturing: bool,
    // The shell answered the init commands and is ready for the user.
    ready:     bool,
    // A command is running, so a submitted line is its stdin, not a new command.
    running:   bool,
    // The shell exited and was reported; the tab keeps its scrollback.
    dead:      bool,
}

@(private = "file")
READ_BUFFER :: 4096

// Starts a terminal on `profile` in the workspace directory. Returns nil when
// the shell does not start.
thor_terminal_create :: proc(thor: ^Thor, profile: shell.Profile) -> ^Terminal {
    term := new(Terminal)
    term.owner = thor
    term.profile = profile
    term.allocator = context.allocator
    term.pending = make([dynamic]u8)
    term.carry = make([dynamic]u8)
    term.token = shell.end_token(len(thor.terminals))
    term.end_cmd = shell.end_command(profile.kind, term.token)

    // Widget ids are borrowed, so every terminal shares one literal; nothing
    // looks a console up by id.
    term.console = widgets.console_create("terminal")
    thor_terminal_apply_theme(thor, term)
    widgets.console_set_on_link(term.console, thor_console_link, thor_console_activate, thor)
    widgets.console_set_on_run(term.console, thor_terminal_submit, term)
    widgets.console_set_on_interrupt(term.console, thor_terminal_interrupt, term)
    widgets.console_set_on_context_menu(term.console, thor_console_context_menu, thor)
    ui.widget_set_grow(&term.console.widget, 1)
    term.console.min_size = {0, 110}

    widgets.console_clear(term.console)
    if !thor_terminal_open_session(term) {
        widgets.console_append(term.console, fmt.tprintf("Could not start %s.\n", profile.name))
        term.dead = true
    }
    return term
}

// Starts the shell and its reader thread, then sends the profile's init
// commands. Their output is dropped, since it is only prompt setup.
@(private = "file")
thor_terminal_open_session :: proc(term: ^Terminal) -> bool {
    session, ok := shell.session_start(term.profile, term.owner.workspace_dir)
    if !ok {
        return false
    }
    term.session = session
    term.ended = false
    term.dead = false
    term.ready = false
    term.capturing = false
    term.running = true
    clear(&term.carry)

    widgets.console_append(term.console, fmt.tprintf("%s  %s\n", term.profile.name, term.owner.workspace_dir))
    term.reader = thread.create_and_start_with_poly_data(term, thor_terminal_reader)

    for command in term.profile.init {
        thor_terminal_write_line(term, command)
    }
    thor_terminal_write_line(term, term.end_cmd)
    return true
}

// Reader thread: hands raw output to the main thread and stops at the end of the
// stream, which is where the shell exited.
@(private = "file")
thor_terminal_reader :: proc(term: ^Terminal) {
    context.allocator = term.allocator
    buf: [READ_BUFFER]u8
    for {
        read := shell.session_read(term.session, buf[:])
        if read <= 0 {
            break
        }
        sync.lock(&term.owner.io_mutex)
        append(&term.pending, ..buf[:read])
        sync.unlock(&term.owner.io_mutex)
    }
    sync.lock(&term.owner.io_mutex)
    term.ended = true
    sync.unlock(&term.owner.io_mutex)
}

@(private = "file")
thor_terminal_write_line :: proc(term: ^Terminal, line: string) {
    if term.session == nil {
        return
    }
    shell.session_write(term.session, line)
    shell.session_write(term.session, "\n")
}

// Console_Run_Proc: a line submitted at the prompt. While a command runs the
// line is its stdin; otherwise it is a new command, followed by the marker that
// reports where its output ends.
thor_terminal_submit :: proc(data: rawptr, command: string) {
    term := cast(^Terminal) data
    if term.session == nil {
        widgets.console_append(term.console, "The shell is not running. Restart it from the console menu.\n")
        widgets.console_command_finished(term.console)
        return
    }
    if term.running {
        thor_terminal_write_line(term, command)
        return
    }
    term.capturing = true
    term.running = true
    thor_terminal_write_line(term, command)
    thor_terminal_write_line(term, term.end_cmd)
}

// Console_Interrupt_Proc: stops the running command. Where the platform cannot
// signal it, the shell is restarted instead.
thor_terminal_interrupt :: proc(data: rawptr) {
    term := cast(^Terminal) data
    if term.session == nil || !term.running {
        return
    }
    if shell.session_interrupt(term.session) {
        widgets.console_append(term.console, "^C\n")
        return
    }
    widgets.console_append(term.console, "^C  restarting the shell\n")
    thor_terminal_restart(term)
}

// Ends the shell and starts a fresh one on the same profile, keeping the
// scrollback. Used by the interrupt on platforms without one, and after the
// shell exits.
thor_terminal_restart :: proc(term: ^Terminal) {
    thor_terminal_close_session(term)
    if !thor_terminal_open_session(term) {
        widgets.console_append(term.console, fmt.tprintf("Could not start %s.\n", term.profile.name))
        term.dead = true
    }
    widgets.console_command_finished(term.console)
}

// Stops the shell and joins the reader. Output the reader already handed over is
// dropped: it belongs to a session that is gone.
@(private = "file")
thor_terminal_close_session :: proc(term: ^Terminal) {
    if term.session == nil {
        return
    }
    shell.session_terminate(term.session)
    if term.reader != nil {
        thread.join(term.reader)
        thread.destroy(term.reader)
        term.reader = nil
    }
    shell.session_destroy(term.session)
    term.session = nil
    term.running = false
    sync.lock(&term.owner.io_mutex)
    clear(&term.pending)
    sync.unlock(&term.owner.io_mutex)
}

// Moves one frame of shell output into the scrollback. Returns whether a command
// finished, which is when the working tree may have changed.
thor_terminal_pump :: proc(term: ^Terminal) -> bool {
    sync.lock(&term.owner.io_mutex)
    chunk := ""
    if len(term.pending) > 0 {
        data := make([]u8, len(term.pending), context.temp_allocator)
        copy(data, term.pending[:])
        clear(&term.pending)
        chunk = string(data)
    }
    ended := term.ended
    sync.unlock(&term.owner.io_mutex)

    finished := false
    if chunk != "" {
        finished = thor_terminal_consume(term, chunk)
    }
    if ended && !term.dead {
        term.dead = true
        term.running = false
        widgets.console_append(term.console, "[the shell exited]\n")
        widgets.console_command_finished(term.console)
    }
    return finished
}

// Splits `chunk` on the end markers it carries, shows the output between them,
// and holds back a tail that may still grow into a marker.
@(private = "file")
thor_terminal_consume :: proc(term: ^Terminal, chunk: string) -> bool {
    text := strings.concatenate({string(term.carry[:]), chunk}, context.temp_allocator)
    clear(&term.carry)

    finished := false
    for {
        before, code, rest, found := shell.scan_end_marker(text, term.token)
        if !found {
            break
        }
        thor_terminal_emit(term, before)
        finished |= thor_terminal_finish(term, code)
        text = rest
    }

    // A whole token without its newline waits for the exit status behind it.
    hold := strings.contains(text, term.token) ? len(text) : shell.partial_marker_len(text, term.token)
    thor_terminal_emit(term, text[:len(text) - hold])
    append(&term.carry, ..transmute([]u8) text[len(text) - hold:])
    return finished
}

@(private = "file")
thor_terminal_emit :: proc(term: ^Terminal, text: string) {
    if term.capturing && text != "" {
        widgets.console_append(term.console, text)
    }
}

// An end marker arrived. Returns whether it ended a user command, as opposed to
// the init commands that make the shell ready.
@(private = "file")
thor_terminal_finish :: proc(term: ^Terminal, code: int) -> bool {
    was_ready := term.ready
    term.ready = true
    term.running = false
    term.capturing = false
    if was_ready && code != 0 {
        widgets.console_append(term.console, fmt.tprintf("[exit %d]\n", code))
    }
    widgets.console_command_finished(term.console)
    return was_ready
}

// Stops the shell and frees the terminal, leaving its widget to whoever owns the
// tree. Shutdown uses this: the console widget dies with the root.
thor_terminal_release :: proc(term: ^Terminal) {
    thor_terminal_close_session(term)
    delete(term.pending)
    delete(term.carry)
    delete(term.token)
    delete(term.end_cmd)
    free(term)
}

thor_terminal_apply_theme :: proc(thor: ^Thor, term: ^Terminal) {
    t := thor.theme
    widgets.console_set_colors(term.console, t.foreground, t.accent_color, t.second_background, t.accent_color)
    widgets.console_set_link_color(term.console, t.info_color)
}

// One entry of the shell menu, so a menu item knows which shell it names.
Shell_Choice :: struct {
    thor:  ^Thor,
    index: int,
}

// Async shell detection: the scan runs vswhere, reads the registry and walks
// PATH, which is too slow for the frame that starts the editor.
Shell_Detect_Job :: struct {
    owner:     ^Thor,
    allocator: runtime.Allocator,
    worker:    ^thread.Thread,
    profiles:  []shell.Profile, // owned, taken over by the main thread
}

// Starts the shell detection. Called once the widget tree exists, since the
// terminal it opens is a child of the console stack. The console panel stays
// empty until the scan lands, so `thor.console` is nil for the first frames.
thor_terminals_init :: proc(thor: ^Thor) {
    thor.terminals = make([dynamic]^Terminal)
    thor.terminals_live = true
    thor.active_terminal = -1

    job := new(Shell_Detect_Job)
    job.owner = thor
    job.allocator = context.allocator

    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, shell_detect_worker)
}

@(private = "file")
shell_detect_worker :: proc(job: ^Shell_Detect_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    job.profiles = shell.profiles_detect()

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_shells, job)
    sync.unlock(&job.owner.io_mutex)
}

// Drains a finished detection (called from thor_process_io): takes over the
// profiles and opens the first terminal.
thor_apply_shell_profiles :: proc(thor: ^Thor, job: ^Shell_Detect_Job) {
    thread.join(job.worker)
    thread.destroy(job.worker)
    profiles := job.profiles
    free(job)
    thor.inflight_jobs -= 1

    // Shutdown drains what is still in flight; there is no console left to fill.
    if !thor.terminals_live {
        shell.profiles_destroy(profiles)
        return
    }

    thor.shell_profiles = profiles
    thor.shell_choices = make([]Shell_Choice, len(profiles))
    for &choice, i in thor.shell_choices {
        choice = {thor, i}
    }
    if len(profiles) == 0 {
        log.warn("No shell found; the console has no terminal")
        return
    }
    // No focus: startup belongs to the editor.
    thor_terminal_open(thor, thor_terminal_default_profile(thor), focus = false)
    if thor.console != nil && strings.builder_len(thor.console_backlog) > 0 {
        widgets.console_append(thor.console, strings.to_string(thor.console_backlog))
        strings.builder_reset(&thor.console_backlog)
    }
}

// The configured shell, or the best one detected when it names a shell this
// machine does not have.
@(private = "file")
thor_terminal_default_profile :: proc(thor: ^Thor) -> shell.Profile {
    if id := setting.default_shell(&thor.config); id != "" {
        if profile, ok := shell.profile_find(thor.shell_profiles, id); ok {
            return profile
        }
        log.warnf("Configured shell %q is not installed; using %s", id, thor.shell_profiles[0].name)
    }
    return thor.shell_profiles[0]
}

// Opens a terminal on `profile` and makes it the active one.
thor_terminal_open :: proc(thor: ^Thor, profile: shell.Profile, focus := true) {
    term := thor_terminal_create(thor, profile)
    append(&thor.terminals, term)
    widgets.append_child(&thor.console_stack.widget, &term.console.widget)
    thor_terminal_select(thor, len(thor.terminals) - 1, focus)
}

// Shows the terminal at `index` and hides the others. An out-of-range index
// leaves the console panel empty, which is what a closed last tab means.
thor_terminal_select :: proc(thor: ^Thor, index: int, focus := true) {
    thor.active_terminal = index >= 0 && index < len(thor.terminals) ? index : -1
    for term, i in thor.terminals {
        term.console.visible = i == thor.active_terminal
    }
    thor.console = thor.active_terminal >= 0 ? thor.terminals[thor.active_terminal].console : nil
    if focus && thor.console != nil {
        thor.ui_context.focused = &thor.console.widget
    }
}

// Ends the terminal at `index` and drops its tab.
thor_terminal_close :: proc(thor: ^Thor, index: int) {
    if index < 0 || index >= len(thor.terminals) {
        return
    }
    term := thor.terminals[index]
    ordered_remove(&thor.terminals, index)

    ui.context_forget(&thor.ui_context, &term.console.widget)
    ui.widget_remove_child(&term.console.widget)
    ui.widget_destroy_tree(&term.console.widget)
    thor_terminal_release(term)

    thor_terminal_select(thor, min(index, len(thor.terminals) - 1))
}

// The terminal the user is typing in, or nil when the last tab is closed.
thor_active_terminal :: proc(thor: ^Thor) -> ^Terminal {
    if thor.active_terminal < 0 || thor.active_terminal >= len(thor.terminals) {
        return nil
    }
    return thor.terminals[thor.active_terminal]
}

// Moves every terminal's output into its scrollback. A finished command may have
// touched the working tree, so the git status is refreshed once for the frame.
thor_process_terminals :: proc(thor: ^Thor) {
    finished := false
    for term in thor.terminals {
        finished |= thor_terminal_pump(term)
    }
    if finished {
        thor_refresh_git_status(thor)
    }
}

// Ends every shell. The console widgets belong to the widget tree, which is
// destroyed with the root.
thor_terminals_shutdown :: proc(thor: ^Thor) {
    for term in thor.terminals {
        thor_terminal_release(term)
    }
    delete(thor.terminals)
    delete(thor.shell_choices)
    shell.profiles_destroy(thor.shell_profiles)
    // Draining the I/O queue still pumps the terminals, so leave nothing to walk.
    thor.terminals = nil
    thor.terminals_live = false
    thor.shell_choices = nil
    thor.shell_profiles = nil
    thor.console = nil
    thor.active_terminal = -1
}

// Tabstrip_Add_Proc: opens the list of installed shells under the add button;
// picking one opens a terminal on it.
thor_terminal_tab_add :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if len(thor.shell_profiles) == 0 {
        return
    }
    widgets.menu_clear(thor.menu)
    for profile, i in thor.shell_profiles {
        widgets.menu_add(thor.menu, profile.name, thor_menu_open_shell, &thor.shell_choices[i])
    }
    anchor := widgets.tabstrip_add_bounds(thor.terminal_tabs)
    widgets.menu_open(thor.menu, &thor.ui_context, {anchor.x, anchor.y + anchor.height})
}

@(private = "file")
thor_menu_open_shell :: proc(data: rawptr) {
    choice := cast(^Shell_Choice) data
    thor_terminal_open(choice.thor, choice.thor.shell_profiles[choice.index])
}

// Tabbar_Count_Proc
thor_terminal_tab_count :: proc(data: rawptr) -> int {
    return len((cast(^Thor) data).terminals)
}

// Tabbar_Info_Proc: the shell's name, numbered when several tabs run the same
// shell, and a busy mark while a command runs.
thor_terminal_tab_info :: proc(data: rawptr, index: int) -> widgets.Tab_Info {
    thor := cast(^Thor) data
    if index < 0 || index >= len(thor.terminals) {
        return {}
    }
    term := thor.terminals[index]

    ordinal, total := 0, 0
    for other, i in thor.terminals {
        if other.profile.id != term.profile.id {
            continue
        }
        total += 1
        if i <= index {
            ordinal = total
        }
    }

    name := term.profile.name
    if total > 1 {
        name = fmt.tprintf("%s %d", name, ordinal)
    }
    return {name = name, loading = term.running, modified = term.dead}
}

// Tabbar_Active_Proc
thor_terminal_tab_active :: proc(data: rawptr) -> int {
    return (cast(^Thor) data).active_terminal
}

// Tabbar_Action_Proc
thor_terminal_tab_select :: proc(data: rawptr, index: int) {
    thor_terminal_select(cast(^Thor) data, index)
}

// Tabbar_Action_Proc
thor_terminal_tab_close :: proc(data: rawptr, index: int) {
    thor_terminal_close(cast(^Thor) data, index)
}

// Reveals the console panel, so a terminal command is visible when it acts.
@(private = "file")
thor_show_console :: proc(thor: ^Thor) {
    if !ui.signal_get(&thor.console_visible) {
        ui.signal_set(&thor.console_visible, true)
    }
}

thor_cmd_new_terminal :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if len(thor.shell_profiles) == 0 {
        thor_flash_status(thor, "No shell was found", true)
        return
    }
    thor_show_console(thor)
    thor_terminal_open(thor, thor_terminal_default_profile(thor))
}

thor_cmd_close_terminal :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_terminal_close(thor, thor.active_terminal)
}

thor_cmd_close_all_terminals :: proc(data: rawptr) {
    thor := cast(^Thor) data
    for len(thor.terminals) > 0 {
        thor_terminal_close(thor, 0)
    }
}

thor_cmd_next_terminal :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if len(thor.terminals) < 2 {
        return
    }
    thor_show_console(thor)
    thor_terminal_select(thor, (thor.active_terminal + 1) % len(thor.terminals))
}

thor_cmd_restart_shell :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if term := thor_active_terminal(thor); term != nil {
        thor_terminal_restart(term)
    }
}

// Picks the shell new terminals start on, and opens one on it right away.
thor_cmd_select_shell :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if len(thor.shell_profiles) == 0 {
        thor_flash_status(thor, "No shell was found", true)
        return
    }
    labels := make([]string, len(thor.shell_profiles), context.temp_allocator)
    ids := make([]string, len(thor.shell_profiles), context.temp_allocator)
    for profile, i in thor.shell_profiles {
        labels[i] = profile.name
        ids[i] = profile.id
    }
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Select Shell", labels, thor_terminal_default_profile(thor).name,
        thor_shell_preview, thor_shell_commit, thor, ids,
    )
}

// Select_Choice_Proc: nothing to preview, since a shell only starts on commit.
@(private = "file")
thor_shell_preview :: proc(data: rawptr, choice: string) {
}

// Select_Choice_Proc: stores the shell as the default and opens a terminal on it.
@(private = "file")
thor_shell_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    profile, ok := shell.profile_find(thor.shell_profiles, choice)
    if !ok {
        return
    }
    if !setting.persist_string(thor_active_settings_path(thor), "default_shell", choice) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return
    }
    thor_reload_settings(thor)
    thor_show_console(thor)
    thor_terminal_open(thor, profile)
}
