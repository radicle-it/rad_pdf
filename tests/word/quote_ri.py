#!/usr/bin/env python3
"""Step B1 of the Word evolution (middleware-docs 96a §1b.1): the quote RI built by hand, its dump, and the page count
of its rendering through the existing engine against Word's export.

    python3 tests/word/quote_ri.py            run tests/word/quote_ri.sql in the test schema (connection: the golden
                                              bench's, tests/golden/bench.py) and compare:
                                              - the RI dump with tests/word/samples/sal_quote_v1_ri.json (same text);
                                              - the bridge's PDF with samples/sal_quote_v1_ri.pdf (same bytes: the
                                                clock is fixed); since B2 the bridge renders the instance of the merge
                                                (template + samples/sal_quote_v1_schema.json + data);
                                              - each negative sample refused by the merge with its [PRT_DATA] message;
                                              - the page count with sal_quote_v1_word.pdf (Word 16.111.2: 3 pages), and
                                                the lines of the table on each page (reported, not required in B1)
    python3 tests/word/quote_ri.py --record   write the RI dump and the PDF as the new references (say why in the commit)

Writes tests/word/out/ (not versioned): sal_quote_v1_ri.json and sal_quote_v1_ri.pdf. Exit 1 when the dump differs from
its reference, the PDF from its reference or the page count from Word's.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'golden'))
import bench  # noqa: E402  (connection, sqlcl, the dump procedure)

SAMPLES = HERE / 'samples'
OUT = HERE / 'out'
REF_JSON = SAMPLES / 'sal_quote_v1_ri.json'
REF_PDF = SAMPLES / 'sal_quote_v1_ri.pdf'
SCHEMA = SAMPLES / 'sal_quote_v1_schema.json'
# the negative samples of 96a section 10 and the refusal each must give (B2: the merge, with the path)
NEGATIVES = {
    'lines_not_array': '[PRT_DATA] lines: an ARRAY must be an array',
    'missing_required': '[PRT_DATA] totals.net: required, missing',
    'wrong_type': '[PRT_DATA] has_discount: a BOOLEAN must be true or false',
}


def ascii_json(path):
    """compact JSON with \\u escapes: SQLcl does not read its standard input as UTF-8"""
    text = json.dumps(json.loads(path.read_text(encoding='utf-8')), ensure_ascii=True, separators=(',', ':'))
    if "~'" in text:
        sys.exit(f"{path.name} holds ~' and cannot go in a q'~...~' literal")
    return text
WORD_PDF = SAMPLES / 'sal_quote_v1_word.pdf'


def pages(pdf):
    out = subprocess.run(['pdfinfo', str(pdf)], capture_output=True, text=True, check=True).stdout
    return int(re.search(r'^Pages:\s+(\d+)', out, re.M).group(1))


def lines_per_page(pdf):
    """the first and last line code of the table on each page"""
    res = []
    for p in range(1, pages(pdf) + 1):
        txt = subprocess.run(['pdftotext', '-f', str(p), '-l', str(p), '-layout', str(pdf), '-'],
                             capture_output=True, text=True, check=True).stdout
        codes = re.findall(r'LAV-(\d{3})', txt)
        res.append((int(codes[0]), int(codes[-1])) if codes else None)
    return res


def main():
    record = '--record' in sys.argv[1:]
    neg = '\n'.join(f"  l_neg({i}) := q'~{ascii_json(SAMPLES / f'sal_quote_v1_neg_{name}.json')}~'; l_negn({i}) := '{name}';"
                    for i, name in enumerate(NEGATIVES, start=1))
    script = (HERE / 'quote_ri.sql').read_text(encoding='utf-8') \
        .replace('@@DATA@@', ascii_json(SAMPLES / 'sal_quote_v1.json')).replace('@@SCHEMA@@', ascii_json(SCHEMA)) \
        .replace('@@NEG@@', neg)
    rc, out = bench.sqlcl(bench.DUMP_PROC)
    if rc or 'compiled' not in out.lower():
        sys.exit('cannot create rad_pdf_test_dump:\n' + out[-2000:])
    rc, out = bench.sqlcl(script, cwd=HERE)
    js, hexes, nodes, inst, negs = [], [], None, None, {}
    for line in out.splitlines():
        if line.startswith('RIJSON:'):
            js.append(line[7:])
        elif line.startswith('PDFHEX:'):
            hexes.append(line[7:].strip())
        elif line.startswith('RINODES:'):
            nodes = int(line[8:])
        elif line.startswith('INSTNODES:'):
            inst = int(line[10:])
        elif line.startswith('NEG:'):
            name, _, msg = line[4:].partition(':')
            negs[name] = msg.strip()
    if rc or not js or not hexes:
        sys.exit(f'quote_ri.sql failed (rc={rc}):\n' + out[-3000:])
    OUT.mkdir(exist_ok=True)
    ri = json.dumps(json.loads(''.join(js)), ensure_ascii=False, indent=1) + '\n'
    (OUT / 'sal_quote_v1_ri.json').write_text(ri, encoding='utf-8')
    pdf = OUT / 'sal_quote_v1_ri.pdf'
    pdf.write_bytes(bytes.fromhex(''.join(hexes)))
    ok = True
    if record:
        REF_JSON.write_text(ri, encoding='utf-8')
        REF_PDF.write_bytes(pdf.read_bytes())
        print(f'recorded: {REF_JSON.name} ({nodes} nodes), {REF_PDF.name} ({REF_PDF.stat().st_size} bytes)')
    else:
        if not REF_JSON.exists() or REF_JSON.read_text(encoding='utf-8') != ri:
            ok = False
            print(f'RI dump DIFFERS from {REF_JSON.name} (see {OUT / "sal_quote_v1_ri.json"})')
        else:
            print(f'RI dump identical to {REF_JSON.name} ({nodes} nodes)')
        if not REF_PDF.exists() or REF_PDF.read_bytes() != pdf.read_bytes():
            ok = False
            print(f'PDF DIFFERS from {REF_PDF.name} (see {pdf})')
        else:
            print(f'PDF identical to {REF_PDF.name} ({REF_PDF.stat().st_size} bytes)')
    print(f'merge: the instance has {inst} nodes')
    for name, want in NEGATIVES.items():
        got = negs.get(name)
        good = got == want
        ok = ok and good
        print(f'negative {name}: {"refused as expected" if good else "WRONG"} -- {got}')
    ours, word = pages(pdf), pages(WORD_PDF)
    print(f'pages: engine {ours}, Word {word} -> {"SAME" if ours == word else "DIFFERENT"}')
    print(f'table lines per page: engine {lines_per_page(pdf)}, Word {lines_per_page(WORD_PDF)}')
    ok = ok and ours == word
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
