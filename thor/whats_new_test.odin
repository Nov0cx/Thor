package thor

import "core:strings"
import "core:testing"

@(test)
test_whats_new_section_reads_one_version :: proc(t: ^testing.T) {
    text     := "# 2026.12.0\n\n- new\n\n# 2026.11.1\r\n\r\n- middle\r\n\r\n# 2026.11.0\n\n- old\n"
    body, ok := whats_new_section(text, "2026.11.1")
    testing.expect(t, ok)
    testing.expect_value(t, body, "- middle")

    body, ok = whats_new_section(text, "2026.11.0")
    testing.expect(t, ok)
    testing.expect_value(t, body, "- old")

    body, ok = whats_new_section(text, "2026.12.0")
    testing.expect(t, ok)
    testing.expect_value(t, body, "- new")

    _, ok = whats_new_section(text, "2026.11")
    testing.expect(t, !ok)
    _, ok = whats_new_section("", "2026.11.0")
    testing.expect(t, !ok)
}

// A `## heading` inside a version is part of its body, not its end.
@(test)
test_whats_new_section_keeps_subheadings :: proc(t: ^testing.T) {
    body, ok := whats_new_section("# 1.0.0\n## Odin\n- a\n# 0.9.0\n- b\n", "1.0.0")
    testing.expect(t, ok)
    testing.expect_value(t, body, "## Odin\n- a")
}

// The release step writes both: the card has nothing to show for a version
// without them.
@(test)
test_whats_new_covers_the_version :: proc(t: ^testing.T) {
    summary, ok := whats_new_section(WHATS_NEW_SOURCE, VERSION)
    testing.expectf(t, ok, "WHATS_NEW.md has no `# %s` heading", VERSION)
    testing.expectf(t, strings.contains(summary, "- "), "the summary of %s has no bullets", VERSION)
    _, ok = whats_new_section(CHANGELOG_SOURCE, VERSION)
    testing.expectf(t, ok, "CHANGELOG.md has no `# %s` heading", VERSION)
}
