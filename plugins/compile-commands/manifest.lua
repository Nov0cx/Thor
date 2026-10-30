-- Plugin manifest. Thor reads it before plugin.lua runs; permissions are
-- asked for once and remembered.
return {
    name = "compile_commands.json",
    description = "Detects the project's build system (CMake, Bazel, Make, or a bare build script) and helps produce the compile_commands.json clangd needs. Run from Settings > Language Servers > clangd.",
    permissions = { "exec", "read", "write", "ui" },
}
