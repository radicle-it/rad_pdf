#!/usr/bin/env python3
"""The golden-PDF bench of RAD_PDF: the same documents, the same bytes.

    python3 tests/golden/bench.py install           install src/ in the test schema (src/install.sql)
    python3 tests/golden/bench.py record            run the corpus and write the reference PDFs to tests/golden/ref/
    python3 tests/golden/bench.py check [NAME ...]  run the corpus again and compare it with the references
    python3 tests/golden/bench.py selftest          the comparison levels on synthetic PDFs, record and check on a
                                                    simulated database (no database)

The corpus: every docs/sample*.sql and docs/template_sample*.sql, plus tests/golden/extra/*.sql. Each file runs in a
FRESH session (one SQLcl process each: a document never depends on the documents before it, unless the file itself
makes several -- the two-document cases of extra/ do), after rad_pdf_ctx.set_fixed_clock: CreationDate, ModDate and the
XMP dates are a fixed instant (and so is SYSDATE in the text of a sample), and /ID is a hash of the bytes, so a document is the same bytes at every run. Before
every DBMS_LOB.FREETEMPORARY(l_pdf) of a file the bench inserts a call of rad_pdf_test_dump(<file>_<n>, l_pdf), a
procedure of the test schema that prints the PDF as hex (PDFNAME:/PDFHEX: lines); a file that frees no l_pdf is
reported as giving no document.

check compares each document with its reference and says the first level that holds:
    BYTES   identical bytes, as produced (no normalization: the clock is fixed and /ID is a hash of the bytes)
    STREAMS identical after qpdf --qdf --object-streams=disable --deterministic-id (decompressed, renumbered)
    PIXELS  identical pages rendered by pdftoppm (150 dpi), same page count
    DIFFERS none of the three: the number of pages and of differing pixels per page are printed
    ERROR   a tool failed (qpdf or pdftoppm exit status not 0, no page rendered): never an equivalence
and runs veraPDF (flavour 2b) on every document that declares PDF/A (pdfaid in its XMP).

Every dump point is required, except one whose FREETEMPORARY is guarded on its line (IF l_pdf IS NOT NULL THEN, IF
DBMS_LOB.ISTEMPORARY(l_pdf)=1 THEN): that is the cleanup of an error path. A file must give exactly its required
documents, in record and in check.

check FAILS (exit 1) on DIFFERS, ERROR, a veraPDF failure, a document missing or not in the manifest, a corpus file
that fails unexpectedly (an error, other documents than its dump points require or the manifest says), a manifest file
no longer in the corpus, a reference whose SHA-256 is not the manifest's, and a selection that matches nothing. The
files that cannot run in a plain test schema are listed in KNOWN_FAILING with the reason and the error they must show:
another error, or documents, fail the check. PIXELS passes: it is the level of a change that is meant to keep the
pages (say it in the commit).

record runs the corpus into a staging directory and replaces tests/golden/ref/ only if every file ran as expected
(unexpected errors abort it, the old references stay; the new ones are copied beside and swapped in), with MANIFEST.json: the commit of the sources, the clock, the
documents of each file and their SHA-256.

The connection (never on a command line: the script goes to SQLcl on stdin):
    RAD_PDF_TNS_ADMIN  the wallet            (default ~/wallets/db26aifree01)
    RAD_PDF_DSN        the service           (default db26aifree01_tp)
    RAD_PDF_USER       the test schema       (default rcapancioni)
    RAD_PDF_PASSWORD   its password, else the macOS Keychain internet password of RAD_PDF_KEYCHAIN (default
                       db.db26aifree01.radicle.it) for RAD_PDF_USER
"""
import hashlib
import json
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
# files that cannot give a document in a plain test schema: they must fail (reason in the report)
# (reason, the error the output must show: another error of the same file is unexpected)
KNOWN_FAILING = {
    'sample11.sql': ('writes the PDF to an Oracle directory object', r'ORA-29280'),
    'sample12.sql': ('needs the EMP/DEPT demo tables and its own table', r'PLS-00103|ORA-00942'),
    'sample21.sql': ('loads a font from an Oracle directory object', r'ORA-29280'),
    'template_sample03.sql': ('ORA-06502 in RAD_PDF_TEMPLATE (open, pre-existing: doc 96 E1 report)',
                              r'ORA-06502: .*buffer too small'),
}
DUMP_PROC = """CREATE OR REPLACE PROCEDURE rad_pdf_test_dump(p_name IN VARCHAR2, p_pdf IN BLOB) IS
  -- the golden bench (tests/golden/bench.py): the PDF as hex lines on DBMS_OUTPUT; a test object, never in src/
  l_pos PLS_INTEGER := 1;
BEGIN
  DBMS_OUTPUT.ENABLE(NULL);  -- no 1 MB buffer limit: large documents
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


# a FREETEMPORARY(l_pdf) guarded on its line (IF l_pdf IS NOT NULL / IF DBMS_LOB.ISTEMPORARY(l_pdf)=1 THEN ...) is the
# cleanup of an error path: its dump is optional and must NOT appear in a good run; every other dump is required
GUARDED = re.compile(r'IF\s+(l_pdf\s+IS\s+NOT\s+NULL|DBMS_LOB\.ISTEMPORARY\s*\(\s*l_pdf\s*\)\s*=\s*1)\s+THEN\s*$', re.I)


def instrument(path):
    """the file with a dump before every FREETEMPORARY(l_pdf), the clock fixed first; returns (script, required
    dump names)"""
    text = path.read_text(encoding='utf-8')
    n, required = 0, []

    def dump(m):
        nonlocal n
        n += 1
        name = f'{path.stem}_{n}'
        if not GUARDED.search(m.string[m.string.rfind('\n', 0, m.start()) + 1:m.start()]):
            required.append(name)
        return f"rad_pdf_test_dump('{name}', l_pdf); " + m.group(0)
    text = re.sub(r'DBMS_LOB\.FREETEMPORARY\s*\(\s*l_pdf\s*\)', dump, text, flags=re.I)
    # the samples print the time of the run (SYSDATE in titles and footers): the same fixed instant as the clock
    text = re.sub(r'\bSYSDATE\b', "TO_DATE('2026-01-01','YYYY-MM-DD')", text, flags=re.I)
    return f'exec rad_pdf_ctx.set_fixed_clock({CLOCK});\nwhenever sqlerror exit sql.sqlcode\n' + text, required


def selected(only):
    files = [f for f in corpus() if not only or any(o.startswith(f.stem) or f.stem.startswith(o) for o in only)]
    if not files:
        sys.exit(f'no corpus file matches {only}')
    return files


def run(outdir, only=None):
    """run the selected corpus into outdir; returns (documents per file, problems)"""
    outdir.mkdir(parents=True, exist_ok=True)
    rc, out = sqlcl(DUMP_PROC)
    if rc or 'compiled' not in out.lower():
        sys.exit('cannot create rad_pdf_test_dump:\n' + out[-2000:])
    per_file, problems = {}, []
    for f in selected(only):
        script, required = instrument(f)
        if not required:
            problems.append(f'{f.name}: frees no l_pdf -- no document')
            continue
        rc, out = sqlcl(script, cwd=f.parent)
        docs, name = {}, None
        for line in out.splitlines():
            if line.startswith('PDFNAME:'):
                name = line[8:].strip()
                if name in docs:
                    problems.append(f'{f.name}: {name} dumped twice (a loop around FREETEMPORARY)')
                docs[name] = []
            elif line.startswith('PDFHEX:') and name:
                docs[name].append(line[7:].strip())
        err = [l for l in out.splitlines() if re.search(r'ORA-|PLS-|SP2-|Error', l)][:3]
        if f.name in KNOWN_FAILING:
            reason, signature = KNOWN_FAILING[f.name]
            if rc and not docs and re.search(signature, out):
                print(f'{f.name}: fails as known -- {reason}', flush=True)
                continue
            problems.append(f'{f.name}: listed in KNOWN_FAILING ({signature}) but rc={rc}, {len(docs)} document(s) '
                            f'{" | ".join(err)}: update the list')
        elif rc or not docs:
            problems.append(f'{f.name}: rc={rc}, {len(docs)} document(s) {" | ".join(err)}')
        elif sorted(docs) != sorted(required):
            problems.append(f'{f.name}: documents {sorted(docs)}, the dump points require {sorted(required)}')
        for name, chunks in docs.items():
            (outdir / f'{name}.pdf').write_bytes(bytes.fromhex(''.join(chunks)))
        per_file[f.name] = sorted(docs)
        print(f'{f.name}: {len(docs)} document(s)', flush=True)
    return per_file, problems


class ToolError(Exception):
    pass


def tool(args):
    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode != 0:  # qpdf: 2 errors, 3 warnings (a warning is not accepted either); pdftoppm: 0 only
        raise ToolError(f'{args[0]} exit {p.returncode}: {(p.stderr or p.stdout).strip()[:200]}')


def qdf(path, tmp):
    out = tmp / (path.stem + '.' + path.parent.name + '.qdf')
    tool(['qpdf', '--qdf', '--object-streams=disable', '--deterministic-id', str(path), str(out)])
    return out.read_bytes()


def pages(path, tmp):
    prefix = tmp / (path.stem + '.' + path.parent.name)
    tool(['pdftoppm', '-r', '150', str(path), str(prefix)])
    found = sorted(tmp.glob(prefix.name + '-*.ppm'))
    if not found:
        raise ToolError(f'pdftoppm rendered no page of {path.name}')
    return found


def ppm_pixels(p):
    data = p.read_bytes()
    m = re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', data)
    if not m:
        raise ToolError(f'not a P6 image: {p.name}')
    return int(m[1]), int(m[2]), data[m.end():]


def compare(ref, new):
    if ref.read_bytes() == new.read_bytes():
        return 'BYTES', ''
    try:
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
    except ToolError as e:
        return 'ERROR', str(e)


def verapdf(path):
    exe = shutil.which('verapdf') or '/opt/homebrew/bin/verapdf'
    p = subprocess.run([exe, '--flavour', '2b', '--format', 'text', str(path)], capture_output=True, text=True)
    out = (p.stdout + p.stderr).strip()
    return 'PASS' if re.search(r'^PASS\b', out, re.M) else 'FAIL ' + out.splitlines()[-1][:160] if out else 'FAIL'


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'install':
        rc, out = sqlcl('@install.sql', cwd=ROOT / 'src', timeout=1800)
        bad = [l for l in out.splitlines() if re.search(r'ORA-|PLS-|SP2-|Errors for', l)]
        print(out[-1500:] if rc or bad else 'installed: src/install.sql, no error')
        sys.exit(1 if rc or bad else 0)
    if cmd == 'record':
        do_record()
        return
    if cmd == 'check':
        do_check(sys.argv[2:] or None)
    if cmd == 'selftest':
        selftest()
        return
    sys.exit(__doc__)


def do_record():
    stage = Path(tempfile.mkdtemp(prefix='rad_pdf_golden_record_'))
    per_file, problems = run(stage)
    if problems:
        for p in problems:
            print('  ERROR', p)
        sys.exit(f'record aborted, the references in {REF} are unchanged (staging: {stage})')
    commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(['git', 'status', '--porcelain', 'src'], cwd=ROOT, capture_output=True,
                                text=True).stdout.strip())
    manifest = {'commit': commit, 'src_dirty': dirty, 'clock': CLOCK,
                'files': {f: {d: sha256(stage / f'{d}.pdf') for d in docs} for f, docs in per_file.items()}}
    (stage / 'MANIFEST.json').write_text(json.dumps(manifest, indent=1, sort_keys=True) + '\n')
    # publish: copy beside, then swap; the old references stay until the new ones are complete
    new, old = REF.with_name('ref.new'), REF.with_name('ref.old')
    for d in (new, old):
        if d.exists():
            shutil.rmtree(d)
    shutil.copytree(stage, new)
    if REF.exists():
        REF.rename(old)
    new.rename(REF)
    if old.exists():
        shutil.rmtree(old)
    print(f'recorded {len(list(REF.glob("*.pdf")))} reference PDF(s) in {REF}')


def do_check(only):
    manifest = json.loads((REF / 'MANIFEST.json').read_text())['files']
    out = Path(tempfile.mkdtemp(prefix='rad_pdf_golden_'))
    per_file, problems = run(out, only)
    # the recorded inventory: a manifest file that the corpus no longer has is missing, not forgotten
    corpus_names = {x.name for x in corpus()}
    for f in sorted(manifest):
        if f not in corpus_names and (not only or any(f.startswith(o) or o.startswith(f[:-4]) for o in only)):
            problems.append(f'{f}: in the manifest, not in the corpus (its documents are MISSING)')
    # the references are the recorded ones
    for f, docs in manifest.items():
        for d, digest in docs.items():
            ref = REF / f'{d}.pdf'
            if not ref.exists() or sha256(ref) != digest:
                problems.append(f'{d}: the reference differs from its SHA-256 in the manifest')
    for f, docs in per_file.items():
        if f in manifest and sorted(manifest[f]) != docs:
            problems.append(f'{f}: documents {docs}, the manifest says {sorted(manifest[f])}')
    expected = {d for f in manifest for d in manifest[f]
                if not only or any(f.startswith(o) or o.startswith(f[:-4]) for o in only)}
    produced = {d for docs in per_file.values() for d in docs}
    counts = {}
    failed = bool(problems)
    for name in sorted(expected | produced):
        if name not in produced:
            print(f'MISSING  {name}'); failed = True; continue
        if name not in expected:
            print(f'NEW      {name} (no reference: record it)'); failed = True; continue
        level, why = compare(REF / f'{name}.pdf', out / f'{name}.pdf')
        counts[level] = counts.get(level, 0) + 1
        failed |= level in ('DIFFERS', 'ERROR')
        line = f'{level:8} {name}' + (f'  [{why}]' if why else '')
        if b'pdfaid' in (out / f'{name}.pdf').read_bytes():
            v = verapdf(out / f'{name}.pdf')
            failed |= v != 'PASS'
            line += f'  veraPDF {v}'
        print(line)
    for p in problems:
        print('  ERROR', p)
    print('result: ' + ', '.join(f'{v} {k}' for k, v in sorted(counts.items())) + (' -- FAILED' if failed else ' -- ok'))
    print(f'output in {out}')
    sys.exit(1 if failed else 0)


def tiny_pdf(text):
    """a valid one-page PDF showing text, uncompressed, with an exact xref"""
    content = b'BT /F1 12 Tf 20 100 Td (' + text + b') Tj ET'
    objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
            b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R '
            b'/Resources << /Font << /F1 5 0 R >> >> >>',
            b'<< /Length ' + str(len(content)).encode() + b' >>\nstream\n' + content + b'\nendstream',
            b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    out, offs = bytearray(b'%PDF-1.4\n'), []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        out += f'{i} 0 obj\n'.encode() + o + b'\nendobj\n'
    xref = len(out)
    out += f'xref\n0 {len(objs) + 1}\n0000000000 65535 f \n'.encode()
    out += b''.join(f'{o:010d} 00000 n \n'.encode() for o in offs)
    out += f'trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    return bytes(out)


def selftest():
    """the comparison itself, without a database: the counterexamples of codex-034 R1 and R2"""
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)

        def pdf(name, data):
            (d / name).write_bytes(data)
            return d / name
        same_a, same_b = pdf('same_a.pdf', tiny_pdf(b'HELLO')), pdf('same_b.pdf', tiny_pdf(b'HELLO'))
        # text that looks like XMP metadata, on pages that really differ (R1: a normalization hid it)
        meta_a = pdf('meta_a.pdf', tiny_pdf(b'<xmp:CreateDate>AAAA<'))
        meta_b = pdf('meta_b.pdf', tiny_pdf(b'<xmp:CreateDate>BBBB<'))
        # two different malformed files (R2: two qpdf failures gave STREAMS)
        bad_a, bad_b = pdf('bad_a.pdf', b'%PDF-1.4\ngarbage A\n'), pdf('bad_b.pdf', b'%PDF-1.4\ngarbage B\n')
        cases = [('identical documents', same_a, same_b, 'BYTES'),
                 ('metadata-like text, different pages', meta_a, meta_b, 'DIFFERS'),
                 ('two malformed files', bad_a, bad_b, 'ERROR')]
        failed = False
        for label, a, b, want in cases:
            got = compare(a, b)[0]
            failed |= got != want
            print(f'{"PASS" if got == want else "FAIL"}  {label}: {got} (expected {want})')
        failed |= not selftest_corpus(d)
    sys.exit(1 if failed else 0)


def selftest_corpus(d):
    """record and check on a simulated database (codex-036 R2): a partial generation does not publish, a corpus file
    removed after the record is MISSING, a guarded (error-path) dump is not required"""
    g = globals()
    saved = {k: g[k] for k in ('sqlcl', 'corpus', 'REF')}
    src = d / 'corpus'
    src.mkdir()
    free = 'DBMS_LOB.FREETEMPORARY(l_pdf);\n'
    (src / 'kept.sql').write_text('BEGIN\n' + free + 'END;\n')
    (src / 'guarded.sql').write_text('BEGIN\n' + free + 'EXCEPTION WHEN OTHERS THEN\n'
                                     '  IF l_pdf IS NOT NULL THEN ' + free + 'END;\n')
    (src / 'partial.sql').write_text('BEGIN\n' + free + free + 'END;\n')
    files = {'kept', 'guarded'}

    def fake_sqlcl(script, cwd=None, timeout=900):
        if 'CREATE OR REPLACE PROCEDURE rad_pdf_test_dump' in script:
            return 0, 'Procedure RAD_PDF_TEST_DUMP compiled'
        names = re.findall(r"rad_pdf_test_dump\('([^']+)'", script)
        out = []
        for n in names:
            if n.endswith('_2'):  # the second dump: the error path of guarded, the dump partial loses
                continue
            out += ['PDFNAME:' + n, 'PDFHEX:' + tiny_pdf(n.encode()).hex()]
        return 0, '\n'.join(out)
    g['sqlcl'] = fake_sqlcl
    g['corpus'] = lambda: sorted(src / f'{x}.sql' for x in files)
    g['REF'] = d / 'ref'
    ok = True

    def expect(label, fn, want_exit):
        nonlocal ok
        try:
            fn()
            code = 0
        except SystemExit as e:
            code = 0 if e.code in (None, 0) else 1
        good = code == want_exit
        ok &= good
        print(f'{"PASS" if good else "FAIL"}  {label}: exit {code} (expected {want_exit})', flush=True)
    try:
        expect('record of a complete corpus (one guarded error-path dump)', do_record, 0)
        before = sorted(p.name for p in g['REF'].iterdir())
        files.add('partial')
        expect('record with a partial generation aborts', do_record, 1)
        after = sorted(p.name for p in g['REF'].iterdir())
        good = before == after
        ok &= good
        print(f'{"PASS" if good else "FAIL"}  the references are intact after the aborted record', flush=True)
        files.discard('partial')
        expect('check of the recorded corpus', lambda: do_check(None), 0)
        files.discard('guarded')
        expect('check after a corpus file was removed (its document MISSING)', lambda: do_check(None), 1)
    finally:
        g.update(saved)
    return ok


if __name__ == '__main__':
    main()
