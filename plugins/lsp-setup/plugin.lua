-- Detects whether each server named in settings/lsp.json answers on PATH, and
-- for a missing one adds a workspace task that installs it. Installers
-- (winget, npm, pip, cargo, brew, apt) commonly run well past the two-second
-- budget a plugin call gets, and thor.exec kills everything left in the
-- command's process tree the moment the call that started it returns — so the
-- install itself has to run in the console (via a task), not through
-- thor.exec directly.

local TASKS_FILE = ".thor/tasks.json"

local SERVERS = {
    {
        id = "clangd", label = "clangd (C / C++)", bin = "clangd",
        install = {
            windows = "winget install -e --id LLVM.LLVM",
            darwin  = "brew install llvm",
            linux   = "sudo apt-get update && sudo apt-get install -y clangd",
        },
        hint = "Also needs a compile_commands.json from your build (CMAKE_EXPORT_COMPILE_COMMANDS, or `bear -- make`).",
    },
    {
        id = "rust-analyzer", label = "rust-analyzer (Rust)", bin = "rust-analyzer",
        install = { any = "rustup component add rust-analyzer" },
        hint = "Needs rustup (https://rustup.rs) if that command is not found.",
    },
    {
        id = "gopls", label = "gopls (Go)", bin = "gopls",
        install = { any = "go install golang.org/x/tools/gopls@latest" },
        hint = "Installs to $(go env GOPATH)/bin — make sure that directory is on PATH.",
    },
    {
        id = "basedpyright", label = "basedpyright (Python)", bin = "basedpyright-langserver",
        install = {
            windows = "python -m pip install -U basedpyright",
            any     = "python3 -m pip install -U basedpyright",
        },
        hint = "Installs basedpyright-langserver beside your other Python scripts — make sure that folder is on PATH.",
    },
    {
        id = "typescript", label = "typescript-language-server (TS / JS)", bin = "typescript-language-server",
        install = { any = "npm install -g typescript-language-server typescript" },
    },
    {
        id = "lua-language-server", label = "lua-language-server (Lua)", bin = "lua-language-server",
        install = {
            windows = "winget install -e --id LuaLS.lua-language-server",
            darwin  = "brew install lua-language-server",
            linux   = "sudo apt-get update && sudo apt-get install -y lua-language-server",
        },
        hint = "No apt package on every distro — see https://github.com/LuaLS/lua-language-server/releases.",
    },
    {
        id = "zls", label = "zls (Zig)", bin = "zls",
        install = {
            windows = "winget install -e --id zigtools.zls",
            darwin  = "brew install zls",
        },
        hint = "zls must match your Zig version — see https://github.com/zigtools/zls#installation.",
    },
}

-- "Windows_NT" expands from cmd.exe's %OS% but reaches /bin/sh as the literal
-- text, so this tells the two apart without a dedicated host API.
local function detect_os()
    if thor.exec("echo %OS%"):find("Windows_NT", 1, true) then
        return "windows"
    elseif thor.exec("uname -s"):find("Darwin", 1, true) then
        return "darwin"
    end
    return "linux"
end

local OS_NAME = detect_os()

-- First line of `where` (Windows) or `command -v` (POSIX), trimmed; "" when
-- the binary is not found.
local function which(bin)
    local out
    if OS_NAME == "windows" then
        out = thor.exec("where " .. bin .. " 2>nul")
    else
        out = thor.exec("command -v " .. bin .. " 2>/dev/null")
    end
    return (out:match("^[^\r\n]*") or ""):gsub("%s+$", "")
end

local function install_command(server)
    return server.install[OS_NAME] or server.install.any
end

local function json_escape(s)
    return (s:gsub('[\\"\n\r\t]', {
        ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
    }))
end

local function json_unescape(s)
    return (s:gsub("\\(.)", function(c)
        if c == "n" then return "\n" end
        if c == "r" then return "\r" end
        if c == "t" then return "\t" end
        return c
    end))
end

-- Reads the {name, command} pairs out of tasks.json. Understands only the
-- flat shape Thor itself writes; anything else (or missing "tasks" array)
-- reports ok = false so a hand-edited file is never rewritten and possibly
-- mangled.
local function read_tasks()
    local text = thor.read(TASKS_FILE)
    if text:match("^%s*$") then
        return {}, true
    end
    local body = text:match('"tasks"%s*:%s*%[(.-)%]%s*}%s*$')
    if not body then
        return nil, false
    end
    local tasks = {}
    for obj in body:gmatch("%b{}") do
        local name = obj:match('"name"%s*:%s*"(.-)"')
        local command = obj:match('"command"%s*:%s*"(.-)"')
        if not (name and command) then
            return nil, false
        end
        tasks[#tasks + 1] = {name = json_unescape(name), command = json_unescape(command)}
    end
    return tasks, true
end

local function write_tasks(tasks)
    local parts = {"{\n    \"tasks\": [\n"}
    for i, t in ipairs(tasks) do
        parts[#parts + 1] = '        { "name": "' .. json_escape(t.name) .. '", "command": "' .. json_escape(t.command) .. '" }'
        parts[#parts + 1] = i < #tasks and ",\n" or "\n"
    end
    parts[#parts + 1] = "    ]\n}\n"
    thor.write(TASKS_FILE, table.concat(parts))
end

-- Adds a task that runs `command` under `name`, unless a task by that name
-- already exists (with a different command, which is left alone).
local function add_task(name, command)
    local tasks, ok = read_tasks()
    if not ok then
        return false, "tasks.json has a shape this plugin does not recognise; add it by hand"
    end
    for _, t in ipairs(tasks) do
        if t.name == name then
            return t.command == command, "a task named \"" .. name .. "\" already exists with a different command"
        end
    end
    tasks[#tasks + 1] = {name = name, command = command}
    write_tasks(tasks)
    return true
end

thor.on_command("lsp-status", function()
    local out = {"# LSP Setup\n\n", "Checked against: `" .. OS_NAME .. "`\n\n"}
    for _, s in ipairs(SERVERS) do
        local path = which(s.bin)
        out[#out + 1] = "- **" .. s.label .. "** (`" .. s.bin .. "`) — "
        out[#out + 1] = path ~= "" and ("found: `" .. path .. "`\n") or "not found on PATH\n"
    end
    thor.doc(".thor/lsp-status.md", table.concat(out), true)
end)

thor.on_command("lsp-install", function()
    local missing = {}
    for _, s in ipairs(SERVERS) do
        if which(s.bin) == "" then
            missing[#missing + 1] = s
        end
    end
    if #missing == 0 then
        thor.print("\n[lsp-setup] every configured language server is already on PATH\n")
        return
    end

    local labels = {}
    for i, s in ipairs(missing) do labels[i] = s.label end

    thor.pick("Install language server", labels, function(choice)
        local server
        for _, s in ipairs(missing) do
            if s.label == choice then server = s end
        end
        if not server then
            return
        end

        local command = install_command(server)
        if not command then
            thor.print("\n[lsp-setup] " .. server.label .. ": no automatic installer for " .. OS_NAME .. "\n" ..
                (server.hint and (server.hint .. "\n") or ""))
            return
        end

        local task_name = "Install " .. server.label
        local ok, err = add_task(task_name, command)
        if not ok then
            thor.print("\n[lsp-setup] could not add a task (" .. err .. "); run this yourself instead:\n> " .. command .. "\n")
            return
        end
        thor.print("\n[lsp-setup] added task \"" .. task_name .. "\" — run it from the titlebar Tasks selector.\n" ..
            "Installs run in the console, not through this plugin, since they usually take longer than a plugin call may block for.\n" ..
            (server.hint and (server.hint .. "\n") or ""))
    end)
end)

thor.menu("LSP Setup", {
    {label = "Check Status",     command = "lsp-status"},
    {label = "Install Missing…", command = "lsp-install"},
})
