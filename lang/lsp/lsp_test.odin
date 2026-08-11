package lsp

import "core:testing"

import lang ".."

// Run from the repository root: odin test lang/lsp

// A disabled server is client_server_for's "not found" — the same gate a
// declined extension already answers through, so handles/supports/notify all
// go quiet with no change to those procs themselves. poll is the one caller
// that bypasses client_server_for (it walks c.servers itself), so it needs its
// own admin_enabled check, covered below.
@(test)
test_client_set_server_enabled_gates_dispatch :: proc(t: ^testing.T) {
    extensions := [1]string{".fake"}
    command := [1]string{"fake-language-server"}

    c: Client
    c.config.servers = make([dynamic]Server_Config, 1)
    defer delete(c.config.servers)
    c.config.servers[0] = Server_Config {
        id         = "fake",
        extensions = extensions[:],
        command    = command[:],
        features   = lang.FEATURES_ALL,
        enabled    = true,
    }
    c.servers = make([dynamic]^Server, 0)
    append(&c.servers, server_create(&c.config.servers[0], ""))
    defer {
        server_stop(c.servers[0])
        server_destroy(c.servers[0])
        delete(c.servers)
    }

    testing.expect(t, handles(&c, ".fake"), "an enabled server must claim its extension")
    testing.expect(t, supports(&c, ".fake", .Definition))

    testing.expect(t, client_set_server_enabled(&c, "fake", false), "the configured id must be found")
    testing.expect(t, !handles(&c, ".fake"), "a disabled server must claim nothing")
    testing.expect(t, !supports(&c, ".fake", .Definition))

    res: lang.Result
    testing.expect(t, !poll(&c, &res), "a disabled server's pushes must not reach the Manager")

    testing.expect(t, client_set_server_enabled(&c, "fake", true))
    testing.expect(t, handles(&c, ".fake"), "re-enabling must let the server claim its extension again")

    testing.expect(t, !client_set_server_enabled(&c, "unknown", false), "an unconfigured id must not be found")
}

// The per-kind admin gate ANDs with the server's own lsp.json features rather
// than replacing them: a kind either layer declines stays declined.
@(test)
test_client_set_server_features_ands_with_config :: proc(t: ^testing.T) {
    extensions := [1]string{".fake"}
    command := [1]string{"fake-language-server"}

    c: Client
    c.config.servers = make([dynamic]Server_Config, 1)
    defer delete(c.config.servers)
    c.config.servers[0] = Server_Config {
        id         = "fake",
        extensions = extensions[:],
        command    = command[:],
        features   = lang.FEATURES_ALL - {.Rename}, // lsp.json already declines Rename
        enabled    = true,
    }
    c.servers = make([dynamic]^Server, 0)
    append(&c.servers, server_create(&c.config.servers[0], ""))
    defer {
        server_stop(c.servers[0])
        server_destroy(c.servers[0])
        delete(c.servers)
    }

    testing.expect(t, supports(&c, ".fake", .Hover))
    testing.expect(t, !supports(&c, ".fake", .Rename), "the lsp.json config already declined Rename")

    testing.expect(t, client_set_server_features(&c, "fake", lang.FEATURES_ALL - {.Hover}))
    testing.expect(t, !supports(&c, ".fake", .Hover), "the settings-driven gate must decline Hover now")
    testing.expect(t, !supports(&c, ".fake", .Rename), "the config's own decline must still hold, not be overridden")
    testing.expect(t, supports(&c, ".fake", .Completion), "an untouched kind must still be answered")

    testing.expect(t, client_set_server_features(&c, "fake", lang.FEATURES_ALL))
    testing.expect(t, supports(&c, ".fake", .Hover), "restoring the settings gate must let Hover through again")
    testing.expect(t, !supports(&c, ".fake", .Rename), "the config's own decline is independent of the settings gate")

    testing.expect(t, !client_set_server_features(&c, "unknown", lang.FEATURES_ALL))
}

// The ids a settings UI enumerates are exactly the configured servers', in
// table order.
@(test)
test_client_server_ids :: proc(t: ^testing.T) {
    extensions_a := [1]string{".a"}
    extensions_b := [1]string{".b"}
    command := [1]string{"x"}

    c: Client
    c.config.servers = make([dynamic]Server_Config, 2)
    defer delete(c.config.servers)
    c.config.servers[0] = Server_Config{id = "alpha", extensions = extensions_a[:], command = command[:], features = lang.FEATURES_ALL, enabled = true}
    c.config.servers[1] = Server_Config{id = "beta", extensions = extensions_b[:], command = command[:], features = lang.FEATURES_ALL, enabled = true}
    c.servers = make([dynamic]^Server, 0)
    append(&c.servers, server_create(&c.config.servers[0], ""))
    append(&c.servers, server_create(&c.config.servers[1], ""))
    defer {
        for s in c.servers {
            server_stop(s)
            server_destroy(s)
        }
        delete(c.servers)
    }

    ids := client_server_ids(&c, context.temp_allocator)
    testing.expect_value(t, len(ids), 2)
    if len(ids) == 2 {
        testing.expect_value(t, ids[0], "alpha")
        testing.expect_value(t, ids[1], "beta")
    }
}
