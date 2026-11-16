#!/usr/bin/env python3
"""The importable core of RAD_PDF checked on its own (middleware-docs 96a §1b; codex-054, codex-058):

    python3 tests/import/check_core.py

On the test schema (the golden bench's connection):
  0. src/install_core.sql installs exactly src/import_core.lst, in its order;
  1. every RAD_PDF object dropped (zero left), then ONLY the core installed (src/install_core.sql) -- the core must
     compile without the flowable layer, the markup engine and the extensions;
  2. the schema holds exactly the units the manifest's files create (specifications and bodies, types and type bodies:
     parsed from their CREATE statements), all VALID, and nothing else named RAD_PDF*;
  3. dependencies (USER_DEPENDENCIES, every unit): no edge from a core unit to a schema object outside the list, and
     the paginator's closure by NAME -- every unit (spec and body) of each name reached is visited -- holds only names
     of the list;
  4. no dynamic PL/SQL in the core's post-processed bodies, PACKAGE BODY and TYPE BODY (DBMS_PREPROCESSOR; the page
     procedures of E6 compiled out); every expected body must be scanned;
  5. the core's own suites run on it: phase23 (RI), phase24 (merge), phase25 (pager; needs tests/word/load_fonts.py),
     and the Word reader's cases (tests/word/docx_cases.py, a Python driver: its exit code and its summary line);
  6. the full product installed again (src/install.sql) -- always, also after a failure above -- with the product's
     own units all VALID: a failed restore is reported as such;
  7. in the product: the cycle layout <-> table gone, layout free of the Swiss QR-bill, rad_pdf_doc free of the
     flowable layer.

Every SQL check runs through run(): it fails on a non-zero exit, on an ORA-/PLS-/SP2- error line (except the suites,
whose negative tests print expected ORA- texts) and on a missing completion marker; a check that did not run is
never read as a check without violations. The offline sensitivity tests are tests/import/test_check_core.py.
Exit 1 when any check fails. The log is printed; keep it as the evidence of a review.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'src'
NOT_IMPORTED = ['RAD_PDF', 'RAD_PDF_FLOW', 'RAD_PDF_LAYOUT', 'RAD_PDF_TABLE', 'RAD_PDF_TEMPLATE', 'RAD_PDF_SWISS',
                'RAD_PDF_BARCODE', 'RAD_PDF_CHART']
SUITES = [('phase23_ri', 'Phase 23 RI'), ('phase24_merge', 'Phase 24 merge'), ('phase25_pager', 'Phase 25 pager')]
PY_SUITES = [('tests/word/docx_cases.py', r'docx cases: OK \(\d+ cases\)')]
OURS = "(object_name = 'RAD_PDF' OR object_name LIKE 'RAD\\_PDF\\_%' ESCAPE '\\')"
UNIT_TYPES = "('PACKAGE', 'PACKAGE BODY', 'TYPE', 'TYPE BODY')"
ERROR_LINE = re.compile(r'^\s*(ORA|PLS|SP2)-\d{4,5}\b|^Error starting at line|^Error report', re.M)
CREATE = re.compile(r'^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(?:(?:NON)?EDITIONABLE\s+)?'
                    r'(PACKAGE\s+BODY|PACKAGE|TYPE\s+BODY|TYPE)\s+"?(\w+)"?', re.I | re.M)
DROP_ALL = f"""
BEGIN
  FOR r IN (SELECT object_name, object_type FROM user_objects
             WHERE object_type IN ('PACKAGE', 'TYPE') AND {OURS}
             ORDER BY CASE object_type WHEN 'PACKAGE' THEN 1 ELSE 2 END,
                      CASE WHEN object_name IN ('RAD_PDF_IMG_DECODER', 'RAD_PDF_IMG_DATA') THEN 2 ELSE 1 END) LOOP
    EXECUTE IMMEDIATE 'DROP ' || r.object_type || ' ' || r.object_name || CASE r.object_type WHEN 'TYPE' THEN ' FORCE' END;
  END LOOP;
END;
/
SELECT 'LEFT:' || COUNT(*) FROM user_objects WHERE {OURS} AND object_type IN {UNIT_TYPES};
"""


def run(sqlcl, label, script, cwd=None, timeout=900, scan_errors=True):
    """one SQL check: (good, problems, output). WHENEVER SQLERROR stops it on the first error; the completion marker
    DONE:<label> must come back on a line of its own, else the check did not complete."""
    body = (f'WHENEVER SQLERROR EXIT FAILURE ROLLBACK\nWHENEVER OSERROR EXIT FAILURE ROLLBACK\n{script}\n'
            f"SET PAGESIZE 0 FEEDBACK OFF HEADING OFF\nSELECT 'DONE:{label}' FROM dual;\n")
    try:
        rc, out = sqlcl(body, cwd=cwd, timeout=timeout)
    except Exception as e:  # a timeout or a missing client is a failed check, never a pass
        return False, [f'client: {type(e).__name__}: {e}'], ''
    problems = []
    if rc != 0:
        problems.append(f'exit code {rc}')
    if scan_errors:
        problems += [f'error line: {m.group(0).strip()}' for m in ERROR_LINE.finditer(out)][:5]
    if not re.search(rf'^DONE:{label}\s*$', out, re.M):
        problems.append('no completion marker')
    return not problems, problems, out


def rows(out, tag):
    return [l.strip()[len(tag) + 1:] for l in out.splitlines() if l.strip().startswith(tag + ':')]


def manifest():
    files = []
    for line in (SRC / 'import_core.lst').read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            files.append(line)
    return files


def install_files(script):
    return [l.strip()[2:] for l in (SRC / script).read_text().splitlines() if l.strip().startswith('@@')]


def units(files):
    """the (NAME, TYPE) units the files create, from their CREATE statements"""
    out = set()
    for f in files:
        for kind, name in CREATE.findall((SRC / f).read_text(encoding='utf-8')):
            out.add((name.upper(), re.sub(r'\s+', ' ', kind.upper())))
    return out


def closure(deps, start):
    """names reached from start, visiting EVERY unit (spec and body) of each name reached: deps are
    (name, type, referenced_name, referenced_type) rows"""
    by_name = {}
    for name, _type, ref, _rtype in deps:
        by_name.setdefault(name, set()).add(ref)
    seen, todo = {start}, [start]
    while todo:
        for ref in by_name.get(todo.pop(), ()):
            if ref not in seen:
                seen.add(ref)
                todo.append(ref)
    return seen


def run_py(script, timeout=3600):
    """a Python suite of the repository: (exit code, output)"""
    import subprocess
    p = subprocess.run([sys.executable, str(ROOT / script)], capture_output=True, text=True, timeout=timeout, cwd=ROOT)
    return p.returncode, p.stdout + p.stderr


def main(sqlcl=None, py=run_py):
    if sqlcl is None:
        sys.path.insert(0, str(ROOT / 'tests' / 'golden'))
        import bench  # noqa: E402
        sqlcl = bench.sqlcl
    failures = []

    def check(step, good, text, detail=None):
        print(f'{step} {text}: {"OK" if good else "FAILED"}')
        for d in (detail or []) if not good else []:
            print(f'     {d}')
        if not good:
            failures.append(f'{step} {text}')
        return good

    files = manifest()
    core_units = units(files)
    core = sorted({n for n, _ in core_units})
    names_sql = ', '.join(f"'{n}'" for n in core)
    bodies = sorted(u for u in core_units if u[1].endswith('BODY'))
    check('0.', install_files('install_core.sql') == files,
          f'install_core.sql installs import_core.lst ({len(files)} files, {len(core)} names, {len(core_units)} units)')
    try:
        good, probs, out = run(sqlcl, 'DROP', DROP_ALL)
        left = rows(out, 'LEFT')
        check('1.', good and left == ['0'], f'every RAD_PDF object dropped ({left[0] if left else "?"} left)', probs)
        good, probs, out = run(sqlcl, 'CORE', '@install_core.sql', cwd=SRC, timeout=1800)
        if not check('1.', good and 'compilation failed' not in out, 'the core alone installed', probs):
            print(out[-3000:])
            return finish(sqlcl, failures, check)

        good, probs, out = run(sqlcl, 'OBJ', f"""
SET PAGESIZE 0 LINESIZE 300 FEEDBACK OFF
SELECT 'OBJ:' || object_name || ':' || object_type || ':' || status FROM user_objects
 WHERE (object_name IN ({names_sql}) OR {OURS}) AND object_type IN {UNIT_TYPES} ORDER BY 1;""")
        found = {tuple(r.split(':')[:2]): r.split(':')[2] for r in rows(out, 'OBJ')}
        missing = sorted(core_units - set(found))
        extra = sorted(set(found) - core_units)
        invalid = sorted(u for u, s in found.items() if s != 'VALID')
        check('2.', good and not missing and not extra and not invalid,
              f'the schema holds exactly the {len(core_units)} units of the manifest, all VALID ({len(found)} found)',
              probs + [f'missing {missing}'] * bool(missing) + [f'extra {extra}'] * bool(extra)
              + [f'not VALID {invalid}'] * bool(invalid))

        good, probs, out = run(sqlcl, 'DEP', """
SET PAGESIZE 0 LINESIZE 300 FEEDBACK OFF
SELECT 'DEP:' || name || ':' || type || ':' || referenced_name || ':' || referenced_type FROM user_dependencies
 WHERE referenced_owner = USER ORDER BY 1;""")
        deps = [tuple(r.split(':')) for r in rows(out, 'DEP')]
        # every body depends at least on its own specification: a body without rows means the query lost them
        silent = [b for b in bodies if (b[0], b[1], b[0]) not in {(d[0], d[1], d[2]) for d in deps}]
        check('3.', good and not silent, f'dependencies read ({len(deps)} edges, every body seen)',
              probs + [f'bodies without edges {silent}'] * bool(silent))
        outs = sorted(f'{n} {t} -> {r} {rt}' for n, t, r, rt in deps if n in core and r not in core)
        check('3.', good and not outs, 'no edge from a core unit leaves the list', outs)
        reached = closure(deps, 'RAD_PDF_PAGER')
        print(f'     the paginator\'s closure (by name, specs and bodies): {", ".join(sorted(reached))}')
        foreign = sorted(reached - set(core))
        check('3.', good and 'RAD_PDF_DOC' in reached and not foreign,
              'the paginator\'s closure holds only names of the list', [f'outside the list {foreign}'])

        # the bodies to scan come from the manifest, not from the schema: a missing body fails (no SCAN row) and a
        # preprocessor error stops the block (WHENEVER SQLERROR)
        scan = '\n   UNION ALL '.join(f"SELECT '{n}' n, '{t}' t FROM dual" for n, t in bodies)
        good, probs, out = run(sqlcl, 'DYN', f"""
SET PAGESIZE 0 LINESIZE 300 FEEDBACK OFF
DECLARE
  l_src DBMS_PREPROCESSOR.SOURCE_LINES_T;
BEGIN
  FOR r IN ({scan}) LOOP
    l_src := DBMS_PREPROCESSOR.GET_POST_PROCESSED_SOURCE(r.t, USER, r.n);
    DBMS_OUTPUT.PUT_LINE('SCAN:' || r.n || ':' || r.t || ':' || l_src.COUNT);
    FOR i IN 1 .. l_src.COUNT LOOP
      IF REGEXP_LIKE(l_src(i), 'EXECUTE[[:space:]]+IMMEDIATE|DBMS_SQL\\.(OPEN_CURSOR|PARSE|EXECUTE|TO_CURSOR_NUMBER)|OPEN[[:space:]]+[A-Za-z_0-9]+[[:space:]]+FOR[[:space:]]+[A-Za-z_]', 'i')
         AND NOT REGEXP_LIKE(l_src(i), '^[[:space:]]*--') THEN
        DBMS_OUTPUT.PUT_LINE('DYN:' || r.n || ':' || i || ':' || TRIM(l_src(i)));
      END IF;
    END LOOP;
  END LOOP;
END;
/""")
        scanned = {(s.split(':')[0], s.split(':')[1]) for s in rows(out, 'SCAN') if int(s.split(':')[2]) > 0}
        unscanned = sorted(set(bodies) - scanned)
        dyn = rows(out, 'DYN')
        check('4.', good and not unscanned and not dyn,
              f'no dynamic PL/SQL in the {len(bodies)} post-processed bodies (package and type bodies)',
              probs + [f'not scanned {unscanned}'] * bool(unscanned) + dyn)

        for suite, head in SUITES:
            good, probs, out = run(sqlcl, suite.upper(), f'@tests/{suite}.sql', cwd=ROOT, scan_errors=False)
            summary = [l.strip() for l in out.splitlines() if l.startswith(head + ':')]
            passed = len(summary) == 1 and re.fullmatch(rf'{head}: [1-9]\d* passed, 0 failed\.', summary[0])
            if not check('5.', good and bool(passed), f'{suite} on the core alone ({summary[0] if summary else "no summary"})',
                         probs):
                print(out[-2000:])
        for script, summary in PY_SUITES:
            try:
                rc, out = py(script)
            except Exception as e:                       # a timeout is a failed suite
                rc, out = -1, f'{type(e).__name__}: {e}'
            line = [l for l in out.splitlines() if re.fullmatch(summary, l.strip())]
            if not check('5.', rc == 0 and len(line) == 1, f'{script} on the core alone ({line[0] if line else "no summary"})',
                         [f'exit code {rc}']):
                print(out[-3000:])
    except Exception as e:  # the restore below must run whatever happened
        check('!', False, f'the check stopped: {type(e).__name__}: {e}')
    return finish(sqlcl, failures, check)


def finish(sqlcl, failures, check):
    product = units(install_files('install.sql'))
    good, probs, _ = run(sqlcl, 'DROP2', DROP_ALL)
    good2, probs2, out = run(sqlcl, 'PRODUCT', '@install.sql', cwd=SRC, timeout=1800)
    restored = good and good2 and 'compilation failed' not in out
    if not check('6.', restored, 'the full product installed again', probs + probs2):
        print('     PRODUCT RESTORE FAILED: the schema may hold the core only; run src/install.sql by hand')
        print(out[-3000:])
    good, probs, out = run(sqlcl, 'PRODUCT_OBJ', f"""
SET PAGESIZE 0 LINESIZE 300 FEEDBACK OFF
SELECT 'OBJ:' || object_name || ':' || object_type || ':' || status FROM user_objects
 WHERE {OURS} AND object_type IN {UNIT_TYPES} ORDER BY 1;""")
    found = {tuple(r.split(':')[:2]): r.split(':')[2] for r in rows(out, 'OBJ')}
    bad = sorted(product - set(found)) + sorted(u for u, s in found.items() if s != 'VALID')
    check('6.', good and not bad, f'the product\'s {len(product)} units present and VALID', probs + [str(bad)] * bool(bad))
    good, probs, out = run(sqlcl, 'EDGE', """
SET PAGESIZE 0 FEEDBACK OFF
SELECT 'EDGE:' || name || ' -> ' || referenced_name FROM user_dependencies
 WHERE referenced_owner = USER
   AND ((name = 'RAD_PDF_TABLE' AND referenced_name = 'RAD_PDF_LAYOUT')
     OR (name = 'RAD_PDF_LAYOUT' AND referenced_name = 'RAD_PDF_SWISS')
     OR (name = 'RAD_PDF_DOC' AND referenced_name IN ('RAD_PDF_LAYOUT', 'RAD_PDF_TABLE', 'RAD_PDF_TEMPLATE', 'RAD_PDF_FLOW', 'RAD_PDF_SWISS')));""")
    edges = rows(out, 'EDGE')
    check('7.', good and not edges, 'in the product: no table -> layout, layout -> swiss, doc -> the flowable layer',
          probs + edges)
    print('core check: ' + ('OK' if not failures else f'FAILED ({len(failures)}: ' + '; '.join(failures) + ')'))
    return not failures


if __name__ == '__main__':
    sys.exit(0 if main() else 1)
