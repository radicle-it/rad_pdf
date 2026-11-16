#!/usr/bin/env python3
"""The golden-PDF bench of RAD_PDF: the same documents, the same bytes.

    python3 tests/golden/bench.py install           install src/ in the test schema (src/install.sql)
    python3 tests/golden/bench.py record            run the corpus and write the reference PDFs to tests/golden/ref/
    python3 tests/golden/bench.py check [NAME ...]  run the corpus again and compare it with the references

The corpus: every docs/sample*.sql and docs/template_sample*.sql, plus tests/golden/extra/*.sql. Each file runs in a
FRESH session (one SQLcl process each: a document never depends on the documents before it, unless the file itself
makes several -- the two-document cases of extra/ do), after rad_pdf_ctx.set_fixed_clock: CreationDate, ModDate and the
XMP dates are a fixed instant (and so is SYSDATE in the text of a sample), and /ID is a hash of the bytes, so a document is the same bytes at every run. Before
every DBMS_LOB.FREETEMPORARY(l_pdf) of a file the bench inserts a call of rad_pdf_test_dump(<file>_<n>, l_pdf), a
procedure of the test schema that prints the PDF as hex (PDFNAME:/PDFHEX: lines); a file that frees no l_pdf is
reported as giving no document.

check compares each document on three levels and says the first one that holds:
    BYTES   identical bytes (after removing dates and /ID, in case a file sets its own)
    STREAMS identical after qpdf --qdf --object-streams=disable (decompressed, renumbered): the same content, other bytes
    PIXELS  identical pages rendered by pdftoppm (150 dpi): the same image, other content streams
    DIFFERS none of the three: the number of pages and of differing pixels per page are printed
and runs veraPDF (flavour 2b) on every document that declares PDF/A (pdfaid in its XMP).

The connection (never on a command line: the script goes to SQLcl on stdin):
    RAD_PDF_TNS_ADMIN  the wallet            (default ~/wallets/db26aifree01)
    RAD_PDF_DSN        the service           (default db26aifree01_tp)
    RAD_PDF_USER       the test schema       (default rcapancioni)
    RAD_PDF_PASSWORD   its password, else the macOS Keychain internet password of RAD_PDF_KEYCHAIN (default
                       db.db26aifree01.radicle.it) for RAD_PDF_USER
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GOLDEN = ROOT / 'tests' / 'golden'
REF = GOLDEN / 'ref'
CLOCK = "TIMESTAMP '2026-01-01 00:00:00'"
SQL = shutil.which('sql') or '/opt/sqlcl/bin/sql'
DUMP_PROC = """CREATE OR REPLACE PROCEDURE rad_pdf_test_dump(p_name IN VARCHAR2, p_pdf IN BLOB) IS
  -- the golden bench (tests/golden/bench.py): the PDF as hex lines on DBMS_OUTPUT; a test object, never in src/
  l_pos PLS_INTEGER := 1;
BEGIN
  DBMS_OUTPUT.PUT_LINE('PDFNAME:' || p_name);
  WHILE l_pos <= DBMS_LOB.GETLENGTH(p_pdf) LOOP
    DBMS_OUTPUT.PUT_LINE('PDFHEX:' || RAWTOHEX(DBMS_LOB.SUBSTR(p_pdf, 12000, l_pos)));
    l_pos := l_pos + 12000;
  END LOOP;
END rad_pdf_test_dump;
/
"""


def connection():
    user = os.environ.get('RAD_PDF_USER', 'rcapancioni')
    pwd = os.environ.get('RAD_PDF_PASSWORD')
    if not pwd:
        pwd = subprocess.run(['security', 'find-internet-password', '-s',
                              os.environ.get('RAD_PDF_KEYCHAIN', 'db.db26aifree01.radicle.it'), '-a', user, '-w'],
                             capture_output=True, text=True).stdout.strip()
    if not pwd:
        sys.exit('no password: set RAD_PDF_PASSWORD or the Keychain entry (see the docstring)')
    return user, pwd, os.environ.get('RAD_PDF_DSN', 'db26aifree01_tp')


def sqlcl(script, cwd=None, timeout=900):
    """run a script in a fresh SQLcl session (the password only on stdin); returns (rc, output)"""
    user, pwd, dsn = connection()
    env = dict(os.environ, TNS_ADMIN=os.path.expanduser(os.environ.get('RAD_PDF_TNS_ADMIN', '~/wallets/db26aifree01')))
    head = f'connect {user}/"{pwd}"@{dsn}\nset define off\nset sqlblanklines on\nset serveroutput on size unlimited\n'
    p = subprocess.run([SQL, '-S', '/nolog'], input=head + script + '\nexit\n', capture_output=True, text=True,
                       cwd=cwd, env=env, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def corpus():
    files = sorted((ROOT / 'docs').glob('sample*.sql')) + sorted((ROOT / 'docs').glob('template_sample*.sql'))
    files += sorted((GOLDEN / 'extra').glob('*.sql'))
    return files


def instrument(path):
    """the file with a dump before every FREETEMPORARY(l_pdf), the clock fixed first"""
    text = path.read_text(encoding='utf-8')
    n = 0

    def dump(m):
        nonlocal n
        n += 1
        return f"rad_pdf_test_dump('{path.stem}_{n}', l_pdf); " + m.group(0)
    text = re.sub(r'DBMS_LOB\.FREETEMPORARY\s*\(\s*l_pdf\s*\)', dump, text, flags=re.I)
    # the samples print the time of the run (SYSDATE in titles and footers): the same fixed instant as the clock
    text = re.sub(r'\bSYSDATE\b', "TO_DATE('2026-01-01','YYYY-MM-DD')", text, flags=re.I)
    return f'exec rad_pdf_ctx.set_fixed_clock({CLOCK});\nwhenever sqlerror exit sql.sqlcode\n' + text, n


def run(outdir, only=None):
    outdir.mkdir(parents=True, exist_ok=True)
    rc, out = sqlcl(DUMP_PROC)
    if rc or 'Procedure RAD_PDF_TEST_DUMP compiled' not in out and 'compiled' not in out.lower():
        sys.exit('cannot create rad_pdf_test_dump:\n' + out[-2000:])
    problems = []
    for f in corpus():
        if only and f.stem not in only and not any(o.startswith(f.stem) for o in only):
            continue
        script, n = instrument(f)
        if not n:
            problems.append(f'{f.name}: frees no l_pdf -- no document')
            continue
        rc, out = sqlcl(script, cwd=f.parent)
        docs = {}
        name = None
        for line in out.splitlines():
            if line.startswith('PDFNAME:'):
                name = line[8:].strip()
                docs[name] = []
            elif line.startswith('PDFHEX:') and name:
                docs[name].append(line[7:].strip())
        if rc or not docs:
            err = [l for l in out.splitlines() if re.search(r'ORA-|PLS-|SP2-|Error', l)][:3]
            problems.append(f'{f.name}: rc={rc}, {len(docs)} document(s) {" | ".join(err)}')
        for name, chunks in docs.items():
            (outdir / f'{name}.pdf').write_bytes(bytes.fromhex(''.join(chunks)))
        print(f'{f.name}: {len(docs)} document(s)', flush=True)
    return problems


NORMALIZE = [(re.compile(rb'/(CreationDate|ModDate)\s*\(D:[^)]*\)'), rb'/\1 (D:X)'),
             (re.compile(rb'/ID\s*\[<[0-9A-Fa-f]*>\s*<[0-9A-Fa-f]*>\]'), rb'/ID [<X> <X>]'),
             (re.compile(rb'<(xmp:(?:CreateDate|ModifyDate|MetadataDate))>[^<]*<'), rb'<\1>X<')]


def normalized(data):
    for rx, rep in NORMALIZE:
        data = rx.sub(rep, data)
    return data


def qdf(path, tmp):
    out = tmp / (path.stem + '.' + path.parent.name + '.qdf')
    subprocess.run(['qpdf', '--qdf', '--object-streams=disable', '--deterministic-id', str(path), str(out)],
                   capture_output=True)
    return normalized(out.read_bytes()) if out.exists() else b''


def pages(path, tmp):
    prefix = tmp / (path.stem + '.' + path.parent.name)
    subprocess.run(['pdftoppm', '-r', '150', str(path), str(prefix)], capture_output=True)
    return sorted(tmp.glob(prefix.name + '-*.ppm'))


def ppm_pixels(p):
    data = p.read_bytes()
    m = re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', data)
    return int(m[1]), int(m[2]), data[m.end():]


def compare(ref, new):
    if normalized(ref.read_bytes()) == normalized(new.read_bytes()):
        return 'BYTES', ''
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        if qdf(ref, tmp) == qdf(new, tmp):
            return 'STREAMS', ''
        a, b = pages(ref, tmp), pages(new, tmp)
        if len(a) != len(b):
            return 'DIFFERS', f'pages {len(a)} -> {len(b)}'
        diffs = []
        for i, (pa, pb) in enumerate(zip(a, b), 1):
            wa, ha, da = ppm_pixels(pa)
            wb, hb, db = ppm_pixels(pb)
            if (wa, ha) != (wb, hb):
                diffs.append(f'p{i} size {wa}x{ha} -> {wb}x{hb}')
            elif da != db:
                n = sum(1 for k in range(0, len(da), 3) if da[k:k + 3] != db[k:k + 3])
                diffs.append(f'p{i} {n} px')
        return ('PIXELS', '') if not diffs else ('DIFFERS', ', '.join(diffs))


def verapdf(path):
    exe = shutil.which('verapdf') or '/opt/homebrew/bin/verapdf'
    p = subprocess.run([exe, '--flavour', '2b', '--format', 'text', str(path)], capture_output=True, text=True)
    out = (p.stdout + p.stderr).strip()
    return 'PASS' if re.search(r'^PASS\b', out, re.M) else 'FAIL ' + out.splitlines()[-1][:160] if out else 'FAIL'


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'install':
        rc, out = sqlcl('@install.sql', cwd=ROOT / 'src', timeout=1800)
        bad = [l for l in out.splitlines() if re.search(r'ORA-|PLS-|SP2-|Errors for', l)]
        print(out[-1500:] if rc or bad else 'installed: src/install.sql, no error')
        sys.exit(1 if rc or bad else 0)
    if cmd == 'record':
        if REF.exists():
            shutil.rmtree(REF)
        problems = run(REF)
        print(f'recorded {len(list(REF.glob("*.pdf")))} reference PDF(s) in {REF.relative_to(ROOT)}')
        for p in problems:
            print('  NOTE', p)
        return
    if cmd == 'check':
        only = sys.argv[2:] or None
        out = Path(tempfile.mkdtemp(prefix='rad_pdf_golden_'))
        problems = run(out, only)
        refs = {p.stem: p for p in REF.glob('*.pdf')}
        news = {p.stem: p for p in out.glob('*.pdf')}
        worst = 0
        rank = {'BYTES': 0, 'STREAMS': 1, 'PIXELS': 2, 'DIFFERS': 3}
        for name in sorted(set(refs) | set(news)):
            if only and not any(name.startswith(o) for o in only):
                continue
            if name not in news:
                print(f'MISSING  {name}'); worst = 3; continue
            if name not in refs:
                print(f'NEW      {name} (no reference)'); continue
            level, why = compare(refs[name], news[name])
            worst = max(worst, rank[level])
            pdfa = b'pdfaid' in news[name].read_bytes()
            print(f'{level:8} {name}' + (f'  [{why}]' if why else '') + (f'  veraPDF {verapdf(news[name])}' if pdfa else ''))
        for p in problems:
            print('  NOTE', p)
        print(f'output in {out}')
        sys.exit(1 if worst == 3 else 0)
    sys.exit(__doc__)


if __name__ == '__main__':
    main()
