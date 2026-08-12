package lsp

import "core:testing"

import lang ".."

// Run from the repository root: odin test lang/lsp

// The merge of one or more config files, in the order a load applies them.
@(private = "file")
merge :: proc(texts: ..string) -> Config {
    cfg := Config {
        servers   = make([dynamic]Server_Config),
        allocator = context.allocator,
    }
    for text in texts {
        config_merge_text(&cfg, text)
    }
    config_finish(&cfg)
    return cfg
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

// A new id adds a server; "enabled": false is how a workspace removes one.
@(test)
test_config_workspace_adds_and_removes :: proc(t: ^testing.T) {
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

    testing.expect_value(t, len(cfg.servers), 2)
    _, has_clangd := find(&cfg, "clangd")
    testing.expect(t, !has_clangd)
    _, has_gopls := find(&cfg, "gopls")
    testing.expect(t, has_gopls)
    _, has_zls := find(&cfg, "zls")
    testing.expect(t, has_zls)
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

// The shipped table itself: it must parse, and every entry in it must be one a
// server can be started from.
@(test)
test_config_shipped_table :: proc(t: ^testing.T) {
    cfg := config_load("")
    defer config_destroy(&cfg)

    testing.expect(t, len(cfg.servers) > 0)
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
    }

    _, has_c := config_server_for(&cfg, ".c")
    testing.expect(t, has_c)
    _, has_odin := config_server_for(&cfg, ".odin")
    testing.expect(t, !has_odin)
}
