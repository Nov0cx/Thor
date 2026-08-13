package update

// The GitHub release payload, and the rule for what the downloader may fetch.

import "core:encoding/json"
import "core:strings"

// One published file of a release. Every other key of the payload is skipped by
// json.unmarshal, so the struct stays as small as the need.
Api_Asset :: struct {
    name:                 string,
    browser_download_url: string,
    size:                 i64,
}

// A published release.
Api_Release :: struct {
    tag_name:   string,
    body:       string,
    draft:      bool,
    prerelease: bool,
    assets:     []Api_Asset,
}

// The only prefix a download may carry. GitHub redirects an asset to its CDN
// and curl follows that, so only the first URL is ours to check — which makes
// the strictest workable rule the right one.
DOWNLOAD_PREFIX :: "https://github.com/" + OWNER + "/" + REPO + "/releases/download/"

// Decodes the reply of the releases API. A payload without a tag is refused
// here rather than later: `null` unmarshals into a zero release without an
// error, and the API answers that for a repository with no release at all.
release_decode :: proc(data: []byte, allocator := context.allocator) -> (release: Api_Release, ok: bool) {
    if len(data) == 0 {
        return {}, false
    }
    if err := json.unmarshal(data, &release, allocator = allocator); err != nil {
        return {}, false
    }
    if release.tag_name == "" {
        return {}, false
    }
    return release, true
}

// The asset of that exact name.
release_find_asset :: proc(release: Api_Release, name: string) -> (asset: Api_Asset, ok: bool) {
    for candidate in release.assets {
        if candidate.name == name {
            return candidate, true
        }
    }
    return {}, false
}

// Whether a URL is a download of this repository's releases. The rule is an
// allowlist, not a denylist: a release payload is remote data, and a URL that
// reached the downloader would reach a shell as well. Rejecting every quote,
// space and shell metacharacter is what makes the quoting of the command string
// sufficient rather than merely hopeful.
url_is_release_download :: proc(url: string) -> bool {
    if !strings.has_prefix(url, DOWNLOAD_PREFIX) {
        return false
    }
    if strings.contains(url, "..") {
        return false
    }
    for c in url {
        if c <= ' ' || c > '~' {
            return false
        }
        switch c {
        case '"', '\'', '`', '$', '&', '|', ';', '<', '>', '^', '\\', '*', '?', '(', ')', '{', '}', '[', ']':
            return false
        }
    }
    return true
}
