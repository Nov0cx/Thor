package update

// The swap mechanics over a scratch directory. Everything above them —
// thor_swap_and_relaunch's teardown order and the relaunch — needs a live editor
// and a window, so it is not covered here.
// Run from the repository root: odin test update

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// A directory of its own for one test, removed when it returns. TEMP is Windows
// only; POSIX names it TMPDIR and leaves it unset on the CI runners.
@(private = "file")
scratch :: proc(t: ^testing.T, name: string) -> (dir: string, ok: bool) {
    base := os.get_env("TEMP", context.temp_allocator)
    when ODIN_OS != .Windows {
        if base == "" {
            base = os.get_env("TMPDIR", context.temp_allocator)
        }
        if base == "" {
            base = "/tmp"
        }
    }
    base = strings.trim_right(base, "/\\")
    joined, join_err := filepath.join({base, fmt.tprintf("thor_%s_%d", name, time.now()._nsec)}, context.temp_allocator)
    if join_err != nil {
        testing.expectf(t, false, "could not build a scratch path: %v", join_err)
        return "", false
    }
    if err := os.make_directory_all(joined); err != nil {
        testing.expectf(t, false, "could not make %q: %v", joined, err)
        return "", false
    }
    return joined, true
}

@(private = "file")
drop :: proc(dir: string) {
    if err := os.remove_all(dir); err != nil {
        // A scratch directory the OS keeps costs the test nothing.
        return
    }
}

@(private = "file")
at :: proc(dir: string, name: string) -> string {
    joined, _ := filepath.join({dir, name}, context.temp_allocator)
    return joined
}

// Writes `content` to dir/name, creating the parent directories it needs.
@(private = "file")
write :: proc(t: ^testing.T, dir: string, name: string, content: string) {
    path := at(dir, name)
    if parent := os.dir(path); parent != "" {
        if err := os.make_directory_all(parent); err != nil && !os.is_dir(parent) {
            testing.expectf(t, false, "could not make %q: %v", parent, err)
            return
        }
    }
    if err := os.write_entire_file(path, transmute([]byte) content); err != nil {
        testing.expectf(t, false, "could not write %q: %v", path, err)
    }
}

// Whether dir/name holds exactly `want`. A missing or unreadable file is false.
@(private = "file")
holds :: proc(dir: string, name: string, want: string) -> bool {
    data, err := os.read_entire_file(at(dir, name), context.temp_allocator)
    return err == nil && string(data) == want
}

@(private = "file")
present :: proc(dir: string, name: string) -> bool {
    return os.exists(at(dir, name))
}

// The new copy lands and the one it replaced waits under its .old name.
@(test)
test_swap_files_replaces_and_backs_up :: proc(t: ^testing.T) {
    root, ok := scratch(t, "swap_files")
    if !ok {
        return
    }
    defer drop(root)

    install, staged := at(root, "install"), at(root, "staged")
    write(t, install, "thor.bin", "old binary")
    write(t, install, "lib.so", "old library")
    write(t, staged, "thor.bin", "new binary")
    write(t, staged, "lib.so", "new library")

    failed, swapped := swap_files(install, staged, {"thor.bin", "lib.so"})
    testing.expectf(t, swapped, "the swap must go through, stopped on %q", failed)
    testing.expect(t, holds(install, "thor.bin", "new binary"), "the new binary must be in place")
    testing.expect(t, holds(install, "lib.so", "new library"), "the new library must be in place")
    testing.expect(t, holds(install, "thor.bin" + OLD_SUFFIX, "old binary"), "the old binary must be kept")
    testing.expect(t, holds(install, "lib.so" + OLD_SUFFIX, "old library"), "the old library must be kept")
}

// A name the archive does not hold stops the swap before anything moves.
@(test)
test_swap_files_refuses_an_incomplete_stage :: proc(t: ^testing.T) {
    // The refusal it reports is the wanted answer, not a failed test.
    context.logger = log.nil_logger()
    root, ok := scratch(t, "incomplete_stage")
    if !ok {
        return
    }
    defer drop(root)

    install, staged := at(root, "install"), at(root, "staged")
    write(t, install, "thor.bin", "old binary")
    write(t, install, "lib.so", "old library")
    write(t, staged, "thor.bin", "new binary")

    failed, swapped := swap_files(install, staged, {"thor.bin", "lib.so"})
    testing.expect(t, !swapped, "an incomplete stage must not swap")
    testing.expect_value(t, failed, "lib.so")
    testing.expect(t, holds(install, "thor.bin", "old binary"), "the install must be untouched")
    testing.expect(t, holds(install, "lib.so", "old library"), "the install must be untouched")
    testing.expect(t, !present(install, "thor.bin" + OLD_SUFFIX), "nothing may have moved aside")
    testing.expect(t, !present(install, "lib.so" + OLD_SUFFIX), "nothing may have moved aside")
}

// A copy that fails part-way puts every name back and leaves no half build.
@(test)
test_swap_files_rolls_back_a_failed_copy :: proc(t: ^testing.T) {
    // The copy it reports is the wanted answer, not a failed test.
    context.logger = log.nil_logger()
    root, ok := scratch(t, "rollback")
    if !ok {
        return
    }
    defer drop(root)

    install, staged := at(root, "install"), at(root, "staged")
    write(t, install, "thor.bin", "old binary")
    write(t, install, "lib.so", "old library")
    write(t, staged, "thor.bin", "new binary")
    // A directory passes the existence check and then refuses to copy as a file,
    // which is the failure the rollback exists for.
    if err := os.make_directory_all(at(staged, "lib.so")); err != nil {
        testing.expectf(t, false, "could not make the unreadable source: %v", err)
        return
    }

    failed, swapped := swap_files(install, staged, {"thor.bin", "lib.so"})
    testing.expect(t, !swapped, "a failed copy must not report a swap")
    testing.expect_value(t, failed, "lib.so")
    testing.expect(t, holds(install, "thor.bin", "old binary"), "the first name must be back")
    testing.expect(t, holds(install, "lib.so", "old library"), "the second name must be back")
    testing.expect(t, !present(install, "thor.bin" + OLD_SUFFIX), "no backup may be left over")
    testing.expect(t, !present(install, "lib.so" + OLD_SUFFIX), "no backup may be left over")
}

// The backup an earlier update left is replaced, not kept.
@(test)
test_swap_files_replaces_an_earlier_backup :: proc(t: ^testing.T) {
    root, ok := scratch(t, "stale_backup")
    if !ok {
        return
    }
    defer drop(root)

    install, staged := at(root, "install"), at(root, "staged")
    write(t, install, "thor.bin", "old binary")
    write(t, install, "thor.bin" + OLD_SUFFIX, "ancient binary")
    write(t, staged, "thor.bin", "new binary")

    failed, swapped := swap_files(install, staged, {"thor.bin"})
    testing.expectf(t, swapped, "the swap must go through, stopped on %q", failed)
    testing.expect(t, holds(install, "thor.bin", "new binary"), "the new binary must be in place")
    testing.expect(t, holds(install, "thor.bin" + OLD_SUFFIX, "old binary"), "the backup must be the build just replaced")
}

// A staged directory replaces its live one; one the stage does not hold is left
// exactly as it was.
@(test)
test_swap_dirs_replaces_present_and_skips_absent :: proc(t: ^testing.T) {
    root, ok := scratch(t, "swap_dirs")
    if !ok {
        return
    }
    defer drop(root)

    install, staged := at(root, "install"), at(root, "staged")
    write(t, install, "assets/icons.json", "old icons")
    write(t, install, "docs/index.md", "own docs")
    write(t, staged, "assets/icons.json", "new icons")

    replaced, failed := swap_dirs(install, staged, {"assets", "docs"})
    testing.expect_value(t, replaced, 1)
    testing.expect_value(t, failed, 0)
    testing.expect(t, holds(install, "assets/icons.json", "new icons"), "the staged directory must land")
    testing.expect(t, holds(install, "assets" + OLD_SUFFIX + "/icons.json", "old icons"), "the old directory must be kept")
    testing.expect(t, holds(install, "docs/index.md", "own docs"), "a directory the stage misses is left alone")
    testing.expect(t, !present(install, "docs" + OLD_SUFFIX), "a skipped directory is not moved aside")
}

// A backup whose live name is gone comes back; one whose live name is there is
// dropped; a name with no backup is not touched.
@(test)
test_restore_names_puts_back_and_prunes :: proc(t: ^testing.T) {
    root, ok := scratch(t, "restore")
    if !ok {
        return
    }
    defer drop(root)

    write(t, root, "gone" + OLD_SUFFIX, "the build before the swap")
    write(t, root, "both", "the new build")
    write(t, root, "both" + OLD_SUFFIX, "the build before the swap")
    write(t, root, "solo", "never swapped")

    restore_names(root, {"gone", "both", "solo"})
    testing.expect(t, holds(root, "gone", "the build before the swap"), "an interrupted swap must be undone")
    testing.expect(t, !present(root, "gone" + OLD_SUFFIX), "the backup goes with the restore")
    testing.expect(t, holds(root, "both", "the new build"), "a completed swap must be kept")
    testing.expect(t, !present(root, "both" + OLD_SUFFIX), "a completed swap drops its backup")
    testing.expect(t, holds(root, "solo", "never swapped"), "a name no swap touched is left alone")
}

// One list drives both the swap and the restore, so a name the swap gains
// cannot escape it.
@(test)
test_swapped_names_covers_the_swap :: proc(t: ^testing.T) {
    names := swapped_names()
    testing.expect_value(t, len(names), len(LOCKED_NAMES) + len(SWAPPED_DIRS))

    for wanted in LOCKED_NAMES {
        testing.expectf(t, slice_holds(names, wanted), "the restore misses the locked name %q", wanted)
    }
    for wanted in SWAPPED_DIRS {
        testing.expectf(t, slice_holds(names, wanted), "the restore misses the directory %q", wanted)
    }
}

@(private = "file")
slice_holds :: proc(names: []string, wanted: string) -> bool {
    for name in names {
        if name == wanted {
            return true
        }
    }
    return false
}

// Only the JSON files are carried, and a target that is already there says so
// rather than carrying anything a second time.
@(test)
test_migrate_json_files :: proc(t: ^testing.T) {
    root, ok := scratch(t, "migrate")
    if !ok {
        return
    }
    defer drop(root)

    from, to := at(root, "settings"), at(root, "user")
    write(t, from, "settings.json", "{\"font_size\":16}")
    write(t, from, "keybinds.json", "{}")
    write(t, from, "notes.txt", "not a setting")
    // A directory named like a settings file, which the suffix alone would take.
    write(t, from, "themes.json/dark.json", "{}")

    carried, migrated := migrate_json_files(from, to)
    testing.expect(t, migrated, "a missing target must be created")
    testing.expect_value(t, carried, 2)
    testing.expect(t, holds(to, "settings.json", "{\"font_size\":16}"), "settings.json must be carried")
    testing.expect(t, present(to, "keybinds.json"), "keybinds.json must be carried")
    testing.expect(t, !present(to, "notes.txt"), "only JSON files are carried")
    testing.expect(t, !present(to, "themes.json"), "a directory is not carried")

    carried, migrated = migrate_json_files(from, to)
    testing.expect(t, !migrated, "a target that is already there is left alone")
    testing.expect_value(t, carried, 0)
}
