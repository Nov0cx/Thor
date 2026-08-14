-- Detects whether gopls answers on PATH and, if not, adds a workspace task
-- that installs it. Installers commonly run well past the two-second budget
-- a plugin call gets, and thor.exec kills everything left in the command's
-- process tree the moment the call that started it returns — so the install
-- itself has to run in the console (via a task), not through thor.exec
-- directly.

local TASKS_FILE = ".thor/tasks.json"

local SERVER = {
    id = "gopls", label = "gopls (Go)", bin = "gopls",
    install = { any = "go install golang.org/x/tools/gopls@latest" },
    hint = "Installs to $(go env GOPATH)/bin — make sure that directory is on PATH.",
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

-- Resolved on first use, not at load: detect_os shells out, and every plugin
-- doing that while loading adds a process spawn to startup.
local os_name_cache
local function os_name()
    if not os_name_cache then
        os_name_cache = detect_os()
    end
    return os_name_cache
end

-- First line of `where` (Windows) or `command -v` (POSIX), trimmed; "" when
-- the binary is not found.
local function which(bin)
    local out
    if os_name() == "windows" then
        out = thor.exec("where " .. bin .. " 2>nul")
    else
        out = thor.exec("command -v " .. bin .. " 2>/dev/null")
    end
    return (out:match("^[^\r\n]*") or ""):gsub("%s+$", "")
end

local function install_command()
    return SERVER.install[os_name()] or SERVER.install.any
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
-- flat shape Thor itself writes; anything else (or a missing "tasks" array)
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

thor.on_command("gopls-status", function()
    local path = which(SERVER.bin)
    local out = "# " .. SERVER.label .. " Setup\n\nChecked against: `" .. os_name() .. "`\n\n" ..
        (path ~= "" and ("found: `" .. path .. "`\n") or "not found on PATH\n")
    thor.doc(".thor/gopls-status.md", out, true)
end)

thor.on_command("gopls-install", function()
    if which(SERVER.bin) ~= "" then
        thor.print("\n[gopls-setup] " .. SERVER.label .. " is already on PATH\n")
        return
    end

    local command = install_command()
    if not command then
        thor.print("\n[gopls-setup] " .. SERVER.label .. ": no automatic installer for " .. os_name() .. "\n" ..
            (SERVER.hint and (SERVER.hint .. "\n") or ""))
        return
    end

    thor.confirm("Install " .. SERVER.label .. " via: " .. command .. "?", function()
        local task_name = "Install " .. SERVER.label
        local ok, err = add_task(task_name, command)
        if not ok then
            thor.print("\n[gopls-setup] could not add a task (" .. err .. "); run this yourself instead:\n> " .. command .. "\n")
            return
        end
        thor.print("\n[gopls-setup] added task \"" .. task_name .. "\" — run it from the titlebar Tasks selector.\n" ..
            "Installs run in the console, not through this plugin, since they usually take longer than a plugin call may block for.\n" ..
            (SERVER.hint and (SERVER.hint .. "\n") or ""))
    end)
end)

thor.menu("LSP Setup", {
    {label = "gopls: Check Status",     command = "gopls-status"},
    {label = "gopls: Install Missing…", command = "gopls-install"},
})
