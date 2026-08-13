package update

// The commands the fetch layer runs. There is no HTTP client in the editor, so
// a download is a shell-out to whatever the machine has.
//
// The tool is a parameter and not a `when ODIN_OS`, which is the same choice
// watch/scan.odin makes for the same reason: every platform's command string
// stays assertable from any one of them.

import "core:fmt"
import "core:strings"

// What fetches a URL. curl ships with Windows 10 1803 and later, macOS and most
// Linux; PowerShell is the Windows fallback for the rest.
Downloader :: enum {
    Curl,
    Powershell,
}

// What unpacks an archive. Windows' tar is bsdtar, which reads a zip as well as
// a tarball; Expand-Archive is the fallback and reads only a zip.
Extractor :: enum {
    Tar,
    Expand_Archive,
}

// How long one download slice may run inside curl, below SLICE_TIMEOUT so curl
// gives up before the job kills it.
@(private = "file")
SLICE_SECONDS :: 60

// A stalled transfer is one under a kilobyte a second for this long.
@(private = "file")
STALL_SECONDS :: 30

// curl's write-out for the status code. An argument and not a literal in the
// format string, where Odin's fmt would read the brace as a verb of its own.
@(private = "file")
CODE_FORMAT :: "%{http_code}"

// The User-Agent every request carries. The releases API answers 403 to a
// request without one.
user_agent :: proc(version: string, allocator := context.allocator) -> string {
    return fmt.aprintf("Thor/%s (+https://github.com/%s/%s)", version, OWNER, REPO, allocator = allocator)
}

// The command that answers whether a tool is there at all.
probe_download_command :: proc(downloader: Downloader) -> string {
    switch downloader {
    case .Curl:
        return "curl --version"
    case .Powershell:
        return "powershell -NoProfile -Command \"$PSVersionTable.PSVersion.Major\""
    }
    return ""
}

// The command that answers whether an extractor is there at all.
probe_extract_command :: proc(extractor: Extractor) -> string {
    switch extractor {
    case .Tar:
        return "tar --version"
    case .Expand_Archive:
        return "powershell -NoProfile -Command \"Get-Command Expand-Archive | Out-Null\""
    }
    return ""
}

// The command that reads the releases API into `dest` and prints the HTTP
// status code as its last output. `--proto =https` is what stops a redirect to
// http:, which -L alone would follow.
api_command :: proc(
    downloader: Downloader,
    url: string,
    dest: string,
    agent: string,
    allocator := context.allocator,
) -> string {
    switch downloader {
    case .Curl:
        return fmt.aprintf(
            `curl -sS -L --proto =https --tlsv1.2 --max-time %d -A "%s" ` +
            `-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" ` +
            `-o "%s" -w "%s" "%s"`,
            SLICE_SECONDS,
            agent,
            dest,
            CODE_FORMAT,
            url,
            allocator = allocator,
        )
    case .Powershell:
        return fmt.aprintf(
            `powershell -NoProfile -Command "$ProgressPreference='SilentlyContinue'; ` +
            `try { $r = Invoke-WebRequest -Uri '%s' -UserAgent '%s' -Headers @{Accept='application/vnd.github+json'} ` +
            `-OutFile '%s' -PassThru -TimeoutSec %d; Write-Output $r.StatusCode } ` +
            `catch { Write-Output $_.Exception.Response.StatusCode.value__ }"`,
            url,
            agent,
            dest,
            SLICE_SECONDS,
            allocator = allocator,
        )
    }
    return ""
}

// The command that downloads one slice of an archive. curl's `-C -` resumes
// from what is already on disk, which is what lets the caller loop: a slice
// that times out is retried instead of restarting the transfer, and a shutdown
// waits out one slice rather than a whole download. PowerShell has no resume,
// so its slice is the whole file.
download_command :: proc(
    downloader: Downloader,
    url: string,
    dest: string,
    agent: string,
    allocator := context.allocator,
) -> string {
    switch downloader {
    case .Curl:
        return fmt.aprintf(
            `curl -fsS -L --proto =https --tlsv1.2 -C - --max-time %d ` +
            `--speed-time %d --speed-limit 1024 -A "%s" -o "%s" "%s"`,
            SLICE_SECONDS,
            STALL_SECONDS,
            agent,
            dest,
            url,
            allocator = allocator,
        )
    case .Powershell:
        return fmt.aprintf(
            `powershell -NoProfile -Command "$ProgressPreference='SilentlyContinue'; ` +
            `Invoke-WebRequest -Uri '%s' -UserAgent '%s' -OutFile '%s' -TimeoutSec %d"`,
            url,
            agent,
            dest,
            SLICE_SECONDS,
            allocator = allocator,
        )
    }
    return ""
}

// Whether a downloader can pick a transfer up where it stopped.
downloader_resumes :: proc(downloader: Downloader) -> bool {
    return downloader == .Curl
}

// The command that unpacks `archive` into the existing directory `dir`.
extract_command :: proc(
    extractor: Extractor,
    archive: string,
    dir: string,
    allocator := context.allocator,
) -> string {
    switch extractor {
    case .Tar:
        return fmt.aprintf(`tar -xf "%s" -C "%s"`, archive, dir, allocator = allocator)
    case .Expand_Archive:
        return fmt.aprintf(
            `powershell -NoProfile -Command "Expand-Archive -LiteralPath '%s' -DestinationPath '%s' -Force"`,
            archive,
            dir,
            allocator = allocator,
        )
    }
    return ""
}

// The extractors that can read a container, best first.
archive_extractors :: proc(archive: Archive) -> []Extractor {
    @(static) zip := [?]Extractor{.Tar, .Expand_Archive}
    @(static) tar := [?]Extractor{.Tar}
    return archive == .Zip ? zip[:] : tar[:]
}

// The status code an api_command printed, which is the last field of its
// output. Zero when the command printed none, which is a request that never
// reached the server.
http_code :: proc(output: string) -> int {
    trimmed := strings.trim_space(output)
    if len(trimmed) < 3 {
        return 0
    }
    tail := trimmed[len(trimmed) - 3:]
    code := 0
    for c in tail {
        if c < '0' || c > '9' {
            return 0
        }
        code = code * 10 + int(c - '0')
    }
    return code
}
