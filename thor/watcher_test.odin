package thor

import "core:testing"

// A lock file under `.git/` is matched in every separator spelling; other git and tree paths are not.
@(test)
test_git_lock_path :: proc(t: ^testing.T) {
    testing.expect(t, thor_git_lock_path("ws/.git/index.lock", "ws"))
    testing.expect(t, thor_git_lock_path("ws\\.git\\index.lock", "ws"))
    testing.expect(t, thor_git_lock_path("ws\\.git\\index.lock", "ws/"))
    testing.expect(t, thor_git_lock_path("a/ws\\.git/refs\\heads/main.lock", "a\\ws"))
    testing.expect(t, thor_git_lock_path("ws/.git/HEAD.lock", "ws"))

    testing.expect(t, !thor_git_lock_path("ws/.git/index", "ws"))
    testing.expect(t, !thor_git_lock_path("ws/.git/HEAD", "ws"))
    testing.expect(t, !thor_git_lock_path("ws/.git/refs/heads/main", "ws"))
    testing.expect(t, !thor_git_lock_path("ws/Cargo.lock", "ws"))
    testing.expect(t, !thor_git_lock_path("ws/src/.git.lock", "ws"))
    testing.expect(t, !thor_git_lock_path("ws/sub/.git/index.lock", "ws"))
    testing.expect(t, !thor_git_lock_path("ws2/.git/index.lock", "ws"))
    testing.expect(t, !thor_git_lock_path("other/.git/index.lock", "ws"))
    testing.expect(t, !thor_git_lock_path("ws/.github/x.lock", "ws"))
    testing.expect(t, !thor_git_lock_path("ws/.git/index.lock", ""))
    testing.expect(t, !thor_git_lock_path("ws", "ws"))

    when ODIN_OS == .Windows {
        testing.expect(t, thor_git_lock_path("WS/.GIT/index.lock", "ws"))
    } else {
        testing.expect(t, !thor_git_lock_path("WS/.git/index.lock", "ws"))
    }
}
