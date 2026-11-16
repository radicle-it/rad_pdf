#!/usr/bin/env python3
"""The importable core of RAD_PDF checked on its own (middleware-docs 96a §1b; codex-054):

    python3 tests/import/check_core.py

On the test schema (the golden bench's connection):
  1. every RAD_PDF object dropped, then ONLY the core installed (src/install_core.sql, from src/import_core.lst) —
     the core must compile without the flowable layer, the markup engine and the extensions;
  2. the transitive closure: no object of the list depends (USER_DEPENDENCIES, specifications and bodies) on an object
     of the schema outside the list, and the paginator's closure holds none of the names not imported;
  3. no dynamic PL/SQL in the core's post-processed sources (DBMS_PREPROCESSOR: the page procedures of E6 compiled out);
  4. the core's own suites run on it: phase23 (RI), phase24 (merge), phase25 (pager; needs tests/word/load_fonts.py);
  5. the full product installed again (src/install.sql), so the schema is left as it was;
  6. in the product: the cycle layout <-> table gone (table does not depend on layout), layout free of the Swiss
     QR-bill, rad_pdf_doc free of the flowable layer.
Exit 1 when any check fails. The log is printed; keep it as the evidence of a review.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests' / 'golden'))
import bench  # noqa: E402

NOT_IMPORTED = ['RAD_PDF', 'RAD_PDF_FLOW', 'RAD_PDF_LAYOUT', 'RAD_PDF_TABLE', 'RAD_PDF_TEMPLATE', 'RAD_PDF_SWISS',
                'RAD_PDF_BARCODE', 'RAD_PDF_CHART']
DROP_ALL = """
BEGIN
  FOR r IN (SELECT object_name, object_type FROM user_objects
             WHERE object_type IN ('PACKAGE', 'TYPE') AND (object_name = 'RAD_PDF' OR object_name LIKE 'RAD\\_PDF\\_%' ESCAPE '\\')
             ORDER BY CASE object_type WHEN 'PACKAGE' THEN 1 ELSE 2 END,
                      CASE WHEN object_name IN ('RAD_PDF_IMG_DECODER', 'RAD_PDF_IMG_DATA') THEN 2 ELSE 1 END) LOOP
    EXECUTE IMMEDIATE 'DROP ' || r.object_type || ' ' || r.object_name || CASE r.object_type WHEN 'TYPE' THEN ' FORCE' END;
  END LOOP;
END;
/
SELECT 'LEFT:' || COUNT(*) FROM user_objects WHERE (object_name = 'RAD_PDF' OR object_name LIKE 'RAD\\_PDF\\_%' ESCAPE '\\')
   AND object_type IN ('PACKAGE', 'PACKAGE BODY', 'TYPE', 'TYPE BODY');
"""


def names():
    out = []
    for line in (ROOT / 'src' / 'import_core.lst').read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            out.append(re.sub(r'\.(pks|pkb|sql)$', '', line).upper())
    return sorted(set(out))


def main():
    core = names()
    in_list = ', '.join(f"'{n}'" for n in core)
    ok = True
    rc, out = bench.sqlcl(DROP_ALL)
    left = re.search(r'LEFT:(\d+)', out)
    print(f'1. every RAD_PDF object dropped: {left.group(1) if left else "?"} left')
    rc, out = bench.sqlcl('@install_core.sql', cwd=ROOT / 'src', timeout=1800)
    good = rc == 0 and 'compilation failed' not in out
    print(f'   the core alone installed ({len(core)} objects): {"OK" if good else "FAILED"}')
    if not good:
        print(out[-3000:])
        ok = False
    q = f"""
SET PAGESIZE 0 LINESIZE 300 FEEDBACK OFF
SELECT TRIM('OBJ:' || object_name || ':' || object_type || ':' || status) FROM user_objects
 WHERE (object_name = 'RAD_PDF' OR object_name LIKE 'RAD\\_PDF\\_%' ESCAPE '\\')
   AND object_type IN ('PACKAGE', 'PACKAGE BODY', 'TYPE', 'TYPE BODY') ORDER BY 1;
SELECT TRIM('OUT:' || d.name || ' ' || d.type || ' -> ' || d.referenced_name || ' ' || d.referenced_type)
  FROM user_dependencies d
 WHERE d.name IN ({in_list}) AND d.referenced_owner = USER AND d.referenced_name NOT IN ({in_list});
SELECT TRIM('CLOSURE:' || referenced_name) FROM (
  SELECT DISTINCT referenced_name FROM user_dependencies
   START WITH name = 'RAD_PDF_PAGER' AND referenced_owner = USER
   CONNECT BY NOCYCLE PRIOR referenced_name = name AND PRIOR referenced_type = type AND referenced_owner = USER)
 ORDER BY 1;
DECLARE
  l_src DBMS_PREPROCESSOR.SOURCE_LINES_T;
  l_hit PLS_INTEGER;
BEGIN
  FOR r IN (SELECT object_name FROM user_objects WHERE object_type = 'PACKAGE BODY' AND object_name IN ({in_list})) LOOP
    l_src := DBMS_PREPROCESSOR.GET_POST_PROCESSED_SOURCE('PACKAGE BODY', USER, r.object_name);
    l_hit := 0;
    FOR i IN 1 .. l_src.COUNT LOOP
      IF REGEXP_LIKE(l_src(i), 'EXECUTE[[:space:]]+IMMEDIATE|DBMS_SQL\\.(OPEN_CURSOR|PARSE|EXECUTE|TO_CURSOR_NUMBER)|OPEN[[:space:]]+[A-Za-z_0-9]+[[:space:]]+FOR[[:space:]]+[A-Za-z_]', 'i') AND NOT REGEXP_LIKE(l_src(i), '^[[:space:]]*--') THEN
        l_hit := l_hit + 1;
        DBMS_OUTPUT.PUT_LINE('DYN:' || r.object_name || ':' || i || ':' || TRIM(l_src(i)));
      END IF;
    END LOOP;
  END LOOP;
END;
/
"""
    rc, out = bench.sqlcl(q)
    objs = [l.strip()[4:] for l in out.splitlines() if l.startswith('OBJ:')]
    bad = [o for o in objs if not o.endswith(':VALID') or o.split(':')[0] not in core]
    print(f'   {len(objs)} RAD_PDF objects in the schema, all VALID and of the list: {"OK" if not bad else bad}')
    ok = ok and not bad and len(objs) > 0
    outs = [l[4:] for l in out.splitlines() if l.startswith('OUT:')]
    print(f'2. dependencies leaving the list: {"none -> OK" if not outs else outs}')
    ok = ok and not outs
    closure = [l.strip()[8:] for l in out.splitlines() if l.startswith('CLOSURE:')]
    forbidden = [c for c in closure if c in NOT_IMPORTED]
    print(f'   the paginator\'s closure: {", ".join(c for c in closure if c.startswith("RAD_PDF"))}')
    print(f'   names not imported in it: {"none -> OK" if not forbidden else forbidden}')
    ok = ok and not forbidden
    dyn = [l[4:] for l in out.splitlines() if l.startswith('DYN:')]
    print(f'3. dynamic PL/SQL in the core\'s post-processed bodies: {"none -> OK" if not dyn else ""}')
    for d in dyn:
        print(f'   {d}')
    ok = ok and not dyn
    for t in ('phase23_ri', 'phase24_merge', 'phase25_pager'):
        rc, out = bench.sqlcl(f'@tests/{t}.sql', cwd=ROOT)
        summary = [l for l in out.splitlines() if re.match(r'^Phase \d+', l)]
        good = rc == 0 and summary and all(', 0 failed' in s for s in summary)
        print(f'4. {t} on the core alone: {" ".join(summary) if summary else "no summary"} -> {"OK" if good else "FAILED"}')
        if not good:
            print(out[-2000:])
        ok = ok and good
    rc, out = bench.sqlcl(DROP_ALL)
    rc, out = bench.sqlcl('@install.sql', cwd=ROOT / 'src', timeout=1800)
    good = rc == 0 and 'compilation failed' not in out
    print(f'5. the full product installed again: {"OK" if good else "FAILED"}')
    ok = ok and good
    rc, out = bench.sqlcl("""
SET PAGESIZE 0 FEEDBACK OFF
SELECT TRIM('EDGE:' || name || ' -> ' || referenced_name) FROM user_dependencies
 WHERE referenced_owner = USER
   AND ((name = 'RAD_PDF_TABLE' AND referenced_name = 'RAD_PDF_LAYOUT')
     OR (name = 'RAD_PDF_LAYOUT' AND referenced_name = 'RAD_PDF_SWISS')
     OR (name = 'RAD_PDF_DOC' AND referenced_name IN ('RAD_PDF_LAYOUT', 'RAD_PDF_TABLE', 'RAD_PDF_TEMPLATE', 'RAD_PDF_FLOW', 'RAD_PDF_SWISS')));
""")
    edges = [l.strip()[5:] for l in out.splitlines() if l.startswith('EDGE:')]
    print(f'6. in the product: table -> layout, layout -> swiss, doc -> the flowable layer: {"none -> OK" if not edges else edges}')
    ok = ok and not edges
    print('core check: ' + ('OK' if ok else 'FAILED'))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
