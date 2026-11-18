#!/usr/bin/env python3
"""No character range in an Oracle regular expression except digits (2026-11-18, the third time of the same trap).

    python3 tests/lint/check_regexp_ranges.py [ROOT ...]          # default src/, tests/, docs/
    python3 tests/lint/check_regexp_ranges.py --fix FILE ...      # rewrite the letter ranges of these files

The same check as middleware-code's db/scripts/check_regexp_ranges.py (which also reads the imported core), kept
byte-equal but for this header and the default roots; plsql_text.py is middleware-code's lexer, copied.

Oracle reads a range of a bracket expression ([A-Z], [a-f], [ -~]) in the collation of NLS_SORT. SQL*Plus, the
deploys and the DB tests run with BINARY; an APEX session runs with the language of the application, ITALIAN with
NLS_COMP = LINGUISTIC. Measured on radicledevadb01 (23.26) under ITALIAN + LINGUISTIC:

  - [A-Z] matches a, à, È, ß, Æ, ø (not z); [a-z] matches é, Z, ß (not A); [0-9a-f] matches F; [0-9A-F] matches Æ;
  - [ -~] raises ORA-12728 (att's ASCII filename, 2026-10-04; rad_pdf_zip's entry names, smoke_prt 2026-11-18);
  - [!-~] matches no letter, so [^!-~] matched every letter (rad_pdf_fonts stripped every font name);
  - the ranges between ASCII digits are exact: [0-9] refuses ², ٥, ５; [1-5] refuses 6;
  - the POSIX classes and the escapes are not ASCII either: [[:upper:]] matches È, [[:xdigit:]] ａ and ５,
    [[:digit:]] and \\d match ٥ and ５ -- they are not a replacement for an ASCII range;
  - a listed member is compared exactly: [ABCZ] refuses a, à, À.

The allow-list is therefore one form: a range between two ASCII digits. Every other range is a finding; the fix is
the explicit list of the ASCII letters ([A-Z] -> [ABCDEFGHIJKLMNOPQRSTUVWXYZ], what --fix writes) or, when the set is
not letters (a byte class such as [ -~]), a check of the bytes or the codes in PL/SQL.

What is read: every SQL / PL/SQL file; in each, the string literals of the arguments of REGEXP_LIKE / _SUBSTR /
_INSTR / _REPLACE / _COUNT, and the initializer of a name such a call uses (a constant or a variable declared
`name [constant] type := ...` in the same file: a pattern kept in a constant is a pattern). Comments are not read
(plsql_text, the Oracle lexer). Exit code 1 on a finding.
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plsql_text  # noqa: E402

ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))      # the repository
CALL = re.compile(r'\bregexp_(?:like|substr|instr|replace|count)\s*\(', re.I)
IDENT = re.compile(r'\b([A-Za-z][A-Za-z0-9_$#]*(?:\.[A-Za-z][A-Za-z0-9_$#]*)?)\b')
EXT = ('.sql', '.pks', '.pkb', '.pls', '.plb', '.trg', '.fnc', '.prc')
UPPER = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
LOWER = UPPER.lower()
DIGITS = '0123456789'


def brackets(p):
    """the bracket expressions of a pattern (POSIX ERE as Oracle reads it): (start, end, items), items each a
    character, ('range', a, b) or ('class', '[:name:]' / '[=e=]' / '[.e.]'); a ']' first in the list is a member, a
    '-' first or last is a member, a backslash is a member (no escape inside brackets)"""
    out, i, n = [], 0, len(p)
    while i < n:
        c = p[i]
        if c == '\\':
            i += 2
            continue
        if c != '[':
            i += 1
            continue
        s, j = i, i + 1
        if j < n and p[j] == '^':
            j += 1
        items, first = [], True
        while j < n and (p[j] != ']' or first):
            first = False
            if p[j] == '[' and j + 1 < n and p[j + 1] in ':=.':
                k = p.find(p[j + 1] + ']', j + 2)
                if k < 0:
                    break
                items.append(('class', p[j:k + 2]))
                j = k + 2
                continue
            if j + 2 < n and p[j + 1] == '-' and p[j + 2] != ']':
                items.append(('range', p[j], p[j + 2]))
                j += 3
                continue
            items.append(p[j])
            j += 1
        if j >= n:                                      # not closed in this literal: a pattern built by pieces
            i = s + 1
            continue
        out.append((s, j + 1, items))
        i = j + 1
    return out


def safe(item):
    """the one allowed range: between two ASCII digits, in order"""
    _, a, b = item
    return a in DIGITS and b in DIGITS and a <= b


def bad_ranges(pattern):
    return [it for _, _, items in brackets(pattern) for it in items
            if isinstance(it, tuple) and it[0] == 'range' and not safe(it)]


def expand(item):
    """the explicit ASCII list of a letter range ([A-F] -> ABCDEF), or None when it is not one"""
    _, a, b = item
    for alphabet in (UPPER, LOWER):
        if a in alphabet and b in alphabet and a <= b:
            return alphabet[alphabet.index(a):alphabet.index(b) + 1]
    return None


def fixed(pattern):
    """the pattern with every letter range listed; None when a bad range is not a letter range (fix by hand)"""
    out, pos = [], 0
    for s, e, items in brackets(pattern):
        body = []
        for it in items:
            if isinstance(it, tuple) and it[0] == 'range' and not safe(it):
                x = expand(it)
                if x is None:
                    return None
                body.append(x)
            elif isinstance(it, tuple):
                body.append(it[1] if it[0] == 'class' else f'{it[1]}-{it[2]}')
            else:
                body.append(it)
        neg = '^' if pattern[s + 1:s + 2] == '^' else ''
        # the members keep their order: a '-' or a ']' member stays first or last, where it was a member
        out.append(pattern[pos:s] + '[' + neg + ''.join(body) + ']')
        pos = e
    return ''.join(out) + pattern[pos:]


def _call_ends(masked):
    """(start, end) of every regexp_* call of the masked text (comments and literals blanked), end at its ')'"""
    out = []
    for m in CALL.finditer(masked):
        depth, i = 0, m.end() - 1
        while i < len(masked):
            if masked[i] == '(':
                depth += 1
            elif masked[i] == ')':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        out.append((m.start(), i))
    return out


def _initializers(masked, name):
    """(start, end) of the initializers of name in the file: `name [constant] type := ... ;`"""
    out = []
    short = name.split('.')[-1]
    for m in re.finditer(r'\b' + re.escape(short) + r'\s+(?:constant\s+)?[A-Za-z][\w.$#%]*(?:\s*\([^)]*\))?\s*(?::=|\bdefault\b)',
                         masked, re.I):
        end = masked.find(';', m.end())
        out.append((m.end(), len(masked) if end < 0 else end))
    return out


def findings_of_text(text, label='<text>'):
    """(line, literal, bad ranges) of every pattern literal of text with a bad range"""
    spans = [(a, b, inner) for kind, a, b, inner in plsql_text.spans(text) if kind == 'string']
    masked = plsql_text.mask(text)
    regions = _call_ends(masked)
    names = set()
    for a, b in regions:
        names |= {n.lower() for n in IDENT.findall(masked[a:b + 1])}
    names -= {'regexp_like', 'regexp_substr', 'regexp_instr', 'regexp_replace', 'regexp_count'}
    for n in sorted(names):
        regions += _initializers(masked, n)
    out, seen = [], set()
    for a, b, inner in spans:
        if a in seen or not any(x <= a <= y for x, y in regions):
            continue
        seen.add(a)
        bad = bad_ranges(inner)
        if bad:
            out.append((text.count('\n', 0, a) + 1, a, b, inner, bad))
    return out


def files(roots):
    for r in roots:
        if os.path.isfile(r):
            yield r
            continue
        for p in sorted(glob.glob(os.path.join(r, '**', '*'), recursive=True)):
            if p.endswith(EXT) and os.path.isfile(p) and f'{os.sep}.git{os.sep}' not in p:
                yield p


def fmt(item):
    return f'{item[1]}-{item[2]}'


def check(roots):
    out = []
    for p in files(roots):
        with open(p, encoding='utf-8', errors='replace') as f:
            text = f.read()
        for line, _, _, inner, bad in findings_of_text(text):
            out.append(f"{os.path.relpath(p, ROOT)}:{line}: range {', '.join('[' + fmt(b) + ']' for b in bad)} in "
                       f"'{inner[:80]}': NLS_SORT-dependent (list the ASCII letters, or check bytes)")
    return out


def fix_file(path):
    """rewrite the letter ranges of path in place; returns the findings left to fix by hand"""
    with open(path, encoding='utf-8', newline='') as f:
        text = f.read()
    left, parts, pos = [], [], 0
    masked = plsql_text.mask(text)
    for line, a, b, inner, bad in findings_of_text(text):
        new = fixed(inner)
        if new is None:
            left.append(f"{path}:{line}: '{inner[:80]}' ({', '.join(fmt(x) for x in bad)}): by hand")
            continue
        # a pattern kept in a declared constant or variable: the listed letters make it longer than its size
        decl = re.search(r'varchar2\s*\(\s*(\d+)\s*(?:char|byte)?\s*\)\s*(?::=|\bdefault\b)[^;]*$',
                         masked[masked.rfind(';', 0, a) + 1:a], re.I)
        if decl and int(decl.group(1)) < len(new):
            left.append(f"{path}:{line}: the listed pattern is {len(new)} characters, declared VARCHAR2({decl.group(1)}):"
                        f" widen the declaration, then --fix again")
            continue
        raw = text[a:b]
        if raw[:1] != "'":                              # a q-quoted literal: rewrite inside its delimiters
            m = re.match(r"[nN]?[qQ]'.", raw)
            body = raw[m.end():-2]
            parts.append(text[pos:a] + raw[:m.end()] + body.replace(inner, new) + raw[-2:])
        else:
            parts.append(text[pos:a] + "'" + new.replace("'", "''") + "'")
        pos = b
    parts.append(text[pos:])
    new_text = ''.join(parts)
    if new_text != text:
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(new_text)
    return left


def main(argv):
    if argv[:1] == ['--fix']:
        left = [x for p in argv[1:] for x in fix_file(p)]
        print('\n'.join(left) if left else 'fixed: every letter range listed')
        return 1 if left else 0
    roots = argv or [os.path.join(ROOT, d) for d in ('src', 'tests', 'docs')]
    out = check(roots)
    for line in out:
        print(line)
    print(f'regexp ranges: {len(out)} finding(s)' if out else 'regexp ranges: OK (only ASCII digit ranges)')
    return 1 if out else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
