package thor

import "core:encoding/json"
import "core:strconv"
import "core:strings"

// Remote-hosting knowledge for the git view: which service origin points at,
// the browser URLs for its pages, and the gh/glab commands behind the pull
// request actions. Everything here is platform-free and parses strings, so it
// is tested without a network.

Git_Host_Kind :: enum {
    None,
    GitHub,
    GitLab,
    Other,  // repo page still opens as https://<host>/<path>
}

Git_Host_Info :: struct {
    kind: Git_Host_Kind,
    host: string,  // owned; "github.com", "gitlab.example.org:8443"
    path: string,  // owned; "owner/repo", GitLab subgroups included
}

git_host_info_destroy :: proc(info: ^Git_Host_Info) {
    delete(info.host)
    delete(info.path)
    info^ = {}
}

// Parses origin's URL in its three shapes: scp-like ("git@host:path.git"),
// ssh:// and http(s)://. The trailing ".git" and "/" are dropped.
git_parse_remote_url :: proc(url: string) -> (info: Git_Host_Info, ok: bool) {
    trimmed := strings.trim_space(url)
    host, path: string

    switch {
    case strings.has_prefix(trimmed, "http://") || strings.has_prefix(trimmed, "https://"):
        rest := trimmed[strings.index(trimmed, "://") + 3:]
        // Credentials in the URL are not part of the host.
        if at := strings.index_byte(rest, '@'); at >= 0 {
            rest = rest[at + 1:]
        }
        slash := strings.index_byte(rest, '/')
        if slash <= 0 {
            return
        }
        host = rest[:slash]
        path = rest[slash + 1:]
    case strings.has_prefix(trimmed, "ssh://"):
        rest := trimmed[len("ssh://"):]
        if at := strings.index_byte(rest, '@'); at >= 0 {
            rest = rest[at + 1:]
        }
        slash := strings.index_byte(rest, '/')
        if slash <= 0 {
            return
        }
        host = rest[:slash]
        path = rest[slash + 1:]
    case strings.contains_rune(trimmed, '@') && strings.contains_rune(trimmed, ':'):
        // scp-like: git@host:owner/repo.git
        at := strings.index_byte(trimmed, '@')
        rest := trimmed[at + 1:]
        colon := strings.index_byte(rest, ':')
        if colon <= 0 {
            return
        }
        host = rest[:colon]
        path = rest[colon + 1:]
    case:
        return
    }

    path = strings.trim_suffix(path, "/")
    path = strings.trim_suffix(path, ".git")
    if host == "" || path == "" {
        return
    }

    kind := Git_Host_Kind.Other
    bare := host
    if colon := strings.index_byte(bare, ':'); colon >= 0 {
        bare = bare[:colon] // the port is not part of the service name
    }
    if bare == "github.com" || strings.has_suffix(bare, ".github.com") {
        kind = .GitHub
    } else if strings.contains(bare, "gitlab") {
        kind = .GitLab
    }

    info = Git_Host_Info {kind = kind, host = strings.clone(host), path = strings.clone(path)}
    ok = true
    return
}

git_host_repo_url :: proc(info: Git_Host_Info, allocator := context.temp_allocator) -> string {
    return strings.concatenate({"https://", info.host, "/", info.path}, allocator)
}

// The commit page. GitLab keeps its pages under "/-/".
git_host_commit_url :: proc(info: Git_Host_Info, hash: string, allocator := context.temp_allocator) -> string {
    infix := info.kind == .GitLab ? "/-/commit/" : "/commit/"
    return strings.concatenate({git_host_repo_url(info, allocator), infix, hash}, allocator)
}

// The file page at `branch`. `rel` is repo-relative with forward slashes;
// spaces and the URL-special characters are percent-escaped.
git_host_file_url :: proc(info: Git_Host_Info, branch, rel: string, allocator := context.temp_allocator) -> string {
    infix := info.kind == .GitLab ? "/-/blob/" : "/blob/"
    return strings.concatenate(
        {git_host_repo_url(info, allocator), infix, git_url_escape_path(branch, allocator), "/", git_url_escape_path(rel, allocator)},
        allocator,
    )
}

// The new-PR/new-MR page for `branch`, the no-CLI fallback.
git_host_compare_url :: proc(info: Git_Host_Info, branch: string, allocator := context.temp_allocator) -> string {
    escaped := git_url_escape_path(branch, allocator)
    if info.kind == .GitLab {
        return strings.concatenate(
            {git_host_repo_url(info, allocator), "/-/merge_requests/new?merge_request%5Bsource_branch%5D=", escaped},
            allocator,
        )
    }
    return strings.concatenate({git_host_repo_url(info, allocator), "/compare/", escaped, "?expand=1"}, allocator)
}

// Percent-escapes a path segment chain, keeping the slashes that separate the
// segments.
git_url_escape_path :: proc(path: string, allocator := context.temp_allocator) -> string {
    b: strings.Builder
    strings.builder_init(&b, allocator)
    for c in transmute([]u8) path {
        switch {
        case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
            strings.write_byte(&b, c)
        case c == '/' || c == '-' || c == '_' || c == '.' || c == '~':
            strings.write_byte(&b, c)
        case:
            hex := "0123456789ABCDEF"
            strings.write_byte(&b, '%')
            strings.write_byte(&b, hex[c >> 4])
            strings.write_byte(&b, hex[c & 0xf])
        }
    }
    return strings.to_string(b)
}

// One open pull/merge request from the CLI's JSON listing.
Git_Pr_Entry :: struct {
    number: int,
    title:  string,  // owned
    branch: string,  // owned
    url:    string,  // owned
}

git_pr_entries_destroy :: proc(entries: ^[dynamic]Git_Pr_Entry) {
    for entry in entries {
        delete(entry.title)
        delete(entry.branch)
        delete(entry.url)
    }
    delete(entries^)
}

// Decodes `gh pr list --json number,title,headRefName,url` and
// `glab mr list --output json` (iid/source_branch/web_url) alike. Anything
// that does not parse as a JSON array yields ok = false, never a bad entry.
git_parse_pr_json :: proc(output: string, out: ^[dynamic]Git_Pr_Entry) -> (ok: bool) {
    value, err := json.parse_string(output, allocator = context.temp_allocator)
    if err != nil {
        return false
    }
    array, is_array := value.(json.Array)
    if !is_array {
        return false
    }
    for element in array {
        object, is_object := element.(json.Object)
        if !is_object {
            continue
        }
        entry: Git_Pr_Entry
        if number, has := git_json_number(object, "number"); has {
            entry.number = number
        } else if iid, has_iid := git_json_number(object, "iid"); has_iid {
            entry.number = iid
        }
        entry.title = strings.clone(git_json_string(object, "title"))
        branch := git_json_string(object, "headRefName")
        if branch == "" {
            branch = git_json_string(object, "source_branch")
        }
        entry.branch = strings.clone(branch)
        url := git_json_string(object, "url")
        if url == "" {
            url = git_json_string(object, "web_url")
        }
        entry.url = strings.clone(url)
        append(out, entry)
    }
    return true
}

@(private = "file")
git_json_string :: proc(object: json.Object, key: string) -> string {
    if value, has := object[key]; has {
        if s, is_string := value.(json.String); is_string {
            return s
        }
    }
    return ""
}

@(private = "file")
git_json_number :: proc(object: json.Object, key: string) -> (n: int, ok: bool) {
    value, has := object[key]
    if !has {
        return
    }
    #partial switch v in value {
    case json.Integer:
        return cast(int) v, true
    case json.Float:
        return cast(int) v, true
    }
    return
}

// First https:// token in CLI output — gh/glab print the created PR's URL.
git_first_url :: proc(output: string) -> string {
    start := strings.index(output, "https://")
    if start < 0 {
        return ""
    }
    rest := output[start:]
    end := len(rest)
    for c, i in transmute([]u8) rest {
        if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
            end = i
            break
        }
    }
    return rest[:end]
}

// "N.M.P" somewhere in `--version` output means the CLI answered.
git_cli_present :: proc(version_output: string, code: int) -> bool {
    if code != 0 {
        return false
    }
    rest := version_output
    for field in strings.fields_iterator(&rest) {
        if len(field) < 3 || !strings.contains_rune(field, '.') {
            continue
        }
        first := field[0]
        if first >= '0' && first <= '9' {
            return true
        }
        if _, ok := strconv.parse_f64(field); ok {
            return true
        }
    }
    return false
}
