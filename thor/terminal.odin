package thor

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

import "../setting"
import "../shell"
import "../vt"

// One console bound to one shell on a pseudo-terminal. The shell outlives the
// commands run in it, so a `cd` sticks and a developer environment loaded once
// stays loaded; a reader thread pushes its output into `pending` and the main
// thread feeds that to the emulator.
Terminal :: struct {
    owner:     ^Thor,
    console:   Console,        // owned; declared by the console panel while this tab is active
    profile:   shell.Profile,  // borrowed from owner.shell_profiles
    pty:       ^shell.Pty,     // owned; nil once the shell is gone
    reader:    ^thread.Thread, // owned
    allocator: runtime.Allocator,
    // Raw shell output the reader has not handed over. Guarded by owner.io_mutex.
    pending:   [dynamic]u8,
    // The reader reached the end of the stream. Guarded by owner.io_mutex.
    ended:     bool,
    // The shell exited and was reported; the tab keeps its scrollback.
    dead:      bool,
    // When the output that just arrived is taken to have settled. A command that
    // finished may have touched the working tree, and most shells say nothing
    // about it, so the pause after the output is the signal.
    settle_at: f64,
}

@(private = "file")
READ_BUFFER :: 8192

// How long the output must be quiet before a command counts as finished.
@(private = "file")
SETTLE_DELAY :: 0.35

// Starts a terminal on `profile` in the workspace directory. Returns a terminal
// whose shell is marked dead when it does not start.
thor_terminal_create :: proc(thor: ^Thor, profile: shell.Profile) -> ^Terminal {
    term := new(Terminal)
    term.owner = thor
    term.profile = profile
    term.allocator = context.allocator
    term.pending = make([dynamic]u8)

    thor_console_init(&term.console)
    thor_console_apply_theme(thor, &term.console)
    thor_console_set_on_link(&term.console, thor_console_link, thor_console_activate, thor)
    thor_console_set_on_write(
        &term.console,
        thor_terminal_write,
        thor_terminal_resize,
        term,
    )

    if !thor_terminal_open_session(term) {
        thor_console_append(&term.console, fmt.tprintf("Could not start %s.\n", profile.name))
        term.dead = true
    }
    return term
}

// Starts the shell and its reader thread, then types the profile's init
// commands — the one a developer prompt loads its environment with.
@(private = "file")
thor_terminal_open_session :: proc(term: ^Terminal) -> bool {
    pty, ok := shell.pty_start(
        term.profile,
        term.owner.workspace_dir,
        term.console.cols,
        term.console.rows,
    )
    if !ok {
        return false
    }
    term.pty = pty
    term.ended = false
    term.dead = false

    term.reader = thread.create_and_start_with_poly_data(term, thor_terminal_reader)
    for command in term.profile.init {
        shell.pty_write(term.pty, command)
        shell.pty_write(term.pty, "\r")
    }
    return true
}

// Reader thread: hands raw output to the main thread and stops at the end of the
// stream, which is where the shell exited.
@(private = "file")
thor_terminal_reader :: proc(term: ^Terminal) {
    context.allocator = term.allocator
    buf: [READ_BUFFER]u8
    for {
        read := shell.pty_read(term.pty, buf[:])
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

// Console_Write_Proc: everything the user types, and every answer the emulator
// owes the shell.
thor_terminal_write :: proc(data: rawptr, bytes: string) {
    term := cast(^Terminal) data
    if term.pty == nil {
        return
    }
    shell.pty_write(term.pty, bytes)
}

// Console_Resize_Proc: the panel changed size, so the shell re-wraps and a
// full-screen program redraws.
thor_terminal_resize :: proc(data: rawptr, cols, rows: int) {
    term := cast(^Terminal) data
    if term.pty == nil {
        return
    }
    shell.pty_resize(term.pty, cols, rows)
}

// Ends the shell and starts a fresh one on the same profile, keeping the
// scrollback.
thor_terminal_restart :: proc(term: ^Terminal) {
    thor_terminal_close_session(term)
    thor_console_append(&term.console, "\n")
    if !thor_terminal_open_session(term) {
        thor_console_append(
            &term.console,
            fmt.tprintf("Could not start %s.\n", term.profile.name),
        )
        term.dead = true
    }
}

// Stops the shell and joins the reader. Output the reader already handed over is
// dropped: it belongs to a session that is gone.
@(private = "file")
thor_terminal_close_session :: proc(term: ^Terminal) {
    if term.pty == nil {
        return
    }
    shell.pty_terminate(term.pty)
    if term.reader != nil {
        thread.join(term.reader)
        thread.destroy(term.reader)
        term.reader = nil
    }
    shell.pty_destroy(term.pty)
    term.pty = nil
    sync.lock(&term.owner.io_mutex)
    clear(&term.pending)
    term.ended = false
    sync.unlock(&term.owner.io_mutex)
}

// Moves one frame of shell output into the emulator and writes back whatever it
// answers. Returns whether a command finished, which is when the working tree
// may have changed.
thor_terminal_pump :: proc(term: ^Terminal) -> bool {
    if term.console.term == nil {
        return false
    }
    sync.lock(&term.owner.io_mutex)
    chunk: []u8
    if len(term.pending) > 0 {
        data := make([]u8, len(term.pending), context.temp_allocator)
        copy(data, term.pending[:])
        clear(&term.pending)
        chunk = data
    }
    ended := term.ended
    sync.unlock(&term.owner.io_mutex)

    now := rl.GetTime()
    if len(chunk) > 0 {
        thor_console_feed(&term.console, chunk)
        term.settle_at = now + SETTLE_DELAY
    }

    finished := false
    // The shell integration mark is the exact answer where a shell sends one.
    if _, ok := vt.term_take_command_end(term.console.term); ok {
        finished = true
        term.settle_at = 0
    }
    if term.settle_at != 0 && now >= term.settle_at {
        term.settle_at = 0
        finished = true
    }

    thor_terminal_drain_replies(term)

    if ended && !term.dead {
        term.dead = true
        thor_console_append(&term.console, "\n[the shell exited]\n")
    }
    return finished
}

// What the emulator owes the outside world: a device report back to the shell,
// and the text an OSC 52 asked to put on the clipboard.
@(private = "file")
thor_terminal_drain_replies :: proc(term: ^Terminal) {
    t := term.console.term
    if t == nil {
        return
    }
    if pending := vt.term_take_reply(t); len(pending) > 0 {
        if term.pty != nil {
            shell.pty_write(term.pty, string(pending))
        }
        vt.term_clear_reply(t)
    }
    if text, ok := vt.term_take_clipboard(t); ok && text != "" {
        rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
    }
    // The bell is read so it cannot pile up; the editor does not ring.
    vt.term_take_bell(t)
}

// Stops the shell and frees the terminal, the emulator and its scrollback with
// it.
thor_terminal_release :: proc(term: ^Terminal) {
    thor_terminal_close_session(term)
    thor_console_destroy(&term.console)
    delete(term.pending)
    free(term)
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
// empty until the scan lands, so there is no console for the first frames.
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
    if console := thor_active_console(thor);
       console != nil && strings.builder_len(thor.console_backlog) > 0 {
        thor_console_append(console, strings.to_string(thor.console_backlog))
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
    thor_terminal_select(thor, len(thor.terminals) - 1, focus)
}

// Makes the terminal at `index` the one the console panel declares. An
// out-of-range index leaves the panel empty, which is what a closed last tab
// means.
thor_terminal_select :: proc(thor: ^Thor, index: int, focus := true) {
    thor.active_terminal = index >= 0 && index < len(thor.terminals) ? index : -1
    if focus && thor_active_console(thor) != nil {
        thor.focus_request = "console"
        thor_active_console(thor).focus_pending = true
    }
}

// The active tab's console, or nil when the last terminal is closed. Every user
// of it needs the nil guard.
thor_active_console :: proc(thor: ^Thor) -> ^Console {
    if term := thor_active_terminal(thor); term != nil {
        return &term.console
    }
    return nil
}

// Ends the terminal at `index` and drops its tab.
thor_terminal_close :: proc(thor: ^Thor, index: int) {
    if index < 0 || index >= len(thor.terminals) {
        return
    }
    term := thor.terminals[index]
    ordered_remove(&thor.terminals, index)

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

// Moves every terminal's output into its emulator. A finished command may have
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

// Re-seeds every terminal's colours after the theme changed.
thor_terminals_apply_theme :: proc(thor: ^Thor) {
    for term in thor.terminals {
        thor_console_apply_theme(thor, &term.console)
    }
}

// Ends every shell. A terminal owns its console, so releasing it frees the
// scrollback with it.
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
    thor.active_terminal = -1
}

// Tabstrip_Add_Proc: opens the list of installed shells under the add button;
// picking one opens a terminal on it.
thor_terminal_tab_add :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if len(thor.shell_profiles) == 0 {
        return
    }
    thor_menu_clear(thor)
    for profile, i in thor.shell_profiles {
        thor_menu_add(thor, profile.name, thor_menu_open_shell, &thor.shell_choices[i])
    }
    thor_menu_open(thor, thor.menu_anchor)
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
// shell. The tooltip carries whatever title the shell set for itself.
thor_terminal_tab_info :: proc(data: rawptr, index: int) -> Tab_Info {
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
    tooltip := term.profile.name
    switch {
    case term.dead:
        tooltip = fmt.tprintf("%s\nThe shell has stopped", term.profile.name)
    case term.console.term != nil && term.console.term.title != "":
        tooltip = fmt.tprintf("%s\n%s", term.profile.name, term.console.term.title)
    }
    return {name = name, tooltip = tooltip, modified = term.dead}
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
    if !signal_get(&thor.console_visible) {
        signal_set(&thor.console_visible, true)
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
    thor_select_open(
        thor,
        "Select Shell",
        labels,
        thor_terminal_default_profile(thor).name,
        thor_shell_preview,
        thor_shell_commit,
        thor,
        ids,
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
