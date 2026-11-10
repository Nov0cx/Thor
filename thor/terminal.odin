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
import "../lockfree"
import "../prof"

// One console bound to one shell on a pseudo-terminal. The shell outlives the
// commands run in it, so a `cd` sticks and a developer environment loaded once
// stays loaded; a reader thread pushes its output into `pending` and the main
// thread feeds that to the emulator.
Terminal :: struct {
    owner:     ^Thor,
    console:   Console,        // owned; declared by the console panel while this tab is active
    profile:   shell.Profile,  // borrowed from owner.shell_profiles
    task:      string,         // owned; the task this tab runs, "" for a user shell
    // Owned; set by the reader once the shell runs, nil once it is gone. Guarded by out_mutex.
    pty:       ^shell.Pty,
    // The reader and writer threads run. Main thread only.
    session:   bool,
    // The directory the shell starts in; owned. Read by the reader before it starts the shell.
    start_cwd: string,
    // The shell could not start. Atomic; set before `ended`.
    start_failed: bool,
    // The grid size the shell must have. Guarded by out_mutex.
    want_cols: int,
    want_rows: int,
    reader:    ^thread.Thread, // owned
    allocator: runtime.Allocator,
    // Raw shell output the reader has not handed over. The reader writes, the main thread reads.
    output:    lockfree.Byte_Ring, // owned
    // The reader reached the end of the stream. Atomic; set after its last write to `output`.
    ended:     bool,
    // The session closes; a reader that waits for room in `output` gives up. Atomic.
    closing:   bool,
    // The shell exited and was reported; the tab keeps its scrollback.
    dead:      bool,
    // Bytes for the shell, written by `writer`. Guarded by out_mutex.
    outbox:    [dynamic]u8,
    // The bytes the writer is sending. Owned by the writer between swaps.
    sending:   [dynamic]u8,
    writer:    ^thread.Thread, // owned
    out_mutex: sync.Mutex,
    out_cond:  sync.Cond,
    // The writer must stop. Guarded by out_mutex.
    out_stop:  bool,
    // The writer could not write to the shell. Atomic.
    write_error: bool,
    // A write to the shell failed and was logged; one log line per session.
    write_failed: bool,
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

// Most bytes queued for a shell that does not read. A larger paste is refused.
@(private = "file")
TERMINAL_OUTBOX_MAX :: 16 * 1024 * 1024

// Starts a terminal on `profile` in the workspace directory. Returns a terminal
// whose shell is marked dead when it does not start.
thor_terminal_create :: proc(thor: ^Thor, profile: shell.Profile) -> ^Terminal {
    term := new(Terminal)
    term.owner = thor
    term.profile = profile
    term.allocator = context.allocator
    term.outbox = make([dynamic]u8)
    term.sending = make([dynamic]u8)

    thor_console_init(&term.console, cast(i32) setting.font_size(&thor.config))
    thor_console_apply_theme(thor, &term.console)
    thor_console_set_on_link(&term.console, thor_console_link, thor_console_activate, thor)
    thor_console_set_on_write(
        &term.console,
        thor_terminal_write,
        thor_terminal_resize,
        term,
    )

    if !lockfree.ring_init(&term.output, TERMINAL_RING_SIZE) {
        thor_console_append(&term.console, fmt.tprintf("Could not start %s.\n", profile.name))
        term.dead = true
        return term
    }
    if !thor_terminal_open_session(term) {
        thor_console_append(&term.console, fmt.tprintf("Could not start %s.\n", profile.name))
        term.dead = true
    }
    return term
}

// Starts the reader thread, which starts the shell, and the writer thread, then
// queues the profile's init commands — the one a developer prompt loads its
// environment with. The shell starts off the frame: a pseudo-console and a
// process cost tens of milliseconds. False when a thread does not start.
@(private = "file")
thor_terminal_open_session :: proc(term: ^Terminal) -> bool {
    sync.atomic_store(&term.ended, false)
    sync.atomic_store(&term.closing, false)
    sync.atomic_store(&term.start_failed, false)
    term.dead = false
    term.write_failed = false
    sync.atomic_store(&term.write_error, false)
    delete(term.start_cwd)
    term.start_cwd = strings.clone(term.owner.workspace_dir)
    sync.lock(&term.out_mutex)
    term.out_stop = false
    term.want_cols = term.console.cols
    term.want_rows = term.console.rows
    clear(&term.outbox)
    sync.unlock(&term.out_mutex)

    term.reader = thread.create_and_start_with_poly_data(term, thor_terminal_reader)
    if term.reader == nil {
        return false
    }
    term.session = true
    term.writer = thread.create_and_start_with_poly_data(term, thor_terminal_writer)
    if term.writer == nil {
        thor_terminal_close_session(term)
        return false
    }
    for command in term.profile.init {
        thor_terminal_send(term, command)
        thor_terminal_send(term, "\r")
    }
    return true
}

// Writer thread: sends the queued bytes to the shell, so a shell that does not
// read blocks this thread and not the frame.
@(private = "file")
thor_terminal_writer :: proc(term: ^Terminal) {
    for {
        sync.lock(&term.out_mutex)
        // Bytes queued while the shell starts wait for it.
        for (len(term.outbox) == 0 || term.pty == nil) && !term.out_stop {
            sync.wait(&term.out_cond, &term.out_mutex)
        }
        if term.out_stop {
            sync.unlock(&term.out_mutex)
            return
        }
        term.outbox, term.sending = term.sending, term.outbox
        pty := term.pty
        sync.unlock(&term.out_mutex)

        if !shell.pty_write(pty, string(term.sending[:])) {
            sync.atomic_store(&term.write_error, true)
        }
        clear(&term.sending)
    }
}

// Reader thread: hands raw output to the main thread and stops at the end of the
// stream, which is where the shell exited.
@(private = "file")
thor_terminal_reader :: proc(term: ^Terminal) {
    context.allocator = term.allocator
    pty := thor_terminal_start_shell(term)
    if pty == nil {
        sync.atomic_store(&term.ended, true)
        return
    }
    buf: [READ_BUFFER]u8
    for {
        read := shell.pty_read(pty, buf[:])
        if read <= 0 {
            break
        }
        // A full ring waits for the main thread, so a flood blocks the shell on its write.
        rest := buf[:read]
        for len(rest) > 0 && !sync.atomic_load(&term.closing) {
            gen := lockfree.ring_space_gen(&term.output)
            wrote := lockfree.ring_write(&term.output, rest)
            rest = rest[wrote:]
            if wrote == 0 && !sync.atomic_load(&term.closing) {
                lockfree.ring_wait_space(&term.output, gen)
            }
        }
    }
    sync.atomic_store(&term.ended, true)
}

// Starts the shell on the reader thread and publishes it, or nil when it does not
// start or the session closed first. A close that comes first never sees the
// shell, so the shell is ended here.
@(private = "file")
thor_terminal_start_shell :: proc(term: ^Terminal) -> ^shell.Pty {
    sync.lock(&term.out_mutex)
    cols, rows := term.want_cols, term.want_rows
    sync.unlock(&term.out_mutex)
    pty, ok := shell.pty_start(term.profile, term.start_cwd, cols, rows)
    if !ok {
        sync.atomic_store(&term.start_failed, true)
        return nil
    }

    sync.lock(&term.out_mutex)
    if term.out_stop {
        sync.unlock(&term.out_mutex)
        shell.pty_terminate(pty)
        shell.pty_destroy(pty)
        return nil
    }
    term.pty = pty
    // The panel changed size while the shell started.
    if (term.want_cols != cols || term.want_rows != rows) && !shell.pty_resize(pty, term.want_cols, term.want_rows) {
        log.warnf("Could not resize the %s terminal to %dx%d", term.profile.name, term.want_cols, term.want_rows)
    }
    sync.unlock(&term.out_mutex)
    sync.signal(&term.out_cond)
    return pty
}

// Console_Write_Proc: everything the user types, and every answer the emulator
// owes the shell.
thor_terminal_write :: proc(data: rawptr, bytes: string) {
    term := cast(^Terminal) data
    if !term.session {
        return
    }
    thor_terminal_send(term, bytes)
}

// Queues `bytes` for the writer thread. Bytes past TERMINAL_OUTBOX_MAX are refused.
@(private = "file")
thor_terminal_send :: proc(term: ^Terminal, bytes: string) {
    if len(bytes) == 0 {
        return
    }
    sync.lock(&term.out_mutex)
    queued := len(term.outbox) + len(bytes) <= TERMINAL_OUTBOX_MAX
    if queued {
        _, err := append(&term.outbox, ..transmute([]u8)bytes)
        queued = err == nil
    }
    sync.unlock(&term.out_mutex)
    if !queued {
        log.warnf("The %s shell does not read its input; %d bytes were not sent", term.profile.name, len(bytes))
        return
    }
    sync.signal(&term.out_cond)
}

// Console_Resize_Proc: the panel changed size, so the shell re-wraps and a
// full-screen program redraws.
thor_terminal_resize :: proc(data: rawptr, cols, rows: int) {
    term := cast(^Terminal) data
    if !term.session {
        return
    }
    // A shell that still starts takes the size when it is published.
    sync.lock(&term.out_mutex)
    defer sync.unlock(&term.out_mutex)
    term.want_cols, term.want_rows = cols, rows
    if term.pty != nil && !shell.pty_resize(term.pty, cols, rows) {
        log.warnf("Could not resize the %s terminal to %dx%d", term.profile.name, cols, rows)
    }
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
    if !term.session {
        return
    }
    term.session = false
    // After out_stop is set, a reader that still starts the shell ends it itself.
    sync.lock(&term.out_mutex)
    term.out_stop = true
    pty := term.pty
    sync.unlock(&term.out_mutex)
    sync.signal(&term.out_cond)
    sync.atomic_store(&term.closing, true)
    lockfree.ring_wake(&term.output)
    // Also ends a write the writer blocks in.
    if pty != nil {
        shell.pty_terminate(pty)
    }
    if term.reader != nil {
        thread.join(term.reader)
        thread.destroy(term.reader)
        term.reader = nil
    }
    if term.writer != nil {
        thread.join(term.writer)
        thread.destroy(term.writer)
        term.writer = nil
    }
    if pty != nil {
        shell.pty_destroy(pty)
    }
    term.pty = nil
    lockfree.ring_reset(&term.output)
    sync.atomic_store(&term.ended, false)
}

// Most shell output fed to the emulator in one frame, so a flood does not stall the frame.
TERMINAL_FEED_MAX :: 256 * 1024

// Bytes of shell output that may wait for the main thread. Past it the reader blocks.
@(private = "file")
TERMINAL_RING_SIZE :: 1024 * 1024

// Moves one frame of shell output into the emulator and writes back whatever it
// answers. Returns whether a command finished, which is when the working tree
// may have changed.
thor_terminal_pump :: proc(term: ^Terminal) -> bool {
    if term.console.term == nil {
        return false
    }
    // Loaded first: every byte written before the end is then in the ring.
    reader_done := sync.atomic_load(&term.ended)
    chunk: []u8
    if waiting := lockfree.ring_len(&term.output); waiting > 0 {
        data := make([]u8, min(waiting, TERMINAL_FEED_MAX), context.temp_allocator)
        chunk = data[:lockfree.ring_read(&term.output, data)]
    }
    // The shell is over only once its last output is fed.
    ended := reader_done && lockfree.ring_len(&term.output) == 0

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

    if !term.write_failed && sync.atomic_load(&term.write_error) {
        term.write_failed = true
        log.warnf("Could not write to the %s shell", term.profile.name)
    }

    if ended && !term.dead {
        term.dead = true
        if sync.atomic_load(&term.start_failed) {
            thor_console_append(&term.console, fmt.tprintf("Could not start %s.\n", term.profile.name))
        } else {
            thor_console_append(&term.console, "\n[the shell exited]\n")
        }
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
        if term.session {
            thor_terminal_send(term, string(pending))
        }
        vt.term_clear_reply(t)
    }
    if text, ok := vt.term_take_clipboard(t); ok && text != "" && setting.terminal_clipboard(&term.owner.config) {
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
    lockfree.ring_destroy(&term.output)
    delete(term.outbox)
    delete(term.sending)
    delete(term.task)
    delete(term.start_cwd)
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
    queue_next: ^Shell_Detect_Job, // link in Thor.finished_shells
    owner:     ^Thor,
    allocator: runtime.Allocator,
    worker:    ^thread.Thread,
    profiles:  []shell.Profile, // owned, taken over by the main thread
}

// Starts the shell detection. Called once the widget tree exists, since the
// terminal it opens is a child of the console stack. The console panel stays
// empty until the scan lands, so there is no console for the first frames.
thor_terminals_init :: proc(thor: ^Thor) {
    prof.proc_scope()
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

    lockfree.stack_push(&job.owner.finished_shells, job)
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

// Opens a terminal on `profile` and makes it the active one. It takes the plugin
// output held while there was no terminal.
thor_terminal_open :: proc(thor: ^Thor, profile: shell.Profile, focus := true) {
    term := thor_terminal_create(thor, profile)
    append(&thor.terminals, term)
    thor_terminal_select(thor, len(thor.terminals) - 1, focus)
    if strings.builder_len(thor.console_backlog) > 0 {
        thor_console_append(&term.console, strings.to_string(thor.console_backlog))
        strings.builder_reset(&thor.console_backlog)
    }
}

// Runs `command` in the tab of the task `name` and selects that tab without
// focus. A tab of the task restarts first, which kills a run that still goes;
// else a new tab opens on the default shell. The profile init commands are
// queued first, so the command runs after them. False when the shell does not
// start. The caller checks that a shell profile exists.
thor_terminal_run_task :: proc(thor: ^Thor, name, command: string) -> bool {
    index := -1
    for term, i in thor.terminals {
        if term.task == name {
            index = i
            break
        }
    }
    if index >= 0 {
        thor_terminal_restart(thor.terminals[index])
    } else {
        thor_terminal_open(thor, thor_terminal_default_profile(thor), focus = false)
        index = len(thor.terminals) - 1
        thor.terminals[index].task = strings.clone(name)
    }
    thor_terminal_select(thor, index, focus = false)

    term := thor.terminals[index]
    if term.dead || !term.session {
        return false
    }
    return thor_console_run_command(&term.console, command)
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
// touched the working tree, so a rate-limited git refresh is requested.
thor_process_terminals :: proc(thor: ^Thor) {
    finished := false
    for term in thor.terminals {
        finished |= thor_terminal_pump(term)
    }
    if finished {
        thor.watch_git_dirty = true
    }
}

// Re-seeds every terminal's colours after the theme changed.
thor_terminals_apply_theme :: proc(thor: ^Thor) {
    for term in thor.terminals {
        thor_console_apply_theme(thor, &term.console)
    }
}

// Follows the font size setting. The grid refits on the next frame, which tells
// each shell its new size.
thor_terminals_apply_font :: proc(thor: ^Thor) {
    size := max(cast(i32) setting.font_size(&thor.config), 8)
    for term in thor.terminals {
        term.console.font_size = size
    }
}

// Starts every shell again in the workspace directory, keeping each tab and its
// scrollback. Opens the default shell when no tab is left.
thor_terminals_restart_all :: proc(thor: ^Thor) {
    if !thor.terminals_live {
        return
    }
    for term in thor.terminals {
        thor_terminal_restart(term)
    }
    if len(thor.terminals) == 0 && len(thor.shell_profiles) > 0 {
        thor_terminal_open(thor, thor_terminal_default_profile(thor), focus = false)
    }
}

// Ends every shell and drops every tab. The list stays for the next terminal.
thor_terminals_close_all :: proc(thor: ^Thor) {
    if !thor.terminals_live {
        return
    }
    for term in thor.terminals {
        thor_terminal_release(term)
    }
    clear(&thor.terminals)
    thor.active_terminal = -1
}

// Ends every shell. A terminal owns its console, so releasing it frees the
// scrollback with it.
thor_terminals_shutdown :: proc(thor: ^Thor) {
    prof.proc_scope()
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

// Opens the list of installed shells under the add button; picking one opens a
// terminal on it.
thor_terminal_tab_add :: proc(thor: ^Thor) {
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

thor_terminal_tab_count :: proc(thor: ^Thor) -> int {
    return len(thor.terminals)
}

// The task name for a task tab, else the shell's name, numbered when several
// user tabs run the same shell. The tooltip carries whatever title the shell set
// for itself.
thor_terminal_tab_info :: proc(thor: ^Thor, index: int) -> Tab_Info {
    if index < 0 || index >= len(thor.terminals) {
        return {}
    }
    term := thor.terminals[index]

    name := term.task
    if name == "" {
        ordinal, total := 0, 0
        for other, i in thor.terminals {
            if other.task != "" || other.profile.id != term.profile.id {
                continue
            }
            total += 1
            if i <= index {
                ordinal = total
            }
        }
        name = term.profile.name
        if total > 1 {
            name = fmt.tprintf("%s %d", name, ordinal)
        }
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

thor_terminal_tab_active :: proc(thor: ^Thor) -> int {
    return thor.active_terminal
}

thor_terminal_tab_select :: proc(thor: ^Thor, index: int) {
    thor_terminal_select(thor, index)
}

thor_terminal_tab_close :: proc(thor: ^Thor, index: int) {
    thor_terminal_close(thor, index)
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
    if err := setting.persist_string(thor_active_settings_path(thor), "default_shell", choice); err != .None {
        thor_settings_save_failed(thor, thor_active_settings_path(thor), err)
        return
    }
    thor_reload_settings(thor)
    thor_show_console(thor)
    thor_terminal_open(thor, profile)
}
