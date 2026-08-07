# PreToolUse guard: an OS-specific import belongs only in the matching platform
# file. A shared file that imports core:sys/windows builds here and breaks the
# ubuntu, arch and macos workflows.

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try {
    $payload = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$path = $payload.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($path) -or $path -notmatch '\.odin$') { exit 0 }

# Write carries the whole file, Edit only the replacement text.
$text = @($payload.tool_input.content, $payload.tool_input.new_string) -join "`n"
if ([string]::IsNullOrWhiteSpace($text)) { exit 0 }

$leaf = Split-Path -Path $path -Leaf
$stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)

$rules = @(
    @{ Import = 'core:sys/windows'; Os = 'Windows'; Suffixes = @('_windows.odin') },
    @{ Import = 'core:sys/posix';   Os = 'POSIX';   Suffixes = @('_posix.odin') },
    @{ Import = 'core:sys/linux';   Os = 'Linux';   Suffixes = @('_posix.odin', '_linux.odin') },
    @{ Import = 'core:sys/darwin';  Os = 'macOS';   Suffixes = @('_posix.odin', '_darwin.odin') }
)

foreach ($rule in $rules) {
    if (-not $text.Contains($rule.Import)) { continue }

    $named = $false
    foreach ($suffix in $rule.Suffixes) {
        if ($leaf.EndsWith($suffix)) { $named = $true; break }
    }
    if ($named) { continue }

    $want = ($rule.Suffixes | ForEach-Object { "$stem$_" }) -join ' or '
    $import = $rule.Import
    $os = $rule.Os

    [Console]::Error.WriteLine(@"
Blocked: $leaf imports $import but is not a $os platform file.

Thor builds on Windows, Linux and macOS. A shared file that imports an
OS-specific package compiles here and breaks the other platforms' workflows.

Split it into three:
  $stem.odin - the platform-free part, plus a comment stating the types and
    procedures both platform files must supply (Odin has no forward declarations)
  ${stem}_windows.odin - tagged #+build windows
  ${stem}_posix.odin - tagged #+build !windows

Pairs to copy: shell/shell_*, watch/watch_*, thor/windows_*, thor/dialogs_*,
thor/filemap_*, thor/reveal_*.

Move this edit into $want, or keep the OS call behind the seam.
"@)
    exit 2
}

exit 0
