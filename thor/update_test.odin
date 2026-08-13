package thor

import "core:testing"

// The background check runs at most once a day; a manual one always runs.
// Run from the repository root: odin test thor
@(test)
test_update_due :: proc(t: ^testing.T) {
    day :: i64(24 * 60 * 60)
    now :: i64(1_800_000_000)

    testing.expect(t, thor_update_due(0, now, false), "a first run is due")
    testing.expect(t, thor_update_due(now - day, now, false), "a day later is due")
    testing.expect(t, thor_update_due(now - day - 1, now, false), "more than a day is due")
    testing.expect(t, !thor_update_due(now, now, false), "a check just now is not due")
    testing.expect(t, !thor_update_due(now - day + 1, now, false), "under a day is not due")

    // A clock that moved backwards would otherwise park the check forever.
    testing.expect(t, thor_update_due(now + day, now, false), "a future stamp is due")

    // A manual check is an explicit request and beats the throttle.
    testing.expect(t, thor_update_due(now, now, true), "a manual check is always due")
    testing.expect(t, thor_update_due(now - 1, now, true), "a manual check ignores the interval")
}

// A dismissal covers exactly the version it was given, so the next release asks
// again and the titlebar button is the only way back to the dismissed one.
@(test)
test_update_should_prompt :: proc(t: ^testing.T) {
    testing.expect(t, thor_update_should_prompt("", "2026.09.0"), "nothing dismissed yet")
    testing.expect(t, !thor_update_should_prompt("2026.09.0", "2026.09.0"), "this one was dismissed")
    testing.expect(t, thor_update_should_prompt("2026.09.0", "2026.10.0"), "a newer release asks again")
    testing.expect(t, thor_update_should_prompt("2026.09.0", "2026.09.1"), "a patch asks again")
    testing.expect(t, !thor_update_should_prompt("2026.09.0", ""), "nothing found, nothing to ask")
}
