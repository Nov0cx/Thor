-- Detects the workspace's build system and helps produce a
-- compile_commands.json clangd can find: writes a .clangd redirect for
-- CMake's out-of-root build directory, offers to wire up Bazel's hedron
-- extractor (bzlmod only) via MODULE.bazel and a root BUILD file, or adds a
-- Make task through bear (POSIX) / compiledb (Windows). Anything that would
-- run a build stays a task the caller (plugin.lua) triggers from the
-- console, not something run here directly — mirroring the install pattern
-- in plugin.lua. `require` shares this plugin's `thor` table but not
-- plugin.lua's locals, so the caller passes `which`/`add_task`/`os_name` in
-- explicitly.

local M = {}

local function exists(path)
    return thor.read(path) ~= ""
end

local BEAR_INSTALL = { linux = "sudo apt-get update && sudo apt-get install -y bear", darwin = "brew install bear" }

-- Offers to install bear via the same confirm-gated task mechanism used for
-- missing language servers. No-op on Windows, where bear does not exist.
local function offer_bear_install(os_name, add_task)
    local command = BEAR_INSTALL[os_name]
    if not command then
        return
    end
    thor.confirm("bear is not on PATH — add a task to install it (" .. command .. ")?", function()
        add_task("Install bear", command)
    end)
end

-- Adds hedron's refresh_compile_commands target to a root BUILD(.bazel) file
-- if it is not already there, then adds the task that runs it. Runs after
-- MODULE.bazel is confirmed to reference the extractor (either already, or
-- just written by configure_bazel below).
local function wire_bazel_build_file(add_task)
    local build_path = exists("BUILD.bazel") and "BUILD.bazel" or (exists("BUILD") and "BUILD" or "BUILD.bazel")
    local build_text = thor.read(build_path)
    local build_wired = build_text:find("hedron_compile_commands//:refresh_compile_commands.bzl", 1, true) ~= nil

    if not build_wired then
        thor.write(build_path, build_text .. [[

load("@hedron_compile_commands//:refresh_compile_commands.bzl", "refresh_compile_commands")

refresh_compile_commands(
    name = "refresh_compile_commands",
)
]])
    end

    add_task("Generate compile_commands.json (Bazel)", "bazel run //:refresh_compile_commands")
    thor.print("\n[clangd-setup] Bazel (bzlmod) project detected: " ..
        (build_wired and ("the refresh_compile_commands target is already in " .. build_path)
                      or ("added the refresh_compile_commands target to " .. build_path)) ..
        "; added a task to run it.\n")
end

-- MODULE.bazel present: wires hedron's bazel-compile-commands-extractor in
-- (with confirmation, since it edits build files) if it is not already
-- there, then the BUILD file target.
local function configure_bazel(add_task)
    local module_text = thor.read("MODULE.bazel")
    if module_text:find("hedron_compile_commands", 1, true) then
        wire_bazel_build_file(add_task)
        return
    end

    thor.confirm("Add hedron's bazel-compile-commands-extractor to MODULE.bazel and a root BUILD file?", function()
        -- Not on the Bazel Central Registry, so bazel_dep needs a git_override
        -- rather than a version string. The commit is left as a placeholder:
        -- hardcoding one now would either go stale silently or, if wrong,
        -- fail in a confusing half-configured way — a placeholder fails loud
        -- and points straight at the page to pick a real one from.
        thor.write("MODULE.bazel", module_text .. [[

# Hedron's Compile Commands Extractor for Bazel
# https://github.com/hedronvision/bazel-compile-commands-extractor
bazel_dep(name = "hedron_compile_commands", dev_dependency = True)
git_override(
    module_name = "hedron_compile_commands",
    remote = "https://github.com/hedronvision/bazel-compile-commands-extractor.git",
    commit = "REPLACE_ME: pick a commit from https://github.com/hedronvision/bazel-compile-commands-extractor/commits/main",
)
]])
        wire_bazel_build_file(add_task)
    end)
end

-- Makefile/makefile/GNUmakefile present: bear on POSIX, compiledb on
-- Windows, installing whichever is missing through the same confirm-gated
-- task mechanism as a missing language server.
local function configure_make(which, add_task, os_name)
    if os_name == "windows" then
        if which("compiledb") ~= "" then
            add_task("Generate compile_commands.json (Make)", "compiledb make")
            thor.print("\n[clangd-setup] Makefile detected: added a task running `compiledb make`.\n")
        else
            thor.print("\n[clangd-setup] Makefile detected, but compiledb is not on PATH.\n")
            thor.confirm("compiledb is not on PATH — add a task to install it (pip install compiledb)?", function()
                add_task("Install compiledb", "pip install compiledb")
            end)
        end
        return
    end

    if which("bear") ~= "" then
        add_task("Generate compile_commands.json (Make)", "bear -- make")
        thor.print("\n[clangd-setup] Makefile detected: added a task running `bear -- make`.\n")
    else
        thor.print("\n[clangd-setup] Makefile detected, but bear is not on PATH.\n")
        offer_bear_install(os_name, add_task)
    end
end

-- Detects the build system in order (CMake, Bazel, Make, a bare script) and
-- acts on the first match; ctx = { which, add_task, os_name }.
function M.configure(ctx)
    local which, add_task, os_name = ctx.which, ctx.add_task, ctx.os_name

    if exists("compile_commands.json") then
        thor.print("\n[clangd-setup] compile_commands.json is already present at the workspace root.\n")
        return
    end
    if exists(".clangd") and thor.read(".clangd"):find("CompilationDatabase", 1, true) then
        thor.print("\n[clangd-setup] .clangd already points clangd at a compilation database.\n")
        return
    end

    if exists("CMakeLists.txt") then
        add_task("Generate compile_commands.json (CMake)", "cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON")
        if exists(".clangd") then
            thor.print("\n[clangd-setup] CMake project detected: added a task to configure the build.\n" ..
                "A .clangd already exists here, so it was left alone — make sure it names your build directory as CompilationDatabase.\n")
        else
            thor.write(".clangd", "CompileFlags:\n  CompilationDatabase: build\n")
            thor.print("\n[clangd-setup] CMake project detected: added a task to configure the build, and wrote .clangd pointing clangd at build/.\n" ..
                "Run \"Generate compile_commands.json (CMake)\" from the Tasks selector, then reopen this workspace's C/C++ files.\n")
        end
        return
    end

    if exists("MODULE.bazel") then
        configure_bazel(add_task)
        return
    end
    if exists("WORKSPACE") or exists("WORKSPACE.bazel") then
        thor.print("\n[clangd-setup] Bazel WORKSPACE detected, but no MODULE.bazel (bzlmod) — this plugin only automates the bzlmod setup.\n" ..
            "See https://github.com/hedronvision/bazel-compile-commands-extractor for the WORKSPACE-based instructions.\n")
        return
    end

    if exists("Makefile") or exists("makefile") or exists("GNUmakefile") then
        configure_make(which, add_task, os_name)
        return
    end

    if os_name ~= "windows" and exists("build.sh") then
        thor.print("\n[clangd-setup] build.sh found with no known build system — re-run it through bear to capture compile_commands.json:\n" ..
            "> bear -- ./build.sh\n")
        if which("bear") == "" then
            offer_bear_install(os_name, add_task)
        end
        return
    end
    if os_name == "windows" and exists("build.bat") then
        thor.print("\n[clangd-setup] build.bat found with no known build system. There is no bear equivalent on Windows, " ..
            "so this cannot be automated — switch to CMake, or hand-write compile_commands.json " ..
            "(see https://clang.llvm.org/docs/JSONCompilationDatabase.html).\n")
        return
    end

    thor.print("\n[clangd-setup] no CMake/Bazel/Make/build script detected at the workspace root — nothing to configure.\n")
end

return M
