-- Plugin manifest. Thor reads it before plugin.lua runs; permissions are
-- asked for once and remembered.
return {
    name = "Git LFS",
    description = "Git LFS commands in a top-bar dropdown, when git-lfs is installed.",
    permissions = { "exec", "ui" },
}
