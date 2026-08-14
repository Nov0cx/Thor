package thor

import "core:testing"

@(test)
test_git_parse_remote_url_forms :: proc(t: ^testing.T) {
    scp, scp_ok := git_parse_remote_url("git@github.com:Nov0cx/thor.git\n")
    defer git_host_info_destroy(&scp)
    testing.expect(t, scp_ok, "scp form did not parse")
    testing.expect_value(t, scp.kind, Git_Host_Kind.GitHub)
    testing.expect_value(t, scp.host, "github.com")
    testing.expect_value(t, scp.path, "Nov0cx/thor")

    https, https_ok := git_parse_remote_url("https://user@gitlab.example.org:8443/group/sub/repo.git")
    defer git_host_info_destroy(&https)
    testing.expect(t, https_ok, "https form did not parse")
    testing.expect_value(t, https.kind, Git_Host_Kind.GitLab)
    testing.expect_value(t, https.host, "gitlab.example.org:8443")
    testing.expect_value(t, https.path, "group/sub/repo")

    ssh, ssh_ok := git_parse_remote_url("ssh://git@sr.ht/~user/repo/")
    defer git_host_info_destroy(&ssh)
    testing.expect(t, ssh_ok, "ssh form did not parse")
    testing.expect_value(t, ssh.kind, Git_Host_Kind.Other)
    testing.expect_value(t, ssh.path, "~user/repo")

    _, bad_ok := git_parse_remote_url("not a url")
    testing.expect(t, !bad_ok, "junk parsed as a remote")
}

@(test)
test_git_host_urls :: proc(t: ^testing.T) {
    github := Git_Host_Info {kind = .GitHub, host = "github.com", path = "owner/repo"}
    testing.expect_value(t, git_host_repo_url(github), "https://github.com/owner/repo")
    testing.expect_value(t, git_host_commit_url(github, "abc123"), "https://github.com/owner/repo/commit/abc123")
    testing.expect_value(t, git_host_file_url(github, "main", "docs/a file.md"), "https://github.com/owner/repo/blob/main/docs/a%20file.md")
    testing.expect_value(t, git_host_compare_url(github, "feat/x"), "https://github.com/owner/repo/compare/feat/x?expand=1")

    gitlab := Git_Host_Info {kind = .GitLab, host = "gitlab.com", path = "g/s/repo"}
    testing.expect_value(t, git_host_commit_url(gitlab, "abc"), "https://gitlab.com/g/s/repo/-/commit/abc")
    testing.expect_value(t, git_host_file_url(gitlab, "main", "x.odin"), "https://gitlab.com/g/s/repo/-/blob/main/x.odin")
    testing.expect_value(
        t,
        git_host_compare_url(gitlab, "feat"),
        "https://gitlab.com/g/s/repo/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat",
    )
}

// One decoder covers both CLIs: gh names the fields number/headRefName/url,
// glab iid/source_branch/web_url.
@(test)
test_git_parse_pr_json :: proc(t: ^testing.T) {
    entries := make([dynamic]Git_Pr_Entry)
    defer git_pr_entries_destroy(&entries)

    gh := `[{"number": 7, "title": "Fix", "headRefName": "fix-1", "url": "https://github.com/o/r/pull/7"}]`
    testing.expect(t, git_parse_pr_json(gh, &entries), "gh JSON refused")
    glab := `[{"iid": 3, "title": "MR", "source_branch": "mr-1", "web_url": "https://gitlab.com/o/r/-/merge_requests/3"}]`
    testing.expect(t, git_parse_pr_json(glab, &entries), "glab JSON refused")

    testing.expect_value(t, len(entries), 2)
    testing.expect_value(t, entries[0].number, 7)
    testing.expect_value(t, entries[0].branch, "fix-1")
    testing.expect_value(t, entries[1].number, 3)
    testing.expect_value(t, entries[1].branch, "mr-1")
    testing.expect_value(t, entries[1].url, "https://gitlab.com/o/r/-/merge_requests/3")

    bad := make([dynamic]Git_Pr_Entry)
    defer git_pr_entries_destroy(&bad)
    testing.expect(t, !git_parse_pr_json("gh: command not found", &bad), "error text decoded as PRs")
    testing.expect_value(t, len(bad), 0)
}

@(test)
test_git_first_url_and_cli_present :: proc(t: ^testing.T) {
    testing.expect_value(t, git_first_url("Creating pull request\nhttps://github.com/o/r/pull/9\ndone"), "https://github.com/o/r/pull/9")
    testing.expect_value(t, git_first_url("no links here"), "")

    testing.expect(t, git_cli_present("gh version 2.40.1 (2026-01-01)", 0), "gh version output refused")
    testing.expect(t, !git_cli_present("'gh' is not recognized", 1), "a failing probe passed")
    testing.expect(t, !git_cli_present("some words only", 0), "versionless output passed")
}
