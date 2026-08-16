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

    // A restart of a server that never started is a no-op that still reports the
    // id was found; an unconfigured one is not.
    testing.expect(t, client_restart_server(&c, "fake"), "the configured id must be found")
    testing.expect_value(t, server_state(c.servers[0]), Server_State.Idle)
    testing.expect(t, !client_restart_server(&c, "unknown"), "an unconfigured id must not be found")
}

// A `filenames` entry claims a bare name through the same seam an extension
// does, so a file with no usable extension is routable at last.
@(test)
test_client_handles_a_file_name :: proc(t: ^testing.T) {
    filenames := [1]string{"Makefile"}
    command := [1]string{"fake-language-server"}

    c: Client
    c.config.servers = make([dynamic]Server_Config, 1)
    defer delete(c.config.servers)
    c.config.servers[0] = Server_Config {
        id        = "make",
        filenames = filenames[:],
        command   = command[:],
        features  = lang.FEATURES_ALL,
        enabled   = true,
    }
    c.servers = make([dynamic]^Server, 0)
    append(&c.servers, server_create(&c.config.servers[0], ""))
    defer {
        server_stop(c.servers[0])
        server_destroy(c.servers[0])
        delete(c.servers)
    }

    testing.expect(t, handles(&c, "Makefile"), "a configured file name must be claimed")
    testing.expect(t, handles(&c, "makefile"), "the file system's case must not decide it")
    testing.expect(t, supports(&c, "Makefile", .Definition))
    testing.expect(t, !handles(&c, ".mk"), "an extension the entry never named must claim nothing")
}

// The server's own lsp.json features seed the per-kind admin gate and state
// nothing after that, so the settings can decline a kind the file allowed and
// allow one the file declined.
@(test)
test_client_set_server_features_seeded_by_config :: proc(t: ^testing.T) {
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
    testing.expect(t, !supports(&c, ".fake", .Rename), "the lsp.json config seeded Rename off")

    defaults_enabled, defaults_features, defaults_ok := client_server_defaults(&c, "fake")
    testing.expect(t, defaults_ok)
    testing.expect(t, defaults_enabled)
    testing.expect_value(t, defaults_features, lang.FEATURES_ALL - {.Rename})

    testing.expect(t, client_set_server_features(&c, "fake", lang.FEATURES_ALL - {.Hover}))
    testing.expect(t, !supports(&c, ".fake", .Hover), "the settings-driven gate must decline Hover now")
    testing.expect(t, supports(&c, ".fake", .Rename), "the settings own the gate the config only seeded")
    testing.expect(t, supports(&c, ".fake", .Completion), "an untouched kind must still be answered")

    testing.expect(t, !client_set_server_features(&c, "unknown", lang.FEATURES_ALL))
    _, _, unknown_ok := client_server_defaults(&c, "unknown")
    testing.expect(t, !unknown_ok, "an unconfigured id has no defaults to report")
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

// The snapshot a status view reads before anything started: not running, not
// installed, and carrying the setup text the panel offers.
@(test)
test_client_server_status :: proc(t: ^testing.T) {
    extensions := [2]string{".py", ".pyi"}
    command := [1]string{"thor-no-such-language-server"}

    c: Client
    c.config.servers = make([dynamic]Server_Config, 1)
    defer delete(c.config.servers)
    c.config.servers[0] = Server_Config {
        id         = "basedpyright",
        name       = "basedpyright (Python)",
        extensions = extensions[:],
        command    = command[:],
        install    = "pipx install basedpyright",
        docs_url   = "https://example.invalid",
        features   = lang.FEATURES_ALL,
        enabled    = true,
    }
    c.servers = make([dynamic]^Server, 0)
    append(&c.servers, server_create(&c.config.servers[0], ""))
    defer {
        for s in c.servers {
            server_stop(s)
            server_destroy(s)
        }
        delete(c.servers)
    }

    status, ok := client_server_status(&c, "basedpyright", context.temp_allocator)
    testing.expect(t, ok, "the configured id must have a status")
    if !ok {
        return
    }
    testing.expect_value(t, status.name, "basedpyright (Python)")
    testing.expect_value(t, status.state, Server_State.Idle)
    testing.expect_value(t, server_state_name(status.state), "Not started")
    testing.expect(t, !status.installed, "a made-up program must not be found on PATH")
    testing.expect_value(t, status.exe, "")
    testing.expect_value(t, status.root, "")
    testing.expect_value(t, status.restarts, 0)
    testing.expect_value(t, status.last_error, "")
    testing.expect(t, status.enabled)
    testing.expect_value(t, status.install_command, "pipx install basedpyright")
    testing.expect(t, status.claimed_by == "", "the only claimant owns its own extension")
    testing.expect_value(t, len(status.extensions), 2)

    _, missing := client_server_status(&c, "nothing", context.temp_allocator)
    testing.expect(t, !missing)
}

// Two enabled entries on one language: the first owns it and the second is dead
// config. The status names the owner, so the collision is visible instead of
// silent.
@(test)
test_client_extension_owner :: proc(t: ^testing.T) {
    extensions := [1]string{".py"}
    command := [1]string{"x"}

    c: Client
    c.config.servers = make([dynamic]Server_Config, 2)
    defer delete(c.config.servers)
    c.config.servers[0] = Server_Config{id = "basedpyright", extensions = extensions[:], command = command[:], features = lang.FEATURES_ALL, enabled = true}
    c.config.servers[1] = Server_Config{id = "ruff", extensions = extensions[:], command = command[:], features = lang.FEATURES_ALL, enabled = true}
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

    owner, taken := client_extension_owner(&c, ".py")
    testing.expect(t, taken)
    testing.expect_value(t, owner, "basedpyright")

    first, _ := client_server_status(&c, "basedpyright", context.temp_allocator)
    testing.expect_value(t, first.claimed_by, "")
    second, _ := client_server_status(&c, "ruff", context.temp_allocator)
    testing.expect_value(t, second.claimed_by, "basedpyright")
}

// server[0] must not starve server[1]: poll starts from poll_next, not always
// from servers[0], so pushes queued on both are taken in round-robin order
// rather than draining the first server dry before the second is ever asked.
@(test)
test_poll_round_robins_across_servers :: proc(t: ^testing.T) {
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

    append(&c.servers[0].pushes, lang.Result{id = 0}, lang.Result{id = 1})
    append(&c.servers[1].pushes, lang.Result{id = 2})

    res: lang.Result
    testing.expect(t, poll(&c, &res))
    testing.expect_value(t, res.id, u64(0))
    testing.expect(t, poll(&c, &res))
    testing.expect_value(t, res.id, u64(2))
    testing.expect(t, poll(&c, &res))
    testing.expect_value(t, res.id, u64(1))
    testing.expect(t, !poll(&c, &res), "both servers must now be drained")
}
