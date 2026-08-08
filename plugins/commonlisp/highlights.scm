; This grammar ships only queries/tags.scm upstream, no highlights.scm, so this
; plugin supplies its own — adapted from sogaiu/tree-sitter-clojure (which this
; grammar extends and shares node names with), verified against this grammar's
; own src/node-types.json. There is no bool_lit node here (Common Lisp has no
; true/false literals, only nil and non-nil). The quoting markers are CL's own
; (grammar.js overrides them), not Clojure's ~ / ~@ / @ reader macros.

[
  (num_lit)
  (complex_num_lit)
] @number

[
  (char_lit)
  (str_lit)
] @string

(nil_lit) @constant.builtin

(kwd_lit) @constant

(package_lit) @namespace

(comment) @comment

[
 "'"
 "#'"
 "`"
 ","
 ",@"
] @operator
