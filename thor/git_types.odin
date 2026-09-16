// Git data the views show and the jobs fill. It sits here rather than in a view
// because the status of a path and the rows of a diff are the same facts
// whether the explorer, the gutter or the git panel is asking.
package thor

// A path's state against the index and HEAD.
Git_Status :: enum u8 {
	None,
	Modified,
	Added,
	Untracked,
	Deleted,
	Renamed,
	Conflict,
	Submodule,
}

// What a status reads as in a hover explanation or a chip.
git_status_name :: proc(status: Git_Status) -> string {
	switch status {
	case .None:
		return ""
	case .Modified:
		return "Modified"
	case .Added:
		return "Added"
	case .Untracked:
		return "Untracked"
	case .Deleted:
		return "Deleted"
	case .Renamed:
		return "Renamed"
	case .Conflict:
		return "Merge conflict"
	case .Submodule:
		return "Submodule"
	}
	return ""
}

Git_Diff_Row_Kind :: enum u8 {
	Hunk, // @@ header
	Context,
	Added,
	Removed,
	Meta, // binary marker, missing-newline marker, truncation marker
}

// One display row of a unified diff. Line numbers are 1-based; 0 means the row
// has no line on that side.
Git_Diff_Row :: struct {
	kind:     Git_Diff_Row_Kind,
	old_line: int,
	new_line: int,
	text:     string, // owned; tabs expanded
}

git_diff_rows_destroy :: proc(rows: ^[dynamic]Git_Diff_Row) {
	for row in rows {
		delete(row.text)
	}
	delete(rows^)
}
