package update

import "core:strings"
import "core:testing"

// year.month.patch only, and nothing that merely looks like it.
// Run from the repository root: odin test update
@(test)
test_version_parse :: proc(t: ^testing.T) {
    version, ok := version_parse("2026.08.0")
    testing.expect(t, ok, "2026.08.0 is a version")
    testing.expect_value(t, version.year, 2026)
    testing.expect_value(t, version.month, 8)
    testing.expect_value(t, version.patch, 0)

    version, ok = version_parse("2026.12.17")
    testing.expect(t, ok, "2026.12.17 is a version")
    testing.expect_value(t, version.month, 12)
    testing.expect_value(t, version.patch, 17)

    for bad in ([?]string {
        "",
        "2026",
        "2026.8",
        "2026.8.0.1",
        "2026.a.0",
        "v2026.8.0",
        "2026..0",
        " 2026.8.0",
        "2026.8.0 ",
        "-1.8.0",
        "2026.+8.0",
        "....",
    }) {
        _, bad_ok := version_parse(bad)
        testing.expectf(t, !bad_ok, "%q is not a version", bad)
    }
}

// The comparison is numeric. A text compare would call 2026.10.0 older than
// 2026.9.0 and offer the same update forever.
@(test)
test_version_less :: proc(t: ^testing.T) {
    older :: proc(t: ^testing.T, a, b: string) {
        left, left_ok := version_parse(a)
        right, right_ok := version_parse(b)
        testing.expect(t, left_ok && right_ok, "both fixtures parse")
        testing.expectf(t, version_less(left, right), "%s is older than %s", a, b)
        testing.expectf(t, !version_less(right, left), "%s is not older than %s", b, a)
    }

    older(t, "2026.9.0", "2026.10.0")
    older(t, "2026.8.0", "2026.9.0")
    older(t, "2026.8.0", "2026.8.1")
    older(t, "2026.12.9", "2027.1.0")
    older(t, "2026.8.9", "2026.8.10")

    same, _ := version_parse("2026.8.0")
    testing.expect(t, !version_less(same, same), "a version is not older than itself")
}

// The release workflow tags v<version>, so the v is required.
@(test)
test_version_from_tag :: proc(t: ^testing.T) {
    version, ok := version_from_tag("v2026.09.0")
    testing.expect(t, ok, "v2026.09.0 is a release tag")
    testing.expect_value(t, version.month, 9)

    for bad in ([?]string{"", "v", "2026.09.0", "nightly", "v2026.09.0-rc1", "vv2026.09.0"}) {
        _, bad_ok := version_from_tag(bad)
        testing.expectf(t, !bad_ok, "%q is not a release tag", bad)
    }
}

// The four names release.yml publishes, spelled out.
@(test)
test_target_asset_name :: proc(t: ^testing.T) {
    testing.expect_value(
        t,
        target_asset_name(.Windows_X64, "2026.09.0", context.temp_allocator),
        "thor-2026.09.0-windows-x86_64.zip",
    )
    testing.expect_value(
        t,
        target_asset_name(.Linux_X64, "2026.09.0", context.temp_allocator),
        "thor-2026.09.0-linux-x86_64.tar.gz",
    )
    testing.expect_value(
        t,
        target_asset_name(.Arch_X64, "2026.09.0", context.temp_allocator),
        "thor-2026.09.0-arch-x86_64.tar.gz",
    )
    testing.expect_value(
        t,
        target_asset_name(.Macos_Arm64, "2026.09.0", context.temp_allocator),
        "thor-2026.09.0-macos-arm64.tar.gz",
    )

    testing.expect_value(t, target_archive(.Windows_X64), Archive.Zip)
    testing.expect_value(t, target_archive(.Linux_X64), Archive.Tar_Gz)
    testing.expect_value(t, target_archive(.Macos_Arm64), Archive.Tar_Gz)
    testing.expect_value(t, target_exe_name(.Windows_X64), "thor.exe")
    testing.expect_value(t, target_exe_name(.Linux_X64), "thor")
}

// Only Arch and its derivatives take the Arch build.
@(test)
test_linux_flavor :: proc(t: ^testing.T) {
    testing.expect_value(t, linux_flavor("ID=arch\nNAME=\"Arch Linux\"\n"), Target.Arch_X64)
    testing.expect_value(t, linux_flavor("ID=\"arch\"\n"), Target.Arch_X64)
    testing.expect_value(t, linux_flavor("ID=manjaro\nID_LIKE=arch\n"), Target.Arch_X64)
    testing.expect_value(t, linux_flavor("ID=endeavouros\nID_LIKE=\"arch\"\n"), Target.Arch_X64)
    testing.expect_value(t, linux_flavor("ID=ubuntu\nID_LIKE=debian\n"), Target.Linux_X64)
    testing.expect_value(t, linux_flavor("ID=fedora\n"), Target.Linux_X64)
    testing.expect_value(t, linux_flavor(""), Target.Linux_X64)
    testing.expect_value(t, linux_flavor("ID=archery\n"), Target.Linux_X64)
}

// Both spellings sha256sum writes, and the forms a hand-made file carries.
@(test)
test_checksums_find :: proc(t: ^testing.T) {
    sums ::
        "1111111111111111111111111111111111111111111111111111111111111111  thor-2026.09.0-windows-x86_64.zip\r\n" +
        "2222222222222222222222222222222222222222222222222222222222222222 *thor-2026.09.0-linux-x86_64.tar.gz\n" +
        "3333333333333333333333333333333333333333333333333333333333333333  ./thor-2026.09.0-macos-arm64.tar.gz\n" +
        "deadbeef  thor-2026.09.0-arch-x86_64.tar.gz\n"

    digest, ok := checksums_find(sums, "thor-2026.09.0-windows-x86_64.zip")
    testing.expect(t, ok, "the windows archive is listed")
    testing.expect_value(t, digest, "1111111111111111111111111111111111111111111111111111111111111111")

    digest, ok = checksums_find(sums, "thor-2026.09.0-linux-x86_64.tar.gz")
    testing.expect(t, ok, "the binary-mode form is read")
    testing.expect_value(t, digest, "2222222222222222222222222222222222222222222222222222222222222222")

    digest, ok = checksums_find(sums, "thor-2026.09.0-macos-arm64.tar.gz")
    testing.expect(t, ok, "a ./ on the name is dropped")

    // A truncated digest is not a digest, so the line does not count.
    _, ok = checksums_find(sums, "thor-2026.09.0-arch-x86_64.tar.gz")
    testing.expect(t, !ok, "a short hex field is refused")

    _, ok = checksums_find(sums, "thor-2026.09.0-freebsd-x86_64.tar.gz")
    testing.expect(t, !ok, "a name that is not listed is refused")

    _, ok = checksums_find("", "thor-2026.09.0-windows-x86_64.zip")
    testing.expect(t, !ok, "an empty file lists nothing")
}

// The digest of a known string, and the case fold of the compare.
@(test)
test_sha256_bytes :: proc(t: ^testing.T) {
    // The SHA-256 of "abc", the value every implementation is checked against.
    expected :: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    digest := sha256_bytes(transmute([]byte)string("abc"))
    testing.expect(t, digest_matches(digest, expected), "the digest of abc is known")
    testing.expect(t, digest_matches(digest, strings.to_upper(expected, context.temp_allocator)),
        "the compare folds case")
    testing.expect(t, digest_matches(digest, "  " + expected + "\n"), "the compare trims space")
    testing.expect(t, !digest_matches(digest, ""), "an empty digest matches nothing")

    empty := sha256_bytes({})
    testing.expect(
        t,
        digest_matches(empty, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        "the digest of nothing is known",
    )
}

// A payload shaped like the real one, keys the struct does not declare and all.
@(test)
test_release_decode :: proc(t: ^testing.T) {
    payload ::
        `{"url":"https://api.github.com/repos/Nov0cx/Thor/releases/1",` +
        `"author":{"login":"Nov0cx","id":1,"site_admin":false},` +
        `"tag_name":"v2026.09.0","target_commitish":"master","name":"Thor 2026.09.0",` +
        `"draft":false,"prerelease":false,"created_at":"2026-09-01T00:00:00Z",` +
        `"body":"Download the archive for your platform.",` +
        `"assets":[` +
        `{"url":"https://api.github.com/repos/Nov0cx/Thor/releases/assets/1","id":1,` +
        `"name":"thor-2026.09.0-windows-x86_64.zip","label":null,` +
        `"uploader":{"login":"github-actions[bot]","id":2},` +
        `"content_type":"application/zip","state":"uploaded","size":41234567,"download_count":3,` +
        `"browser_download_url":"https://github.com/Nov0cx/Thor/releases/download/v2026.09.0/thor-2026.09.0-windows-x86_64.zip"},` +
        `{"id":2,"name":"SHA256SUMS","size":412,` +
        `"browser_download_url":"https://github.com/Nov0cx/Thor/releases/download/v2026.09.0/SHA256SUMS"}` +
        `]}`

    release, ok := release_decode(transmute([]byte)string(payload), context.temp_allocator)
    testing.expect(t, ok, "the payload decodes")
    testing.expect_value(t, release.tag_name, "v2026.09.0")
    testing.expect_value(t, release.draft, false)
    testing.expect_value(t, release.prerelease, false)
    testing.expect_value(t, len(release.assets), 2)
    testing.expect_value(t, release.body, "Download the archive for your platform.")

    asset, found := release_find_asset(release, "thor-2026.09.0-windows-x86_64.zip")
    testing.expect(t, found, "the windows archive is an asset")
    testing.expect_value(t, asset.size, 41234567)
    testing.expect(t, url_is_release_download(asset.browser_download_url), "its download is ours")

    _, found = release_find_asset(release, SUMS_ASSET)
    testing.expect(t, found, "SHA256SUMS is an asset")

    _, found = release_find_asset(release, "thor-2026.09.0-linux-x86_64.tar.gz")
    testing.expect(t, !found, "an asset that is not there is not found")
}

// Anything but a payload returns false rather than panicking.
@(test)
test_release_decode_bad :: proc(t: ^testing.T) {
    for bad in ([?]string {
        "",
        "{",
        `{"tag_name":`,
        "[]",
        "null",
        "not json at all",
        `{"draft":false}`,
    }) {
        _, ok := release_decode(transmute([]byte)bad, context.temp_allocator)
        testing.expectf(t, !ok, "%q does not decode", bad)
    }
}

// The allowlist. A release payload is remote data, so this is the line between
// the downloader and a URL somebody else chose.
@(test)
test_url_is_release_download :: proc(t: ^testing.T) {
    good :: "https://github.com/Nov0cx/Thor/releases/download/v2026.09.0/thor-2026.09.0-linux-x86_64.tar.gz"
    testing.expect(t, url_is_release_download(good), "the published form is accepted")

    for bad in ([?]string {
        "",
        "http://github.com/Nov0cx/Thor/releases/download/v2026.09.0/thor.tar.gz",
        "https://evil.example/Nov0cx/Thor/releases/download/v2026.09.0/thor.tar.gz",
        "https://github.com.evil.example/Nov0cx/Thor/releases/download/v2026.09.0/thor.tar.gz",
        "https://github.com/Someone/Else/releases/download/v2026.09.0/thor.tar.gz",
        "https://github.com/Nov0cx/Thor/releases/download/../../../etc/passwd",
        `https://github.com/Nov0cx/Thor/releases/download/v1/a" && calc.exe && "`,
        "https://github.com/Nov0cx/Thor/releases/download/v1/a`whoami`",
        "https://github.com/Nov0cx/Thor/releases/download/v1/a$(whoami)",
        "https://github.com/Nov0cx/Thor/releases/download/v1/a b.tar.gz",
        "https://github.com/Nov0cx/Thor/releases/download/v1/a\nb.tar.gz",
    }) {
        testing.expectf(t, !url_is_release_download(bad), "%q is refused", bad)
    }
}

// The command strings, for every tool, asserted from whichever platform runs
// the tests.
@(test)
test_commands :: proc(t: ^testing.T) {
    url :: "https://github.com/Nov0cx/Thor/releases/download/v2026.09.0/thor.tar.gz"
    agent :: "Thor/2026.08.0 (+https://github.com/Nov0cx/Thor)"

    curl := download_command(.Curl, url, ".update/thor.tar.gz", agent, context.temp_allocator)
    testing.expect(t, strings.contains(curl, "\"" + url + "\""), "the url is quoted")
    testing.expect(t, strings.contains(curl, "\".update/thor.tar.gz\""), "the destination is quoted")
    testing.expect(t, strings.contains(curl, "--proto =https"), "no protocol downgrade")
    testing.expect(t, strings.contains(curl, "-C -"), "the transfer resumes")
    testing.expect(t, strings.contains(curl, agent), "the user agent is sent")

    shell := download_command(.Powershell, url, ".update/thor.zip", agent, context.temp_allocator)
    testing.expect(t, strings.contains(shell, url), "the url is passed")
    testing.expect(t, strings.contains(shell, "Invoke-WebRequest"), "powershell downloads")
    testing.expect(t, downloader_resumes(.Curl), "curl resumes")
    testing.expect(t, !downloader_resumes(.Powershell), "powershell does not")

    api := api_command(.Curl, API_URL, ".update/api.json", agent, context.temp_allocator)
    testing.expect(t, strings.contains(api, "X-GitHub-Api-Version"), "the api version is pinned")
    testing.expect(t, strings.contains(api, "%{http_code}"), "the status code is printed")

    for extractor in ([?]Extractor{.Tar, .Expand_Archive}) {
        command := extract_command(extractor, ".update/thor.zip", ".update/x", context.temp_allocator)
        testing.expect(t, strings.contains(command, ".update/thor.zip"), "the archive is named")
        testing.expect(t, strings.contains(command, ".update/x"), "the destination is named")
    }

    testing.expect_value(t, len(archive_extractors(.Zip)), 2)
    testing.expect_value(t, len(archive_extractors(.Tar_Gz)), 1)
    testing.expect_value(t, archive_extractors(.Tar_Gz)[0], Extractor.Tar)
}

// The mark of the web comes off the whole staged tree, not only its top level:
// the binary that the swap relaunches sits one directory down.
@(test)
test_unblock_command :: proc(t: ^testing.T) {
    command := unblock_command(".update/x/thor-2026.08.2-windows-x86_64", context.temp_allocator)
    testing.expect(t, strings.contains(command, "Unblock-File"), "the mark comes off")
    testing.expect(
        t,
        strings.contains(command, "'.update/x/thor-2026.08.2-windows-x86_64'"),
        "the staged root is quoted",
    )
    testing.expect(t, strings.contains(command, "-Recurse"), "every file below it is reached")
    testing.expect(t, strings.contains(command, "-NoProfile"), "no user profile runs")
}

// The status code is the last field of the output, whatever the tool printed
// before it.
@(test)
test_http_code :: proc(t: ^testing.T) {
    testing.expect_value(t, http_code("200"), 200)
    testing.expect_value(t, http_code("200\n"), 200)
    testing.expect_value(t, http_code("curl: (22) The requested URL returned error 403\n403"), 403)
    testing.expect_value(t, http_code(""), 0)
    testing.expect_value(t, http_code("curl: (6) Could not resolve host: api.github.com"), 0)
}
