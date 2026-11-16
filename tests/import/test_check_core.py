#!/usr/bin/env python3
"""Offline sensitivity tests of tests/import/check_core.py (codex-058 R1, R2): no database, bench.sqlcl replaced by a
simulated client. The healthy simulation must pass; every fault -- a failed or unfinished check, an error line, a
missing result, a missing unit, a forbidden edge reached only through a body, a failed restore -- must not.

    python3 tests/import/test_check_core.py
"""
import contextlib
import io
import re
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_core as cc  # noqa: E402

CORE = cc.units(cc.manifest())
PRODUCT = cc.units(cc.install_files('install.sql'))
BODIES = sorted(u for u in CORE if u[1].endswith('BODY'))


def healthy_deps():
    """every body on its own spec, plus a small realistic graph: pager -> doc -> ctx/serial only through bodies"""
    deps = [(n, t, n, t.replace(' BODY', '')) for n, t in BODIES]
    deps += [('RAD_PDF_PAGER', 'PACKAGE', 'RAD_PDF_TYPES', 'PACKAGE'),
             ('RAD_PDF_PAGER', 'PACKAGE BODY', 'RAD_PDF_DOC', 'PACKAGE'),
             ('RAD_PDF_PAGER', 'PACKAGE BODY', 'RAD_PDF_RI', 'PACKAGE'),
             ('RAD_PDF_DOC', 'PACKAGE', 'RAD_PDF_TYPES', 'PACKAGE'),
             ('RAD_PDF_DOC', 'PACKAGE BODY', 'RAD_PDF_CTX', 'PACKAGE'),
             ('RAD_PDF_DOC', 'PACKAGE BODY', 'RAD_PDF_SERIAL', 'PACKAGE')]
    return deps


class Sim:
    """the simulated client: answers each check by its completion label; faults override one label"""

    def __init__(self, **faults):
        self.faults = faults
        self.deps = healthy_deps()
        self.calls = []

    def default(self, label):
        if label in ('DROP', 'DROP2'):
            return 0, 'LEFT:0'
        if label in ('CORE', 'PRODUCT', 'EDGE'):
            return 0, ''
        if label == 'OBJ':
            return 0, '\n'.join(f'OBJ:{n}:{t}:VALID' for n, t in sorted(CORE))
        if label == 'PRODUCT_OBJ':
            return 0, '\n'.join(f'OBJ:{n}:{t}:VALID' for n, t in sorted(PRODUCT))
        if label == 'DEP':
            return 0, '\n'.join('DEP:' + ':'.join(d) for d in self.deps)
        if label == 'DYN':
            return 0, '\n'.join(f'SCAN:{n}:{t}:120' for n, t in BODIES)
        for suite, head in cc.SUITES:
            if label == suite.upper():
                return 0, f'PASS 1 ORA-20841 expected\n{head}: 12 passed, 0 failed.'
        raise AssertionError(label)

    def __call__(self, script, cwd=None, timeout=900):
        label = re.search(r"SELECT 'DONE:(\w+)' FROM dual;\s*$", script).group(1)
        self.calls.append(label)
        fault = self.faults.get(label)
        if isinstance(fault, BaseException):
            raise fault
        rc, out = self.default(label)
        marker = True
        if callable(fault):
            rc, out, marker = fault(rc, out)
        return rc, out + (f'\nDONE:{label}\n' if marker else '\n')


def py_ok(script):
    return 0, 'ok   pos_row_loop ...\ndocx cases: OK (68 cases)\n'


def go(sim, py=py_ok):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        ok = cc.main(sim, py)
    return ok, buf.getvalue()


class Sensitivity(unittest.TestCase):
    def red(self, why, py=py_ok, **faults):
        sim = Sim(**faults)
        ok, log = go(sim, py)
        self.assertFalse(ok, f'{why}: the gate passed\n{log}')
        self.assertIn('core check: FAILED', log)
        self.assertIn('PRODUCT', sim.calls, f'{why}: the product was not restored')
        return log

    def test_healthy_passes(self):
        ok, log = go(Sim())
        self.assertTrue(ok, log)
        self.assertIn('core check: OK', log)

    def test_codex058_repro(self):
        # codex-058 R1: DROP rc=1 LEFT:7, main query rc=1 with one object and ORA-24234, final query ORA-00942
        self.red('codex-058 repro',
                 DROP=lambda rc, out: (1, 'LEFT:7', True),
                 OBJ=lambda rc, out: (1, 'OBJ:RAD_PDF_TYPES:PACKAGE:VALID\nORA-24234: unable to get source', False),
                 EDGE=lambda rc, out: (1, 'ORA-00942: table or view does not exist', False))

    def test_drop_leaves_objects(self):
        self.red('drop with residues', DROP=lambda rc, out: (0, 'LEFT:7', True))

    def test_drop_without_count(self):
        self.red('drop without LEFT', DROP=lambda rc, out: (0, '', True))

    def test_install_fails(self):
        log = self.red('core install', CORE=lambda rc, out: (3, 'RAD_PDF core compilation failed', False))
        self.assertIn('6. the full product installed again: OK', log)

    def test_preprocessor_error(self):
        self.red('preprocessor error', DYN=lambda rc, out: (1, 'ORA-24234: unable to get source of package', False))

    def test_error_line_with_rc0(self):
        self.red('error line, rc 0', DEP=lambda rc, out: (0, out + '\nORA-01555: snapshot too old', True))

    def test_check_without_result(self):
        self.red('no marker', OBJ=lambda rc, out: (0, out, False))

    def test_check_with_empty_result(self):
        self.red('empty OBJ', OBJ=lambda rc, out: (0, '', True))

    def test_missing_unit(self):
        self.red('missing doc body', OBJ=lambda rc, out: (
            0, out.replace('OBJ:RAD_PDF_DOC:PACKAGE BODY:VALID', ''), True))

    def test_extra_unit(self):
        self.red('layout present', OBJ=lambda rc, out: (0, out + '\nOBJ:RAD_PDF_LAYOUT:PACKAGE:VALID', True))

    def test_invalid_unit(self):
        self.red('invalid', OBJ=lambda rc, out: (
            0, out.replace('OBJ:RAD_PDF_PAGER:PACKAGE BODY:VALID', 'OBJ:RAD_PDF_PAGER:PACKAGE BODY:INVALID'), True))

    def test_dependencies_lost(self):
        self.red('no DEP rows', DEP=lambda rc, out: (0, '', True))

    def test_type_body_not_scanned(self):
        self.red('type body unscanned', DYN=lambda rc, out: (
            0, out.replace('SCAN:RAD_PDF_JPEG_DECODER:TYPE BODY:120', ''), True))

    def test_dynamic_sql_found(self):
        self.red('dynamic sql', DYN=lambda rc, out: (0, out + '\nDYN:RAD_PDF_CANVAS:812:EXECUTE IMMEDIATE l_sql;', True))

    def test_suite_without_summary(self):
        self.red('suite summary', PHASE25_PAGER=lambda rc, out: (0, 'PASS 1', True))

    def test_suite_failed(self):
        self.red('suite failed', PHASE24_MERGE=lambda rc, out: (0, 'Phase 24 merge: 92 passed, 1 failed.', True))

    def test_suite_exit_code(self):
        self.red('suite rc', PHASE23_RI=lambda rc, out: (1, out, True))

    def test_py_suite_failed(self):
        self.red('docx cases failed', py=lambda s: (1, 'FAIL err_field\ndocx cases: FAILED (68 cases)\n'))

    def test_py_suite_no_summary(self):
        self.red('docx cases without summary', py=lambda s: (0, 'ok   pos_row_loop\n'))

    def test_py_suite_timeout(self):
        def boom(s):
            raise subprocess.TimeoutExpired('python3', 3600)
        self.red('docx cases timeout', py=boom)

    def test_timeout(self):
        self.red('timeout', DYN=subprocess.TimeoutExpired('sql', 900))

    def test_restore_fails(self):
        log = self.red('restore', PRODUCT=lambda rc, out: (1, 'RAD_PDF compilation failed', False))
        self.assertIn('PRODUCT RESTORE FAILED', log)

    def test_product_unit_invalid(self):
        self.red('product invalid', PRODUCT_OBJ=lambda rc, out: (
            0, out.replace('OBJ:RAD_PDF_LAYOUT:PACKAGE BODY:VALID', 'OBJ:RAD_PDF_LAYOUT:PACKAGE BODY:INVALID'), True))

    def test_product_edge(self):
        self.red('table -> layout', EDGE=lambda rc, out: (0, 'EDGE:RAD_PDF_TABLE -> RAD_PDF_LAYOUT', True))


class Closure(unittest.TestCase):
    """codex-058 R2: an edge only in the BODY of an indirect dependency must be reached"""
    GRAPH = [('RAD_PDF_PAGER', 'PACKAGE BODY', 'RAD_PDF_DOC', 'PACKAGE'),
             ('RAD_PDF_DOC', 'PACKAGE', 'RAD_PDF_TYPES', 'PACKAGE'),
             ('RAD_PDF_DOC', 'PACKAGE BODY', 'RAD_PDF_LAYOUT', 'PACKAGE')]

    def test_body_of_indirect_dependency(self):
        self.assertIn('RAD_PDF_LAYOUT', cc.closure(self.GRAPH, 'RAD_PDF_PAGER'))

    def test_spec_to_spec_walk_would_miss_it(self):
        # the round-1 walk (PRIOR referenced_type = type) from the pager's units: DOC is reached as a PACKAGE, so only
        # DOC's PACKAGE rows are followed -- LAYOUT is not reached; this is the defect the by-name walk removes
        reached, todo = set(), [(n, t) for n, t, _, _ in self.GRAPH if n == 'RAD_PDF_PAGER']
        while todo:
            n, t = todo.pop()
            for a, at, r, rt in self.GRAPH:
                if (a, at) == (n, t) and r not in reached:
                    reached.add(r)
                    todo.append((r, rt))
        self.assertNotIn('RAD_PDF_LAYOUT', reached)

    def test_gate_fails_on_it(self):
        sim = Sim()
        sim.deps = healthy_deps() + [('RAD_PDF_DOC', 'PACKAGE BODY', 'RAD_PDF_LAYOUT', 'PACKAGE')]
        ok, log = go(sim)
        self.assertFalse(ok, log)
        self.assertIn("3. the paginator's closure holds only names of the list: FAILED", log)
        self.assertIn('RAD_PDF_DOC PACKAGE BODY -> RAD_PDF_LAYOUT PACKAGE', log)


if __name__ == '__main__':
    unittest.main(verbosity=2)
