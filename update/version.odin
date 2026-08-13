package update

// The release version, year.month.patch. Compared field by field and never as
// text: 2026.9.0 sorts before 2026.10.0 numerically and after it lexically.

import "core:strconv"
import "core:strings"

// A release version. Every field is non-negative.
Version :: struct {
    year:  int,
    month: int,
    patch: int,
}

// Reads "year.month.patch". Rejects a leading `v`, a sign, spaces, an empty
// field and any count of fields but three.
version_parse :: proc(s: string) -> (version: Version, ok: bool) {
    rest := s
    fields: [3]int
    for i in 0 ..< 3 {
        field: string
        if i < 2 {
            cut := strings.index_byte(rest, '.')
            if cut < 0 {
                return {}, false
            }
            field, rest = rest[:cut], rest[cut + 1:]
        } else {
            field, rest = rest, ""
        }
        if len(field) == 0 {
            return {}, false
        }
        for c in field {
            if c < '0' || c > '9' {
                return {}, false
            }
        }
        value, parsed := strconv.parse_int(field, 10)
        if !parsed {
            return {}, false
        }
        fields[i] = value
    }
    return {year = fields[0], month = fields[1], patch = fields[2]}, true
}

// Reads a release tag, "v" plus a version. The `v` is required: the release
// workflow tags `v<version>` and nothing else may pass for a release.
version_from_tag :: proc(tag: string) -> (version: Version, ok: bool) {
    if len(tag) < 2 || tag[0] != 'v' {
        return {}, false
    }
    return version_parse(tag[1:])
}

// Whether `a` is older than `b`.
version_less :: proc(a, b: Version) -> bool {
    if a.year != b.year {
        return a.year < b.year
    }
    if a.month != b.month {
        return a.month < b.month
    }
    return a.patch < b.patch
}
