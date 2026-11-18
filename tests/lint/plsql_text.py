"""The comments and the string literals of SQL and PL/SQL source, read in ONE pass (2026-11-17).

The checks used to strip them with successive regular expressions: strings first, then comments (an apostrophe in a
comment -- "the quote's sheet" -- opened a literal that swallowed the code up to the next quote, and check_decl_order
missed sal_quote_uc.g_vat_notes after a subprogram), or comments first (a "--" inside a literal cut the line). A
single left-to-right scan decides at each position whether it is in code, a line comment, a block comment, a literal
('...' with '' doubled) or a q-quoted literal (q'[...]', q'{...}', q'<...>', q'(...)', q'!...!'), as the Oracle
lexer does.

    mask(text)                      # comments and literals blanked, newlines and positions kept
    mask(text, strings=False)       # comments only
"""

import re

_CLOSE = {'[': ']', '{': '}', '<': '>', '(': ')'}
_Q = re.compile(r"[nN]?[qQ]'(.)", re.S)


def _blank(chunk):
    return re.sub(r'[^\n]', ' ', chunk)


def spans(text):
    """the comments and the literals of text, in order: (kind, start, end, inner) -- kind 'comment' or 'string', start
    and end the offsets of the whole (quotes included), inner the content of a literal ('' undoubled) or of a
    comment; one scan, the Oracle lexer's (2026-11-18, middleware-docs 98 P11: the tokens of a migration)"""
    out, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '-' and text.startswith('--', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(('comment', i, j, text[i + 2:j]))
            i = j
        elif ch == '/' and text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(('comment', i, j, text[i + 2:max(i + 2, j - 2)]))
            i = j
        elif ch in 'nNqQ' and _Q.match(text, i) and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] in '_$#')):
            m = _Q.match(text, i)
            close = _CLOSE.get(m.group(1), m.group(1)) + "'"
            j = text.find(close, m.end())
            j = n if j < 0 else j + 2
            out.append(('string', i, j, text[m.end():max(m.end(), j - 2)]))
            i = j
        elif ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if text.startswith("''", j):
                        j += 2
                        continue
                    break
                j += 1
            j = min(j + 1, n)
            out.append(('string', i, j, text[i + 1:max(i + 1, j - 1)].replace("''", "'")))
            i = j
        else:
            k = i + 1
            while k < n and text[k] not in "-/'nNqQ":
                k += 1
            i = k
    return out


def mask(text, comments=True, strings=True):
    """text with its comments and/or string literals replaced by spaces (newlines kept, so lines and offsets hold);
    a literal keeps its quotes, so code like x := '' stays code-shaped"""
    out, pos = [], 0
    for kind, a, b, _ in spans(text):
        out.append(text[pos:a])
        chunk = text[a:b]
        if kind == 'comment' and comments:
            out.append(_blank(chunk))
        elif kind == 'string' and strings:
            m = _Q.match(chunk)
            if m and chunk[0] in 'nNqQ':
                out.append(chunk[:m.end()] + _blank(chunk[m.end():-2]) + chunk[-2:] if len(chunk) >= m.end() + 2 else chunk)
            else:
                out.append("'" + _blank(chunk[1:-1]) + "'" if len(chunk) >= 2 else chunk)
        else:
            out.append(chunk)
        pos = b
    out.append(text[pos:])
    return ''.join(out)
