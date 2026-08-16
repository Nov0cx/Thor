package lsp

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

// Run from the repository root: odin test lang/lsp

// The merge of one or more config files, in the order a load applies them.
@(private = "file")
merge :: proc(texts: ..string) -> Config {
    return merge_in("", ..texts)
}

// The same, against a workspace root the ${workspace} variable can expand to.
@(private = "file")
merge_in :: proc(workspace: string, texts: ..string) -> Config {
    cfg := Config {
        servers   = make([dynamic]Server_Config),
        problems  = make([dynamic]Config_Problem),
        workspace = strings.clone(workspace),
        allocator = context.allocator,
    }
    for text in texts {
        config_merge_text(&cfg, text, "test.json")
    }
    config_finish(&cfg)
    return cfg
}

// True when some problem's message holds `needle`.
@(private = "file")
reports :: proc(cfg: ^Config, needle: string) -> bool {
    for problem in cfg.problems {
        if strings.contains(problem.message, needle) {
            return true
        }
    }
    return false
}

@(private = "file")
find :: proc(cfg: ^Config, id: string) -> (^Server_Config, bool) {
    at := config_index(cfg, id)
    if at < 0 {
        return nil, false
    }
    return &cfg.servers[at], true
}

// Every field of a whole entry, since each one is a separate decode.
@(test)
test_config_parses_an_entry :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [{
            "id": "clangd",
            "extensions": [".c", ".h"],
            "command": ["clangd", "--background-index"],
            "cwd": "/src",
            "env": {"CLANGD_FLAGS": "-j4"},
            "root_markers": ["compile_commands.json", ".git"],
            "features": {"rename": false},
            "enabled": true,
            "override": true
        }]}`,
    )
    defer config_destroy(&cfg)

    server, ok := find(&cfg, "clangd")
    testing.expect(t, ok)
    if !ok {
        return
    }
    testing.expect_value(t, len(server.extensions), 2)
    testing.expect_value(t, server.extensions[0], ".c")
    testing.expect_value(t, server.extensions[1], ".h")
    testing.expect_value(t, len(server.command), 2)
    testing.expect_value(t, server.command[0], "clangd")
    testing.expect_value(t, server.command[1], "--background-index")
    testing.expect_value(t, server.cwd, "/src")
    testing.expect_value(t, len(server.env), 1)
    testing.expect_value(t, server.env[0], "CLANGD_FLAGS=-j4")
    testing.expect_value(t, len(server.root_markers), 2)
    testing.expect_value(t, server.features, lang.FEATURES_ALL - {.Rename})
    testing.expect(t, server.override)
}

// A workspace entry states the one thing it changes: the fields it does not name
// keep the shipped values.
@(test)
test_config_workspace_overlays_by_id :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [{"id": "clangd", "extensions": [".c"], "command": ["clangd"], "cwd": "/global"}]}`,
        `{"servers": [{"id": "clangd", "command": ["clangd-18", "--log=verbose"]}]}`,
    )
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    server, ok := find(&cfg, "clangd")
    testing.expect(t, ok)
    if !ok {
        return
    }
    testing.expect_value(t, len(server.command), 2)
    testing.expect_value(t, server.command[0], "clangd-18")
    testing.expect_value(t, len(server.extensions), 1)
    testing.expect_value(t, server.extensions[0], ".c")
    testing.expect_value(t, server.cwd, "/global")
}

// A new id adds a server; "enabled": false is how a workspace turns one off. It
// stays in the table so Settings can list it and turn it back on, and it stops
// claiming its extensions.
@(test)
test_config_workspace_adds_and_disables :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [
            {"id": "clangd", "extensions": [".c"], "command": ["clangd"]},
            {"id": "gopls", "extensions": [".go"], "command": ["gopls"]}
        ]}`,
        `{"servers": [
            {"id": "clangd", "enabled": false},
            {"id": "zls", "extensions": [".zig"], "command": ["zls"]}
        ]}`,
    )
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 3)
    clangd, has_clangd := find(&cfg, "clangd")
    testing.expect(t, has_clangd, "a disabled server must stay listed")
    testing.expect(t, !clangd.enabled)
    _, claims_c := config_server_for(&cfg, ".c")
    testing.expect(t, !claims_c, "a disabled server must not claim its extensions")
    _, has_gopls := find(&cfg, "gopls")
    testing.expect(t, has_gopls)
    _, has_zls := find(&cfg, "zls")
    testing.expect(t, has_zls)
}

// Turning a shipped server off is how a workspace hands its language to another
// entry: the disabled one must not consume the extension on the way past.
@(test)
test_config_disabled_server_yields_extension :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [{"id": "basedpyright", "extensions": [".py"], "command": ["basedpyright-langserver"]}]}`,
        `{"servers": [
            {"id": "basedpyright", "enabled": false},
            {"id": "ruff", "extensions": [".py"], "command": ["ruff", "server"]}
        ]}`,
    )
    defer config_destroy(&cfg)

    server, found := config_server_for(&cfg, ".py")
    testing.expect(t, found, "the enabled entry must take the language over")
    testing.expect_value(t, server.id, "ruff")
}

// An entry with nothing to start is not a server. Nor is one with no id, which
// nothing could overlay.
@(test)
test_config_drops_entries_that_start_nothing :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [
            {"id": "no-command", "extensions": [".x"]},
            {"id": "empty-command", "extensions": [".y"], "command": []},
            {"extensions": [".z"], "command": ["anon"]},
            {"id": "fine", "extensions": [".w"], "command": ["fine"]}
        ]}`,
    )
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    testing.expect_value(t, cfg.servers[0].id, "fine")
}

// A file that is not a config contributes nothing, and never takes the table with
// it: a broken workspace file must leave the shipped servers standing.
@(test)
test_config_survives_malformed_files :: proc(t: ^testing.T) {
    good := `{"servers": [{"id": "gopls", "extensions": [".go"], "command": ["gopls"]}]}`
    cases := []string {
        "",
        "not json at all",
        `{"servers": {}}`,
        `{"servers": [1, "two", null]}`,
        `[]`,
        `{"unknown_key": 3, "servers": [{"id": "gopls", "unknown": true}]}`,
    }
    for text in cases {
        cfg := merge(good, text)
        defer config_destroy(&cfg)
        testing.expectf(t, len(cfg.servers) == 1, "%q left %d servers", text, len(cfg.servers))
        if len(cfg.servers) == 1 {
            testing.expect_value(t, cfg.servers[0].command[0], "gopls")
        }
    }
}

// The feature names are lang's own, so there is no second spelling; a name
// nothing answers to is ignored rather than fatal.
@(test)
test_config_features :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [{"id": "s", "extensions": [".s"], "command": ["s"],
            "features": {"rename": false, "hover": false, "not_a_feature": false}}]}`,
        `{"servers": [{"id": "s", "features": {"hover": true, "completion": false}}]}`,
    )
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    testing.expect_value(t, cfg.servers[0].features, lang.FEATURES_ALL - {.Rename, .Completion})
}

// The three formatting kinds' feature names, same as any other kind.
@(test)
test_config_features_formatting :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [{"id": "s", "extensions": [".s"], "command": ["s"],
            "features": {"formatting": false, "range_formatting": false, "on_type_formatting": false}}]}`,
    )
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    testing.expect_value(t, cfg.servers[0].features, lang.FEATURES_ALL - {.Format, .Format_Range, .Format_On_Type})
}

// The leading '.' a config may omit is put back, because a path's extension
// always carries one.
@(test)
test_config_extensions_get_a_dot :: proc(t: ^testing.T) {
    cfg := merge(`{"servers": [{"id": "s", "extensions": ["c", ".h", "hpp"], "command": ["s"]}]}`)
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    testing.expect_value(t, cfg.servers[0].extensions[0], ".c")
    testing.expect_value(t, cfg.servers[0].extensions[1], ".h")
    testing.expect_value(t, cfg.servers[0].extensions[2], ".hpp")
}

// `filenames` claims a bare name verbatim — no dot is added, unlike
// `extensions` — and a later layer replaces the list rather than adding to it.
@(test)
test_config_filenames_are_kept_verbatim :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [{"id": "cmake", "filenames": ["Makefile"], "command": ["s"]}]}`,
        `{"servers": [{"id": "cmake", "filenames": ["CMakeLists.txt", "Makefile"]}]}`,
    )
    defer config_destroy(&cfg)

    server, ok := find(&cfg, "cmake")
    testing.expect(t, ok, "the entry was dropped")
    if !ok {
        return
    }
    testing.expect_value(t, len(server.filenames), 2)
    testing.expect_value(t, server.filenames[0], "CMakeLists.txt")
    testing.expect_value(t, server.filenames[1], "Makefile")
}

// A file name beats an extension, so a file whose extension names another
// language still reaches the server that claims its name.
@(test)
test_config_server_for_filename :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [
            {"id": "cmake", "filenames": ["CMakeLists.txt"], "extensions": [".cmake"], "command": ["s"]},
            {"id": "text", "extensions": [".txt"], "command": ["t"]}
        ]}`,
    )
    defer config_destroy(&cfg)

    server, ok := config_server_for(&cfg, "cmakelists.txt")
    testing.expect(t, ok, "a bare file name claimed nothing")
    if ok {
        testing.expect_value(t, server.id, "cmake")
    }
    other, has := config_server_for(&cfg, ".txt")
    testing.expect(t, has, "the extension entry stopped answering")
    if has {
        testing.expect_value(t, other.id, "text")
    }
}

// A key of the wrong type is reported and leaves the field as it was.
@(test)
test_config_filenames_must_be_an_array :: proc(t: ^testing.T) {
    cfg := merge(`{"servers": [{"id": "s", "filenames": "Makefile", "command": ["s"]}]}`)
    defer config_destroy(&cfg)

    testing.expect(t, reports(&cfg, `"filenames" must be an array of strings`), "a bad type went unreported")
}

// The lookup a request makes, and the case a path can arrive in.
@(test)
test_config_server_for_extension :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [
            {"id": "clangd", "extensions": [".c", ".h"], "command": ["clangd"]},
            {"id": "gopls", "extensions": [".go"], "command": ["gopls"]}
        ]}`,
    )
    defer config_destroy(&cfg)

    server, ok := config_server_for(&cfg, ".H")
    testing.expect(t, ok)
    if ok {
        testing.expect_value(t, server.id, "clangd")
    }

    _, missing := config_server_for(&cfg, ".odin")
    testing.expect(t, !missing)
    _, empty := config_server_for(&cfg, "")
    testing.expect(t, !empty)
}

// initializationOptions and settings pass through to the server verbatim, so they
// are kept as text and not decoded. Sorted keys make one config one text.
@(test)
test_config_json_passthrough :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [{"id": "s", "extensions": [".s"], "command": ["s"],
            "initialization_options": {"b": "two", "a": {"deep": true}},
            "settings": null}]}`,
    )
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    testing.expect_value(t, cfg.servers[0].init_options, `{"a":{"deep":true},"b":"two"}`)
    testing.expect_value(t, cfg.servers[0].settings, "")
}

// A file that cannot be a config says so, instead of leaving the user to guess
// why their server is missing.
@(test)
test_config_reports_broken_files :: proc(t: ^testing.T) {
    cases := []struct {
        text:   string,
        needle: string,
    } {
        {"not json at all", "not valid JSON"},
        {`[]`, "must be a JSON object"},
        {`{"other": 1}`, `no "servers" array`},
        {`{"servers": {}}`, `"servers" must be an array`},
        {`{"servers": [1]}`, "entry #1 is not an object"},
        {`{"servers": [{"command": ["x"]}]}`, `entry #1 has no "id"`},
    }
    for c in cases {
        cfg := merge(c.text)
        defer config_destroy(&cfg)
        testing.expectf(t, reports(&cfg, c.needle), "%q did not report %q", c.text, c.needle)
    }
}

// A key nothing answers to is worth a word, but never costs the server: a file
// written for a later version still loads here.
@(test)
test_config_reports_unknown_and_mistyped_keys :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [{"id": "s", "extensions": [".s"], "command": ["s"],
            "init_optionz": {}, "root_markers": "not-an-array"}]}`,
    )
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    testing.expect(t, reports(&cfg, `unknown key "init_optionz"`), "the misspelled key is named")
    testing.expect(t, reports(&cfg, `"root_markers" must be an array`), "the wrong type is named")
}

// An entry that names no command cannot start anything, and says why it went.
@(test)
test_config_reports_a_dropped_entry :: proc(t: ^testing.T) {
    cfg := merge(`{"servers": [{"id": "no-command", "extensions": [".x"]}]}`)
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 0)
    testing.expect(t, reports(&cfg, "names no command"), "the drop is reported")
}

// `init_options` is the spelling the documentation carried for a while; it must
// reach the same field as the current one, with no complaint.
@(test)
test_config_accepts_the_init_options_alias :: proc(t: ^testing.T) {
    cfg := merge(`{"servers": [{"id": "s", "extensions": [".s"], "command": ["s"],
        "init_options": {"a": 1}}]}`)
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    testing.expect_value(t, cfg.servers[0].init_options, `{"a":1}`)
    testing.expect(t, !reports(&cfg, "unknown key"), "the alias is not an unknown key")
}

// The setup fields the panel reads: a display name, the install command for this
// platform alone, and the two opaque strings the host acts on.
@(test)
test_config_parses_setup_fields :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [{"id": "s", "name": "Server (Lang)", "extensions": [".s"], "command": ["s"],
            "install": {"windows": "winget install s", "darwin": "brew install s", "linux": "apt install s"},
            "docs_url": "https://example.invalid", "setup_command": "s-configure"}]}`,
    )
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    server := &cfg.servers[0]
    testing.expect_value(t, server_display_name(server), "Server (Lang)")
    testing.expect_value(t, server.docs_url, "https://example.invalid")
    testing.expect_value(t, server.setup_command, "s-configure")
    when ODIN_OS == .Windows {
        testing.expect_value(t, server.install, "winget install s")
    } else when ODIN_OS == .Darwin {
        testing.expect_value(t, server.install, "brew install s")
    } else {
        testing.expect_value(t, server.install, "apt install s")
    }
}

// A platform the entry says nothing about falls back to "any".
@(test)
test_config_install_falls_back_to_any :: proc(t: ^testing.T) {
    cfg := merge(
        `{"servers": [{"id": "s", "extensions": [".s"], "command": ["s"],
            "install": {"any": "go install example.invalid/s@latest"}}]}`,
    )
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    testing.expect_value(t, cfg.servers[0].install, "go install example.invalid/s@latest")
}

// The display name of an entry that states none is its id.
@(test)
test_config_name_falls_back_to_id :: proc(t: ^testing.T) {
    cfg := merge(`{"servers": [{"id": "zls", "extensions": [".zig"], "command": ["zls"]}]}`)
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    testing.expect_value(t, server_display_name(&cfg.servers[0]), "zls")
}

// The variables a per-project server path needs. A name nothing answers to is
// left as written, so it fails to resolve visibly instead of silently becoming
// an empty path.
@(test)
test_config_expands_variables :: proc(t: ^testing.T) {
    home := config_home()
    cfg := merge_in(
        "ws",
        `{"servers": [{"id": "s", "extensions": [".s"], "command": ["${workspace}/.venv/bin/s", "--home=${userHome}"],
            "cwd": "${workspace}/sub", "env": {"TOOL": "${nope}"}}]}`,
    )
    defer config_destroy(&cfg)

    testing.expect_value(t, len(cfg.servers), 1)
    server := &cfg.servers[0]
    testing.expect_value(t, server.command[0], "ws/.venv/bin/s")
    testing.expect_value(t, server.cwd, "ws/sub")
    testing.expect_value(t, server.env[0], "TOOL=${nope}")
    testing.expect(t, reports(&cfg, "${nope}"), "the unresolved variable is named")
    if home != "" {
        testing.expect_value(t, server.command[1], strings.concatenate({"--home=", home}, context.temp_allocator))
    }
}

// An environment variable the machine sets reaches the command; one it does not
// is left as written.
@(test)
test_config_expands_environment :: proc(t: ^testing.T) {
    KEY :: "USERPROFILE" when ODIN_OS == .Windows else "HOME"

    cfg := merge(`{"servers": [{"id": "s", "extensions": [".s"], "command": ["s", "--at=${env:THOR_NO_SUCH_VAR}"]}]}`)
    defer config_destroy(&cfg)
    testing.expect_value(t, len(cfg.servers), 1)
    testing.expect_value(t, cfg.servers[0].command[1], "--at=${env:THOR_NO_SUCH_VAR}")

    value := os.get_env(KEY, context.temp_allocator)
    if value == "" {
        return
    }
    text := fmt.tprintf(`{{"servers": [{{"id": "s", "extensions": [".s"], "command": ["s", "${{env:%s}}"]}}]}}`, KEY)
    set := merge(text)
    defer config_destroy(&set)
    testing.expect_value(t, len(set.servers), 1)
    testing.expect_value(t, set.servers[0].command[1], value)
}

// The shipped table itself: it must parse with nothing to report, and every
// entry in it must be one a server can be started from. Merged on its own, so a
// developer's own user/lsp.json cannot fail the build.
@(test)
test_config_shipped_table :: proc(t: ^testing.T) {
    data, rerr := os.read_entire_file(GLOBAL_CONFIG, context.temp_allocator)
    testing.expect(t, rerr == nil, "settings/lsp.json must be readable from the repository root")
    if rerr != nil {
        return
    }
    cfg := merge(string(data))
    defer config_destroy(&cfg)

    testing.expect(t, len(cfg.servers) > 0)
    for problem in cfg.problems {
        testing.expectf(t, false, "settings/lsp.json: %s", config_problem_text(problem, context.temp_allocator))
    }
    for server in cfg.servers {
        testing.expectf(t, server.id != "", "an entry has no id")
        testing.expectf(t, len(server.command) > 0, "%q has no command", server.id)
        testing.expectf(t, len(server.extensions) > 0, "%q claims no extension", server.id)
        testing.expectf(t, server.features == lang.FEATURES_ALL, "%q gates a feature by default", server.id)
        testing.expectf(t, !server.override, "%q overrides the in-client engine by default", server.id)
        for ext in server.extensions {
            testing.expectf(t, ext[0] == '.', "%q claims %q", server.id, ext)
            testing.expectf(t, ext != ".odin", "%q claims .odin, which is served in-client")
        }
        // A root marker is stat-ed, never matched: a glob would simply never
        // find the root and the server would start at the workspace instead.
        for marker in server.root_markers {
            testing.expectf(t, !strings.contains(marker, "*"), "%q has the glob root marker %q", server.id, marker)
        }
        testing.expectf(t, len(server.root_markers) > 0, "%q names no root marker", server.id)
    }

    // Exactly one entry may claim a language out of the box. Every other entry
    // for it ships off, so the first enabled claimant is never a surprise.
    claimed := make(map[string]string, context.temp_allocator)
    for server in cfg.servers {
        if !server.enabled {
            continue
        }
        for ext in server.extensions {
            if owner, taken := claimed[ext]; taken {
                testing.expectf(t, false, "%q and %q both ship enabled for %q", owner, server.id, ext)
                continue
            }
            claimed[ext] = server.id
        }
    }

    _, has_c := config_server_for(&cfg, ".c")
    testing.expect(t, has_c)
    _, has_odin := config_server_for(&cfg, ".odin")
    testing.expect(t, !has_odin)
}
