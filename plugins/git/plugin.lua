-- Git integration: a single "Git" top-bar dropdown whose entries run through the
-- host API (thor.exec / doc / prompt / pick / confirm / refresh_git). Stage and
-- commit are dialogs. Git LFS entries appear only when `git lfs` is installed.
-- Nothing git-specific lives in the editor except the tree's status colouring,
-- which the host owns.

local STATUS_DOC = "git/status.md"

-- Runs `git <args>` in the workspace and returns its output with trailing
-- whitespace trimmed.
local function git(args)
    return (thor.exec("git " .. args):gsub("%s+$", ""))
end

-- True when the workspace is inside a git work tree.
local function is_repo()
    return git("rev-parse --is-inside-work-tree") == "true"
end

-- Prints a git command's output to the console under a labelled heading.
local function report(title, output)
    if output == "" then
        output = "(no output)"
    end
    thor.print("\n[git] " .. title .. "\n" .. output .. "\n")
end

-- Runs an action only inside a repository, reporting a friendly note otherwise.
local function in_repo(title, fn)
    return function()
        if not is_repo() then
            report(title, "not a git repository")
            return
        end
        fn()
    end
end

-- Splits git output into a list of non-empty lines.
local function lines(text)
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            out[#out + 1] = line
        end
    end
    return out
end

-- Prefixes every line of `text` with `> ` so raw git output reads as a block.
local function quote(text)
    if text == "" then
        return "> (none)\n"
    end
    return "> " .. text:gsub("\n", "\n> ") .. "\n"
end

local function render_status()
    if not is_repo() then
        return "# Git\n\nThis workspace is not a git repository.\n"
    end

    local branch = git("rev-parse --abbrev-ref HEAD")
    local upstream = git("rev-list --left-right --count @{upstream}...HEAD 2>nul")
    local ahead, behind = "0", "0"
    local b, a = upstream:match("^(%d+)%s+(%d+)$")
    if a then
        ahead, behind = a, b
    end

    local out = {}
    local function w(s) out[#out + 1] = s end

    w("# Git — `" .. branch .. "`\n\n")
    w("Ahead **" .. ahead .. "**, behind **" .. behind .. "** of upstream.\n\n")
    w("Workspace: `" .. thor.workspace() .. "`\n\n")

    w("## Staged\n\n")
    w(quote(git("diff --cached --name-status")))
    w("\n")

    w("## Changes\n\n")
    w(quote(git("status --short")))
    w("\n")

    w("## Recent commits\n\n")
    w(quote(git("log --oneline --decorate -n 15")))
    w("\n")

    return table.concat(out)
end

thor.on_command("git", function()
    thor.doc(STATUS_DOC, render_status(), true)
end)

-- Paths with unstaged or untracked changes, for the stage picker.
local function unstaged_paths()
    local out = {}
    for _, line in ipairs(lines(git("status --porcelain"))) do
        -- Porcelain "XY path": Y is the work-tree column; anything non-space
        -- there (or "??") means there is something to stage.
        local worktree = line:sub(2, 2)
        if worktree ~= " " then
            out[#out + 1] = line:sub(4)
        end
    end
    return out
end

-- Paths already staged, for the unstage picker.
local function staged_paths()
    return lines(git("diff --cached --name-only"))
end

thor.on_command("git-stage", in_repo("stage", function()
    local paths = unstaged_paths()
    if #paths == 0 then
        report("stage", "nothing to stage")
        return
    end
    table.insert(paths, 1, "* All changes")
    thor.pick("Stage file", paths, function(choice)
        if choice == "* All changes" then
            report("stage all", git("add -A"))
        else
            report("stage " .. choice, git('add -- "' .. choice .. '"'))
        end
        thor.refresh_git()
    end)
end))

thor.on_command("git-unstage", in_repo("unstage", function()
    local paths = staged_paths()
    if #paths == 0 then
        report("unstage", "nothing staged")
        return
    end
    table.insert(paths, 1, "* All staged")
    thor.pick("Unstage file", paths, function(choice)
        if choice == "* All staged" then
            report("unstage all", git("reset -q"))
        else
            report("unstage " .. choice, git('reset -q -- "' .. choice .. '"'))
        end
        thor.refresh_git()
    end)
end))

thor.on_command("git-commit", in_repo("commit", function()
    if git("diff --cached --name-only") == "" then
        report("commit", "nothing staged — use Stage first")
        return
    end
    thor.prompt("Commit message", function(message)
        message = (message:gsub("^%s+", ""):gsub("%s+$", ""))
        if message == "" then
            report("commit", "aborted: empty commit message")
            return
        end
        -- Write the message to a scratch file so multi-word / punctuation-heavy
        -- messages need no shell escaping, then commit from it.
        local scratch = thor.workspace() .. "\\.git\\THOR_COMMITMSG"
        thor.write(scratch, message .. "\n")
        report("commit", git('commit -F "' .. scratch .. '"'))
        thor.refresh_git()
    end)
end))

thor.on_command("git-push", in_repo("push", function()
    report("push", git("push"))
    thor.refresh_git()
end))

thor.on_command("git-pull", in_repo("pull", function()
    report("pull", git("pull --ff-only"))
    thor.refresh_git()
end))

thor.on_command("git-fetch", in_repo("fetch", function()
    report("fetch", git("fetch --all --prune"))
    thor.refresh_git()
end))

thor.on_command("git-discard", in_repo("discard", function()
    if git("status --porcelain") == "" then
        report("discard", "working tree is clean")
        return
    end
    thor.confirm("Discard ALL uncommitted changes? This cannot be undone.", function()
        report("discard", git("checkout -- ."))
        thor.refresh_git()
    end)
end))

local has_lfs = git("lfs version"):match("^git%-lfs") ~= nil

if has_lfs then
    thor.on_command("git-lfs-status", in_repo("lfs status", function()
        report("lfs status", git("lfs status"))
    end))

    thor.on_command("git-lfs-pull", in_repo("lfs pull", function()
        report("lfs pull", git("lfs pull"))
        thor.refresh_git()
    end))

    thor.on_command("git-lfs-track", in_repo("lfs track", function()
        thor.prompt("LFS track pattern (e.g. *.png)", function(pattern)
            pattern = (pattern:gsub("^%s+", ""):gsub("%s+$", ""))
            if pattern == "" then
                report("lfs track", "aborted: empty pattern")
                return
            end
            report("lfs track " .. pattern, git('lfs track "' .. pattern .. '"'))
            thor.refresh_git()
        end)
    end))
end

local entries = {
    { label = "Status",          command = "git" },
    { separator = true },
    { label = "Stage…",          command = "git-stage" },
    { label = "Unstage…",        command = "git-unstage" },
    { label = "Commit…",         command = "git-commit" },
    { separator = true },
    { label = "Push",            command = "git-push" },
    { label = "Pull",            command = "git-pull" },
    { label = "Fetch",           command = "git-fetch" },
    { separator = true },
    { label = "Discard All…",    command = "git-discard" },
}

if has_lfs then
    entries[#entries + 1] = { separator = true }
    entries[#entries + 1] = { label = "LFS: Status",      command = "git-lfs-status" }
    entries[#entries + 1] = { label = "LFS: Pull",        command = "git-lfs-pull" }
    entries[#entries + 1] = { label = "LFS: Track…",      command = "git-lfs-track" }
end

thor.menu("Git", entries)
