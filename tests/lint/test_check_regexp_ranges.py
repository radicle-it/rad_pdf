#!/usr/bin/env python3
"""Counter-proofs of check_regexp_ranges.py (2026-11-18): the two traps already met (att's [^ -~], rad_pdf_zip's
[ -~], rad_pdf_fonts' [^!-~]), the letter ranges, a pattern in a constant, and the forms that must pass; then --fix on
each letter case (the listed pattern, the members in their order) and its refusals."""
import os
import sys
import tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_regexp_ranges import findings_of_text, fixed, fix_file  # noqa: E402

CASES = [
    ("rad_pdf_zip's entry names (ORA-12728)",
     "if not regexp_like(utl_raw.cast_to_varchar2(l_raw), '^[ -~]*$') then null; end if;", 1),
    ("rad_pdf_fonts' name token ([^!-~] took every letter)", "n := REGEXP_REPLACE(n, '[^!-~]|[()<>\\[\\]{}/%#]', '');", 1),
    ("att's ASCII filename", "f := regexp_replace(p_filename, '[^ -~]', '_');", 1),
    ("a code", "if not regexp_like(p_code, '^[A-Z][A-Z0-9_]*$') then", 1),
    ("lowercase hex", "if not regexp_like(h, '^[0-9a-f]{64}$') then", 1),
    ("a pattern in a constant",
     "c_re constant varchar2(100) := '^[A-Za-z_]+$';\nbegin if regexp_like(x, c_re) then null; end if;", 1),
    ("a pattern in a qualified constant",
     "c_re constant varchar2(100) := '^[a-z]+$';\nbegin if regexp_like(x, pkg.c_re) then null; end if;", 1),
    ("a q-quoted pattern", "if regexp_like(x, q'[^[a-z]+$]') then", 1),
    ("a check constraint", "alter table t add constraint t_ck check (regexp_like(c, '^[A-Z]{3}$'));", 1),
    # what passes
    ("digits", "if regexp_like(x, '^[0-9]+([.][0-9]{1,2})?$') and regexp_like(y, '^h[1-6]$') then", 0),
    ("the ASCII letters listed", "if regexp_like(x, '^[ABCDEFGHIJKLMNOPQRSTUVWXYZ0-9_]+$') then", 0),
    ("a '-' member first or last", "if regexp_like(x, '^[-+]?[0-9]+$') or regexp_like(y, '[0-9._-]') then", 0),
    ("a ']' member first", "x := regexp_replace(y, '[]x]', '');", 0),
    ("a POSIX class is no range (and no ASCII either: not this check)", "if regexp_like(x, '[[:cntrl:]]') then", 0),
    ("an escaped bracket is no class", "n := regexp_count(p, '\\[\\]');", 0),
    ("a range outside any regexp_ call", "l_json := '[A-Z]';\nl_x := 'a-z';", 0),
    ("a range in a comment", "-- regexp_like(x, '[A-Z]')\nnull;", 0),
    ("a bracket built by pieces", "l_at := regexp_instr(l_chunk, '[' || chr(9) || chr(10) || ']');", 0),
]

FIXES = [
    ('^[A-Z][A-Z0-9_]*$', '^[ABCDEFGHIJKLMNOPQRSTUVWXYZ][ABCDEFGHIJKLMNOPQRSTUVWXYZ0-9_]*$'),
    ('^[0-9a-f]{64}$', '^[0-9abcdef]{64}$'),
    ('^[0-9A-Fa-f]{6}$', '^[0-9ABCDEFabcdef]{6}$'),
    ('[^a-z0-9._-]', '[^abcdefghijklmnopqrstuvwxyz0-9._-]'),
    ('^[A-D]$', '^[ABCD]$'),
    ('\\[[A-Z_]+\\]', '\\[[ABCDEFGHIJKLMNOPQRSTUVWXYZ_]+\\]'),
    ('[[:alpha:]a-c]', '[[:alpha:]abc]'),
    ('^[ -~]*$', None),                      # not letters: a byte check, by hand
    ('[^!-~]', None),
    ('[a-Z]', None),
]

fails = 0
for what, text, expected in CASES:
    got = len(findings_of_text(text))
    ok = got == expected
    fails += not ok
    print(f"{'OK  ' if ok else 'FAIL'} {what}: {got}" + ("" if ok else f" (expected {expected})"))
for pattern, want in FIXES:
    got = fixed(pattern)
    ok = got == want
    fails += not ok
    print(f"{'OK  ' if ok else 'FAIL'} fix {pattern!r} -> {got!r}" + ("" if ok else f" (expected {want!r})"))

# --fix on a file: the literal rewritten (a doubled quote kept), a too short declaration and a byte class left by hand
with tempfile.TemporaryDirectory() as d:
    p = os.path.join(d, 'x.sql')
    with open(p, 'w', encoding='utf-8') as f:
        f.write("c_re constant varchar2(20) := '^[A-Za-z]+$';\n"
                "begin\n  if regexp_like(a, '^[a-c'']$') and regexp_like(b, c_re) then null; end if;\n"
                "  if regexp_like(c, '^[ -~]*$') then null; end if;\nend;\n")
    left = fix_file(p)
    text = open(p, encoding='utf-8').read()
    for what, ok in [("--fix lists the letters, the doubled quote kept", "'^[abc'']$'" in text),
                     ("--fix leaves the constant too short for the list", len(left) == 2 and 'VARCHAR2(20)' in left[0]
                      and "'^[A-Za-z]+$'" in text),
                     ("--fix leaves the byte class by hand", any('by hand' in x for x in left))]:
        fails += not ok
        print(f"{'OK  ' if ok else 'FAIL'} {what}")
print(f'test_check_regexp_ranges: {fails} failure(s)')
sys.exit(1 if fails else 0)
