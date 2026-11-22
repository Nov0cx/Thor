package lang

import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
Merge_Probe :: struct {
    path:    string,
    message: string,
    saw_by:  bool, // merge_by was set when this link ran
    expire:  bool, // spends the budget, as a slow backend would
    ran:     bool,
}

@(private = "file")
probe_report :: proc(data: rawptr, req: ^Request, res: ^Result) {
    probe := cast(^Merge_Probe)data
    probe.ran = true
    probe.saw_by = req.merge_by != {}
    if probe.expire {
        req.merge_by = time.tick_now()
    }
    res.ok = true
    res.report.scope = strings.clone(probe.path)
    res.report.items = make([dynamic]Diagnostic)
    append(&res.report.items, Diagnostic{path = strings.clone(probe.path), message = strings.clone(probe.message), line = 1, col = 1})
}

// Two producers' reports stay apart, each named by its link.
@(test)
test_chain_diagnostics_keep_each_source :: proc(t: ^testing.T) {
    a     := Merge_Probe{path = "a.chain", message = "from a"}
    b     := Merge_Probe{path = "a.chain", message = "from b"}
    links := []Link{{id = "first", data = &a, resolve = probe_report}, {id = "second", data = &b, resolve = probe_report}}
    req   := Request{kind = .Diagnostics}
    res   := Result{kind = .Diagnostics}
    resolve_links(links, &req, &res)
    defer result_release(&res)

    testing.expect(t, res.ok)
    testing.expect_value(t, res.report.source, "first")
    testing.expect_value(t, len(res.related), 1)
    if len(res.related) == 1 {
        testing.expect_value(t, res.related[0].report.source, "second")
        testing.expect_value(t, res.related[0].report.items[0].message, "from b")
    }
    testing.expect(t, req.merge_by == {}, "the budget outlived the chain")
}

// Once a link answered, later links see the budget, and a spent budget skips the rest.
@(test)
test_chain_merge_budget_skips_late_links :: proc(t: ^testing.T) {
    a     := Merge_Probe{path = "a.chain", message = "a"}
    b     := Merge_Probe{path = "a.chain", message = "b", expire = true}
    c     := Merge_Probe{path = "a.chain", message = "c"}
    links := []Link{{id = "a", data = &a, resolve = probe_report}, {id = "b", data = &b, resolve = probe_report}, {id = "c", data = &c, resolve = probe_report}}
    req   := Request{kind = .Diagnostics}
    res   := Result{kind = .Diagnostics}
    resolve_links(links, &req, &res)
    defer result_release(&res)

    testing.expect(t, !a.saw_by, "the first link had a budget")
    testing.expect(t, b.saw_by, "the second link had no budget")
    testing.expect(t, !c.ran, "a link ran after the budget was spent")
    testing.expect_value(t, len(res.related), 1)
}
