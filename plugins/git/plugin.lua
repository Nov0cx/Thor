-- Git LFS commands in a top-bar dropdown, shown only when `git lfs` is
-- installed. Everything else git moved into the editor's own Git UI (View >
-- Git); LFS stays here as a small, living example of the plugin API.

-- Runs `git <args>` in the workspace and returns its output with trailing
-- whitespace trimmed.
local function git(args)
    return (thor.exec("git " .. args):gsub("%s+$", ""))
end

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

    thor.menu("Git LFS", {
        { label = "Status", command = "git-lfs-status" },
        { label = "Pull",   command = "git-lfs-pull" },
        { label = "Track…", command = "git-lfs-track" },
    })
end
