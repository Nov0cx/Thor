package thor

import "core:strings"
import "core:testing"

// Every accepted flag spelling, and the arguments that must stay paths.
// Run from the repository root: odin test thor
@(test)
test_cli_action :: proc(t: ^testing.T) {
    testing.expect_value(t, thor_cli_action({"thor"}), Cli_Action.Open)
    testing.expect_value(t, thor_cli_action({}), Cli_Action.Open)

    for arg in ([?]string{"--version", "-version", "-v"}) {
        testing.expect_value(t, thor_cli_action({"thor", arg}), Cli_Action.Version)
    }
    for arg in ([?]string{"--help", "-help", "-h", "-?"}) {
        testing.expect_value(t, thor_cli_action({"thor", arg}), Cli_Action.Help)
    }

    // The workspace argument a shell launch and a new window both pass.
    testing.expect_value(t, thor_cli_action({"thor", "."}), Cli_Action.Open)
    testing.expect_value(t, thor_cli_action({"thor", "D:\\thor"}), Cli_Action.Open)
    testing.expect_value(t, thor_cli_action({"thor", "/home/user/thor"}), Cli_Action.Open)
    testing.expect_value(t, thor_cli_action({"thor", "--versions"}), Cli_Action.Open)
}

// The version is year.month.patch, the form the changelog headings use.
@(test)
test_version_format :: proc(t: ^testing.T) {
    parts := strings.split(VERSION, ".", context.temp_allocator)
    testing.expect_value(t, len(parts), 3)
    for part in parts {
        testing.expect(t, len(part) > 0, "each version field needs digits")
        for c in part {
            testing.expect(t, c >= '0' && c <= '9', "the version must hold digits only")
        }
    }
}
