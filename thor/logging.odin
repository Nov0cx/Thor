package thor

import "base:runtime"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../setting"

// Where log output goes. A release build links the windows subsystem and starts
// with no console, so without a file every warning — a language server that did
// not start, a config file that will not parse — reaches nobody.

// Beside the binary, in the one directory Thor owns and writes to. Truncated at
// every start: what matters is the session that just went wrong.
LOG_FILE :: "thor.log"

// The loggers a run holds. `to_file` is false when the file could not be opened,
// which leaves the console logger alone rather than failing the start.
Log_State :: struct {
    logger:  log.Logger, // what to put in the context
    console: log.Logger,
    file:    log.Logger,
    to_file: bool,
    // The allocator the loggers were made from, kept because the caller installs
    // a tracking allocator after this and tears it down before the free.
    allocator: runtime.Allocator,
}

// The log path, resolved against the executable and not the working directory:
// the move to the exe directory happens inside `init`, and the logger is made
// before that.
log_file_path :: proc(allocator := context.allocator) -> string {
    dir := setting.USER_DIR
    if exe, err := os.get_executable_path(context.temp_allocator); err == nil {
        if joined, jerr := filepath.join({os.dir(exe), setting.USER_DIR}, context.temp_allocator); jerr == nil {
            dir = joined
        }
    }
    path, jerr := filepath.join({dir, LOG_FILE}, allocator)
    if jerr != nil {
        return strings.clone(LOG_FILE, allocator)
    }
    return path
}

// The console logger, and a file logger beside it when the file opens.
log_init :: proc(lowest: log.Level, allocator := context.allocator) -> Log_State {
    state := Log_State {
        console   = log.create_console_logger(lowest, {.Level, .Terminal_Color}, allocator = allocator),
        allocator = allocator,
    }
    state.logger = state.console

    path := log_file_path(context.temp_allocator)
    // user/ does not exist until the first write to it.
    if dir := filepath.dir(path); dir != "" && !os.is_dir(dir) {
        if err := os.make_directory(dir); err != nil && !os.is_dir(dir) {
            return state
        }
    }
    handle, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
    if err != nil {
        return state
    }
    state.file = log.create_file_logger(handle, lowest, allocator = allocator)
    state.to_file = true
    state.logger = log.create_multi_logger(state.console, state.file, allocator = allocator)
    return state
}

// Frees what log_init made. destroy_file_logger closes the file itself.
log_destroy :: proc(state: Log_State) {
    if state.to_file {
        log.destroy_multi_logger(state.logger, state.allocator)
        log.destroy_file_logger(state.file, state.allocator)
    }
    log.destroy_console_logger(state.console, state.allocator)
}
