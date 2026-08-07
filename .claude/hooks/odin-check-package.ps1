# PostToolUse: type-checks the package of the edited file. `odin check` needs
# neither MSVC nor a window, so it is the one feedback loop that always works
# here.

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try {
    $payload = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$path = $payload.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($path) -or $path -notmatch '\.odin$') { exit 0 }

# `odin check` drops _test.odin files; only `odin test` compiles them, and that
# links, so it needs a developer shell. /verify covers the test packages.
if ($path -match '_test\.odin$') { exit 0 }

if (-not (Get-Command odin -ErrorAction SilentlyContinue)) { exit 0 }

$root = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
try {
    $full = [System.IO.Path]::GetFullPath($path)
} catch {
    exit 0
}
if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { exit 0 }

$rel = $full.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
if ($rel -match '^(vendor|bin)/') { exit 0 }

$dir = Split-Path -Path $rel -Parent
if ($dir) { $dir = $dir.Replace('\', '/') }

if ([string]::IsNullOrEmpty($dir)) {
    # A root file is its own package, e.g. build.odin.
    $odinArgs = @('check', $rel, '-file')
    $label = $rel
} elseif ($dir -eq 'main') {
    $odinArgs = @('check', 'main')
    $label = 'main'
} else {
    $odinArgs = @('check', $dir, '-no-entry-point')
    $label = $dir
}

Push-Location $root
try {
    $out = & odin @odinArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($code -ne 0) {
    [Console]::Error.WriteLine("odin check $label failed:")
    [Console]::Error.WriteLine($out.Trim())
    exit 2
}

exit 0
