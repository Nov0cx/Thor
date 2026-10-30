-- Plugin manifest. Thor reads it before plugin.lua runs; permissions are
-- asked for once and remembered.
return {
    name = "Tutorial",
    description = "Interactive tutorial: a shortcut drill and a broken Odin file to repair.",
    permissions = { "read", "write", "ui", "keys", "tick" },
}
