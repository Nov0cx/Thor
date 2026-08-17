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

local ESCAPE = {
    ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r",
    ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f",
}

local UNESCAPE = {b = "\b", f = "\f", n = "\n", r = "\r", t = "\t"}

local function json_escape(s)
    return (s:gsub('[%c\\"]', function(c)
        return ESCAPE[c] or string.format("\\u%04X", c:byte())
    end))
end

-- Decodes the escapes JSON defines, \uXXXX included. A surrogate pair is
-- joined, so a character outside the basic plane survives the round trip.
local function json_unescape(s)
    if not s:find("\\", 1, true) then
        return s
    end
    local out, i = {}, 1
    while i <= #s do
        local at = s:find("\\", i, true)
        if not at then
            out[#out + 1] = s:sub(i)
            break
        end
        out[#out + 1] = s:sub(i, at - 1)
        local c = s:sub(at + 1, at + 1)
        if c ~= "u" then
            out[#out + 1] = UNESCAPE[c] or c
            i = at + 2
        else
            local code = tonumber(s:sub(at + 2, at + 5), 16)
            i = at + 6
            if code and code >= 0xD800 and code <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
                local low = tonumber(s:sub(i + 2, i + 5), 16)
                if low and low >= 0xDC00 and low <= 0xDFFF then
                    code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                    i = i + 6
                end
            end
            out[#out + 1] = code and utf8.char(code) or s:sub(at, at + 5)
        end
    end
    return table.concat(out)
end

-- Walks the JSON string that opens at `i`, honouring backslash escapes so an
-- embedded \" does not end it early. Returns the raw body and the index after
-- the closing quote, or nil when the string never closes.
local function scan_string(s, i)
    if s:sub(i, i) ~= '"' then
        return nil
    end
    local j = i + 1
    while j <= #s do
        local c = s:sub(j, j)
        if c == "\\" then
            j = j + 2
        elseif c == '"' then
            return s:sub(i + 1, j - 1), j + 1
        else
            j = j + 1
        end
    end
    return nil
end

-- Splits an array body into its top-level objects. A brace inside a string is
-- text, not structure — the difference %b{} cannot tell.
local function scan_objects(body)
    local objects, i = {}, 1
    while i <= #body do
        local c = body:sub(i, i)
        if c == "{" then
            local depth, j = 0, i
            while j <= #body do
                local d = body:sub(j, j)
                if d == '"' then
                    local _, after = scan_string(body, j)
                    if not after then
                        return nil
                    end
                    j = after
                else
                    if d == "{" then
                        depth = depth + 1
                    elseif d == "}" then
                        depth = depth - 1
                    end
                    j = j + 1
                    if depth == 0 then
                        break
                    end
                end
            end
            if depth ~= 0 then
                return nil
            end
            objects[#objects + 1] = body:sub(i, j - 1)
            i = j
        elseif c:match("[%s,]") then
            i = i + 1
        else
            return nil
        end
    end
    return objects
end

-- Reads a flat { "key": "value" } object. A key is matched as a key, never as
-- a substring, so "display_name" is not "name". A value that is not a string
-- is a shape this plugin must not rewrite, so it refuses.
local function object_fields(obj)
    local fields, i = {}, obj:find("{")
    if not i then
        return nil
    end
    i = i + 1
    while true do
        local at = obj:find("[^%s,]", i)
        if not at or obj:sub(at, at) == "}" then
            return fields
        end
        local key, after = scan_string(obj, at)
        if not after then
            return nil
        end
        local _, colon_end = obj:find("^%s*:%s*", after)
        if not colon_end then
            return nil
        end
        local value, next_i = scan_string(obj, colon_end + 1)
        if not next_i then
            return nil
        end
        fields[json_unescape(key)] = json_unescape(value)
        i = next_i
    end
end

-- Reads the {name, command} pairs out of tasks.json. Understands only the
-- flat shape Thor itself writes; anything else (an unknown key, a missing
-- "tasks" array) reports ok = false, so a hand-edited file is never rewritten
-- from a parse that lost part of it.
local function read_tasks()
    local text = thor.read(TASKS_FILE)
    if text:match("^%s*$") then
        return {}, true
    end
    local body = text:match('"tasks"%s*:%s*%[(.-)%]%s*}%s*$')
    if not body then
        return nil, false
    end
    local objects = scan_objects(body)
    if not objects then
        return nil, false
    end
    local tasks = {}
    for _, obj in ipairs(objects) do
        local fields = object_fields(obj)
        if not fields then
            return nil, false
        end
        for key in pairs(fields) do
            if key ~= "name" and key ~= "command" then
                return nil, false
            end
        end
        if not (fields.name and fields.command) then
            return nil, false
        end
        tasks[#tasks + 1] = {name = fields.name, command = fields.command}
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
-- already exists (with a different command, which is left alone). A refusal is
-- reported here, since the callers go on to describe what they configured and
-- would otherwise name a task that was never added.
local function add_task(name, command)
    local function refuse(reason)
        thor.print("\n[compile-commands] " .. reason .. "\n")
        return false, reason
    end

    local tasks, ok = read_tasks()
    if not ok then
        return refuse("tasks.json has a shape this plugin does not recognise; add \"" .. name .. "\" by hand")
    end
    for _, t in ipairs(tasks) do
        if t.name == name then
            if t.command == command then
                return true
            end
            return refuse("a task named \"" .. name .. "\" already exists with a different command")
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
