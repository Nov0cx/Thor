// Finding and installing a newer Thor. The editor ships as one folder — the
// binary beside assets/, plugins/, settings/ and docs/ — so an update is a
// download of the release archive for this platform, a checksum, and a swap of
// that folder's contents.
//
// The package sits below the editor and holds no state: `check` answers what the
// latest release is, `install_apply` leaves a verified tree in a staging folder,
// and the caller performs the swap. Everything but fetch.odin and install.odin
// is pure, so the four platforms' behaviour is testable from any one of them.
//
// Two rules the rest of the package exists to keep. The download URL must match
// `url_is_release_download`, which is an allowlist over the release host and
// rejects every character a shell would read. And a release without a
// SHA256SUMS entry for its archive is never installed — that check is mandatory,
// not best effort. It comes over the same channel as the archive, so it defends
// against a corrupt or truncated download, not against a compromised release.
package update

import "core:time"

// The repository the releases are published from.
OWNER :: "Nov0cx"
REPO :: "Thor"

// The releases API. /latest excludes drafts and prereleases itself; the decoded
// flags are re-checked anyway so a later switch to /releases cannot ship one.
API_URL :: "https://api.github.com/repos/" + OWNER + "/" + REPO + "/releases/latest"

// Where the user is sent when the install cannot run.
RELEASES_URL :: "https://github.com/" + OWNER + "/" + REPO + "/releases/latest"

// The checksum file the release workflow publishes beside the archives.
SUMS_ASSET :: "SHA256SUMS"

// The staging folder, beside the executable. Removed at every start.
STAGE_DIR :: ".update"

// The suffix a replaced file is renamed to, so the running image keeps its
// inode and a swap that dies part-way can be undone.
OLD_SUFFIX :: ".old"

// An archive larger than this is refused before a byte is downloaded.
MAX_ASSET_BYTES :: 512 * 1024 * 1024

// The release body is kept for the prompt, so it is capped before it is cloned.
NOTES_MAX :: 4096

// How long each shell-out may take. None is ever unbounded: a hung curl must
// not outlive the editor.
PROBE_TIMEOUT :: 5 * time.Second
API_TIMEOUT :: 20 * time.Second
SLICE_TIMEOUT :: 120 * time.Second
EXTRACT_TIMEOUT :: 300 * time.Second
XATTR_TIMEOUT :: 30 * time.Second
UNBLOCK_TIMEOUT :: 60 * time.Second

// Why a check or an install stopped. Ok is the only success; Up_To_Date is the
// ordinary outcome of a check.
Status :: enum {
    Ok,
    Up_To_Date,
    No_Tools,
    No_Network,
    Rate_Limited,
    Bad_Response,
    Bad_Tag,
    Draft_Release,
    No_Asset,
    Bad_Url,
    Bad_Size,
    Download_Failed,
    Bad_Checksum,
    Extract_Failed,
    Bad_Archive,
    Not_Installable,
    Install_Failed,
    Cancelled,
}

// What a check found. Every string is owned by the caller's allocator and is
// empty unless the status is Ok.
Check_Result :: struct {
    status:   Status,
    version:  string, // owned; the release version, no leading v
    notes:    string, // owned; the release body, capped at NOTES_MAX
    url:      string, // owned; the validated archive download
    sums_url: string, // owned; the validated SHA256SUMS download
    asset:    string, // owned; the archive name, which is the SHA256SUMS key
    size:     i64,
    // Whether this build may install what it found. False sends the user to the
    // releases page instead — a dev tree, a directory it cannot write.
    installable: bool,
}

// What install_apply must fetch. Every string is borrowed from the caller.
Install_Plan :: struct {
    url:      string,
    sums_url: string,
    asset:    string,
    size:     i64,
    target:   Target,
}

// Where install_apply left the verified tree.
Install_Result :: struct {
    status: Status,
    root:   string, // owned; the staged folder the swap reads from
    detail: string, // owned; "" unless the status needs a line of text
}

// A one-line reason for a status, for the status bar.
status_message :: proc(status: Status) -> string {
    switch status {
    case .Ok:
        return "Ready"
    case .Up_To_Date:
        return "Thor is up to date"
    case .No_Tools:
        return "Could not find curl or tar to download the update"
    case .No_Network:
        return "Could not reach GitHub"
    case .Rate_Limited:
        return "GitHub rate limit reached, try again later"
    case .Bad_Response:
        return "GitHub answered with something unreadable"
    case .Bad_Tag:
        return "The latest release is not tagged as a version"
    case .Draft_Release:
        return "The latest release is a draft"
    case .No_Asset:
        return "The release carries no build for this platform"
    case .Bad_Url:
        return "The release names a download Thor will not follow"
    case .Bad_Size:
        return "The download is not the size the release names"
    case .Download_Failed:
        return "The download did not finish"
    case .Bad_Checksum:
        return "The download does not match its checksum"
    case .Extract_Failed:
        return "The archive did not unpack"
    case .Bad_Archive:
        return "The archive does not hold a Thor build"
    case .Not_Installable:
        return "This build cannot update itself"
    case .Install_Failed:
        return "The update could not be written"
    case .Cancelled:
        return "The update was cancelled"
    }
    return "The update stopped"
}
