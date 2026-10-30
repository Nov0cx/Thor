-- Comment and string syntax per language, keyed by a language name.
-- extensions lists the file extensions or whole file names it applies to.

return {
    batch = {
        extensions = { ".bat" },
        line = "::",
        quotes = "\"",
    },
    c = {
        block = { "/*", "*/" },
        extensions = { ".c", ".h" },
        line = "//",
        quotes = "\"",
    },
    cmake = {
        block = { "#[[", "]]" },
        extensions = { ".cmake", "CMakeLists.txt" },
        line = "#",
        quotes = "\"",
    },
    commonlisp = {
        block = { "#|", "|#" },
        extensions = { ".lisp", ".lsp", ".cl", ".asd" },
        line = ";",
        quotes = "\"",
    },
    cpp = {
        block = { "/*", "*/" },
        extensions = {
            ".cpp",
            ".cc",
            ".cxx",
            ".c++",
            ".hpp",
            ".hh",
            ".hxx",
            ".h++",
            ".ipp",
        },
        line = "//",
        quotes = "\"",
    },
    csharp = {
        block = { "/*", "*/" },
        extensions = { ".cs", ".csx" },
        line = "//",
        quotes = "\"",
    },
    css = {
        block = { "/*", "*/" },
        extensions = { ".css" },
        quotes = "\"'",
    },
    dockerfile = {
        extensions = { ".dockerfile", "Dockerfile", "dockerfile", "Containerfile" },
        line = "#",
        quotes = "\"'",
    },
    dotenv = {
        extensions = { ".env" },
        line = "#",
        quotes = "\"'",
    },
    git = {
        extensions = { ".gitignore", ".gitmodules" },
        line = "#",
    },
    glsl = {
        block = { "/*", "*/" },
        extensions = { ".glsl", ".vert", ".frag" },
        line = "//",
        quotes = "\"",
    },
    go = {
        block = { "/*", "*/" },
        extensions = { ".go" },
        line = "//",
        quotes = "\"`",
    },
    groovy = {
        block = { "/*", "*/" },
        extensions = { ".groovy", ".gradle", ".gvy", ".gy" },
        line = "//",
        quotes = "\"'",
    },
    haskell = {
        block = { "{-", "-}" },
        extensions = { ".hs" },
        line = "--",
        quotes = "\"",
    },
    hcl = {
        block = { "/*", "*/" },
        extensions = { ".tf", ".tfvars", ".hcl" },
        line = "#",
        quotes = "\"",
    },
    html = {
        block = { "<!--", "-->" },
        extensions = { ".html", ".htm", ".xml", ".svg" },
        quotes = "\"'",
    },
    ini = {
        extensions = { ".ini", ".cfg" },
        line = ";",
        quotes = "\"",
    },
    jai = {
        block = { "/*", "*/" },
        extensions = { ".jai" },
        line = "//",
        quotes = "\"",
    },
    java = {
        block = { "/*", "*/" },
        extensions = { ".java" },
        line = "//",
        quotes = "\"",
    },
    javascript = {
        block = { "/*", "*/" },
        extensions = { ".js", ".jsx", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".tsx" },
        line = "//",
    },
    kotlin = {
        block = { "/*", "*/" },
        extensions = { ".kt" },
        line = "//",
        quotes = "\"",
    },
    lua = {
        block = { "--[[", "]]" },
        extensions = { ".lua" },
        line = "--",
        quotes = "\"'",
    },
    make = {
        extensions = { ".mk", ".mak", "Makefile", "GNUmakefile" },
        line = "#",
    },
    markdown = {
        block = { "<!--", "-->" },
        extensions = { ".md" },
        quotes = "\"",
    },
    nim = {
        block = { "#[", "]#" },
        extensions = { ".nim", ".nims", ".nimble" },
        line = "#",
        quotes = "\"",
    },
    nix = {
        block = { "/*", "*/" },
        extensions = { ".nix" },
        line = "#",
        quotes = "\"",
    },
    ocaml = {
        block = { "(*", "*)" },
        extensions = { ".ml", ".mli" },
        quotes = "\"",
    },
    odin = {
        block = { "/*", "*/" },
        extensions = { ".odin" },
        line = "//",
        quotes = "\"`",
    },
    pascal = {
        block = { "{", "}" },
        extensions = { ".pas", ".pp", ".lpr", ".dpr" },
        line = "//",
        quotes = "'",
    },
    php = {
        block = { "/*", "*/" },
        extensions = { ".php", ".phtml", ".php3", ".php4", ".php5" },
        line = "//",
        quotes = "\"'",
    },
    powershell = {
        block = { "<#", "#>" },
        extensions = { ".ps1", ".psm1", ".psd1" },
        line = "#",
        quotes = "\"'",
    },
    python = {
        extensions = { ".py" },
        line = "#",
        quotes = "\"'",
    },
    ruby = {
        extensions = { ".rb", ".rake", ".gemspec", ".ru" },
        line = "#",
        quotes = "\"'",
    },
    rust = {
        block = { "/*", "*/" },
        extensions = { ".rs" },
        line = "//",
        quotes = "\"",
    },
    shell = {
        extensions = { ".sh" },
        line = "#",
    },
    slang = {
        block = { "/*", "*/" },
        extensions = { ".slang", ".slangh" },
        line = "//",
        quotes = "\"",
    },
    sml = {
        block = { "(*", "*)" },
        extensions = { ".sml", ".sig", ".fun" },
        quotes = "\"",
    },
    starlark = {
        extensions = { ".bzl", ".star", "BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel" },
        line = "#",
        quotes = "\"'",
    },
    toml = {
        extensions = { ".toml" },
        line = "#",
        quotes = "\"'",
    },
    yaml = {
        extensions = { ".yml", ".yaml" },
        line = "#",
        quotes = "\"'",
    },
    zig = {
        extensions = { ".zig" },
        line = "//",
        quotes = "\"",
    },
}
