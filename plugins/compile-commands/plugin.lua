-- Detects the project's build system and helps produce the
-- compile_commands.json clangd needs (see buildsystem.lua). Reached from
-- Settings > Language Servers > clangd > "Set Up This Project", which runs the
-- `configure-compile-commands` command below; the entry that names it is
-- `"setup_command"` in settings/lsp.json.
--
-- Whether clangd itself is installed is not asked here: the editor looks on
-- PATH natively and offers the install. This plugin is only the part that
-- tracks external build tooling, which is why it stays Lua.

local TASKS_FILE = ".thor/tasks.json"

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

local buildsystem = require "buildsystem"

thor.on_command("configure-compile-commands", function()
    buildsystem.configure({ which = which, add_task = add_task, os_name = os_name() })
end)
