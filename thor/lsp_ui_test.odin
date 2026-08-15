package thor

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

import "../lang/lsp"

// The editor's half of the language-server panel: the rule that decides which
// state change is worth a notice, and the lsp.json writer behind "Add a
// Server...". Run from the repository root: odin test thor

// The log lands beside the binary, in the directory Thor writes to — not in the
// folder it was launched from, which is where the working directory still points
// when the logger is made.
@(test)
test_log_file_path_is_under_user :: proc(t: ^testing.T) {
    path := log_file_path(context.temp_allocator)
    testing.expect(t, strings.has_suffix(path, LOG_FILE), "the log is not named thor.log")
    testing.expect(t, strings.contains(path, "user"), "the log is not under user/")
    testing.expect(t, len(path) > len("user/") + len(LOG_FILE), "the path was not resolved against the binary")
}

// The loggers are made and freed from one allocator, since the caller installs a
// tracking allocator between the two calls.
@(test)
test_log_init_round_trips :: proc(t: ^testing.T) {
    state := log_init(.Info)
    testing.expect(t, state.logger.procedure != nil, "no logger was made")
    log_destroy(state)
}

// A state that did not change says nothing, and neither does an ordinary start.
@(test)
test_lsp_health_flash_stays_quiet :: proc(t: ^testing.T) {
    quiet := [][2]lsp.Server_State {
        {.Idle, .Idle},
        {.Ready, .Ready},
        {.Idle, .Starting},
        {.Starting, .Ready},
        {.Ready, .Stopping},
    }
    for pair in quiet {
        _, _, say := thor_lsp_health_flash(pair[0], pair[1])
        testing.expectf(t, !say, "%v -> %v was reported", pair[0], pair[1])
    }
}

// The three changes the user has to know about, and the recovery that closes
// them off.
@(test)
test_lsp_health_flash_reports_failures :: proc(t: ^testing.T) {
    message, is_error, say := thor_lsp_health_flash(.Starting, .Failed)
    testing.expect(t, say, "a server that did not start must be reported")
    testing.expect(t, is_error, "a failed start is an error")
    testing.expect(t, strings.contains(message, "%s"), "the message names the server")

    message, is_error, say = thor_lsp_health_flash(.Ready, .Crashed)
    testing.expect(t, say && is_error, "a crash must be reported")
    testing.expect(t, strings.contains(message, "restarting"), "a crash says it is coming back")

    message, is_error, say = thor_lsp_health_flash(.Crashed, .Failed)
    testing.expect(t, say && is_error, "giving up must be reported")
    testing.expect(t, strings.contains(message, "not be started again"), "giving up says so")

    message, is_error, say = thor_lsp_health_flash(.Crashed, .Ready)
    testing.expect(t, say, "coming back must be reported")
    testing.expect(t, !is_error, "coming back is not an error")
}

// The writer adds an entry, keeps the entries already there, and answers an id
// the file already names without writing it twice.
@(test)
test_lsp_append_server_writes_and_dedupes :: proc(t: ^testing.T) {
    PATH :: "thor_lsp_append.tmp"
    defer os.remove(PATH)

    testing.expect(t, thor_lsp_append_server(PATH, "ruff"), "the first write failed")
    first, rerr := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect(t, rerr == nil, "the file was not written")
    testing.expect(t, strings.contains(string(first), `"ruff"`), "the id did not land")
    testing.expect(t, strings.contains(string(first), `"servers"`), "the servers array is missing")

    testing.expect(t, thor_lsp_append_server(PATH, "gopls"), "the second write failed")
    second, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect(t, strings.contains(string(second), `"ruff"`), "the first entry was dropped")
    testing.expect(t, strings.contains(string(second), `"gopls"`), "the second entry did not land")

    testing.expect(t, thor_lsp_append_server(PATH, "ruff"), "a known id must not be an error")
    third, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, strings.count(string(third), `"ruff"`), 1)
}

// A file that will not parse is left exactly as it is: it is the user's, and a
// syntax error is not a reason to lose what is in it.
@(test)
test_lsp_append_server_keeps_a_broken_file :: proc(t: ^testing.T) {
    PATH :: "thor_lsp_broken.tmp"
    defer os.remove(PATH)

    BROKEN :: `{"servers": [`
    testing.expect(t, os.write_entire_file(PATH, transmute([]u8) string(BROKEN)) == nil, "the fixture was not written")
    testing.expect(t, !thor_lsp_append_server(PATH, "ruff"), "a broken file must not be written to")

    after, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, string(after), BROKEN)
}

// The skeleton names every key the user then has to fill in, and it parses.
@(test)
test_lsp_append_server_writes_a_skeleton :: proc(t: ^testing.T) {
    PATH :: "thor_lsp_skeleton.tmp"
    defer os.remove(PATH)

    testing.expect(t, thor_lsp_append_server(PATH, "ruff"), "the write failed")
    data, rerr := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect(t, rerr == nil)

    text := string(data)
    for key in ([?]string{`"id"`, `"extensions"`, `"command"`, `"root_markers"`, `"enabled"`}) {
        testing.expectf(t, strings.contains(text, key), "the skeleton has no %s", key)
    }

    value, perr := json.parse(data, spec = .JSON, allocator = context.temp_allocator)
    testing.expectf(t, perr == .None, "the written file does not parse: %v", perr)
    root, ok := value.(json.Object)
    testing.expect(t, ok, "the written file is not a JSON object")
    if ok {
        _, has_servers := root["servers"].(json.Array)
        testing.expect(t, has_servers, `the written file has no "servers" array`)
    }
}
