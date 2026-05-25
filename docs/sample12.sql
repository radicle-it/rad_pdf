-- sample12.sql - DB-driven template store
--
-- Demonstrates loading rad_pdf_template templates from a database table.
-- This pattern lets operations / content teams update PDF layouts at runtime
-- (e.g. via APEX Admin pages or SQL Developer) without touching application
-- code or redeploying anything.
--
-- Pattern overview:
--   1. A PDF_TEMPLATES table stores one CLOB row per named template.
--   2. The rendering procedure SELECT … INTO to load the CLOB, then calls
--      rad_pdf_template.render with a bind array built at runtime.
--   3. Updating a template is a plain UPDATE statement — no code change.
--
-- Uses the classic Oracle EMP / DEPT tables (Oracle sample schema).
--
-- Prerequisites:
--   - RAD_PDF suite installed (all 9 phases).
--   - Oracle DIRECTORY alias RAD_PDF_DIR pointing to a writeable server path.
--   - CREATE TABLE privilege on the target schema.
--
-- Run in SQL*Plus from repo root:
--   SET SERVEROUTPUT ON SIZE UNLIMITED
--   @docs/sample12.sql

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

-- ===========================================================================
-- Step 1: Create the template store table (idempotent).
-- ===========================================================================
BEGIN
  EXECUTE IMMEDIATE '
    CREATE TABLE pdf_templates (
      name        VARCHAR2(100)  NOT NULL
                    CONSTRAINT pdf_tmpl_pk PRIMARY KEY,
      description VARCHAR2(500),
      body        CLOB           NOT NULL,
      created_at  DATE           DEFAULT SYSDATE NOT NULL,
      updated_at  DATE           DEFAULT SYSDATE NOT NULL
    )';
  DBMS_OUTPUT.PUT_LINE('pdf_templates table created.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -955 THEN   -- ORA-00955: name already used
      DBMS_OUTPUT.PUT_LINE('pdf_templates table already exists.');
    ELSE
      RAISE;
    END IF;
END;
/

-- ===========================================================================
-- Step 2: Insert (or replace) two named templates.
--   - "dept_header"  : a minimal one-page department summary (no table).
--   - "dept_full"    : department header + employee <table>.
--
-- Templates use #BIND# tokens; callers supply values at render time.
-- ===========================================================================
DECLARE
  PROCEDURE upsert_template(p_name IN VARCHAR2, p_desc IN VARCHAR2, p_body IN CLOB) IS
  BEGIN
    MERGE INTO pdf_templates t
    USING (SELECT p_name AS name FROM DUAL) s
    ON (t.name = s.name)
    WHEN MATCHED THEN
      UPDATE SET body = p_body, description = p_desc, updated_at = SYSDATE
    WHEN NOT MATCHED THEN
      INSERT (name, description, body)
      VALUES (p_name, p_desc, p_body);
  END upsert_template;

  l_body CLOB;

  PROCEDURE w(p_s IN VARCHAR2) IS
  BEGIN
    DBMS_LOB.WRITEAPPEND(l_body, LENGTH(p_s), p_s);
  END w;

BEGIN
  -- ── Template 1: dept_header ─────────────────────────────────────────────
  DBMS_LOB.CREATETEMPORARY(l_body, TRUE);
  w('<h1>Department Summary</h1>');
  w('<spacer height="6pt"/>');
  w('<p>Department: <b>#DEPT_NAME#</b></p>');
  w('<p>Location: <b>#DEPT_LOC#</b></p>');
  w('<p>Head count: #EMP_COUNT# employees</p>');
  w('<spacer height="10pt"/>');
  w('<hr color="336699"/>');
  w('<spacer height="8pt"/>');
  w('<if bind="MANAGER_NAME">');
  w('  <p>Manager: <b>#MANAGER_NAME#</b></p>');
  w('</if>');
  w('<p>Generated on #GEN_DATE#.</p>');
  upsert_template('dept_header', 'One-page department summary', l_body);
  DBMS_LOB.FREETEMPORARY(l_body);

  -- ── Template 2: dept_full ───────────────────────────────────────────────
  DBMS_LOB.CREATETEMPORARY(l_body, TRUE);
  w('<h1>#DEPT_NAME# — Employee Roster</h1>');
  w('<spacer height="6pt"/>');
  w('<p>Location: <b>#DEPT_LOC#</b> &amp; department number: <b>#DEPTNO#</b></p>');
  w('<spacer height="10pt"/>');
  w('<hr color="336699"/>');
  w('<spacer height="10pt"/>');
  w('<h2>Employees</h2>');
  w('<table columns="EMP_ROSTER"');
  w('       query="SELECT empno, ename, job,');
  w('                     TO_CHAR(hiredate, ''DD-Mon-YYYY''), sal');
  w('                FROM emp WHERE deptno = #DEPTNO# ORDER BY ename"');
  w('       row_height="15pt"');
  w('       header_bg="336699"');
  w('       border_color="AAAAAA"');
  w('       allow_query="true"/>');
  w('<spacer height="8pt"/>');
  w('<if bind="FOOTER_NOTE">');
  w('  <p><i>#FOOTER_NOTE#</i></p>');
  w('</if>');
  upsert_template('dept_full', 'Department roster with employee table', l_body);
  DBMS_LOB.FREETEMPORARY(l_body);

  DBMS_OUTPUT.PUT_LINE('Templates stored: dept_header, dept_full');
END;
/

-- ===========================================================================
-- Step 3: Register the column set for the <table> tag (idempotent).
-- In a real application, do this in an application-level initialisation block
-- (e.g. an APEX On-New-Session process) so it runs only once per session.
-- ===========================================================================
DECLARE
  l_cols rad_pdf_types.t_columns;
BEGIN
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(5);

  l_cols(1).label              := 'No';
  l_cols(1).width              := 42;
  l_cols(1).header_fmt.align_h := 'C';
  l_cols(1).data_fmt.align_h   := 'C';

  l_cols(2).label := 'Name';    l_cols(2).width := 110;
  l_cols(3).label := 'Job';     l_cols(3).width := 90;

  l_cols(4).label              := 'Hired';
  l_cols(4).width              := 80;
  l_cols(4).header_fmt.align_h := 'C';
  l_cols(4).data_fmt.align_h   := 'C';

  l_cols(5).label               := 'Salary';
  l_cols(5).width               := 64;
  l_cols(5).header_fmt.align_h  := 'R';
  l_cols(5).data_fmt.align_h    := 'R';
  l_cols(5).data_fmt.num_format := '999,990.00';

  rad_pdf_template.register_columns('EMP_ROSTER', l_cols);
  DBMS_OUTPUT.PUT_LINE('Column set EMP_ROSTER registered.');
END;
/

-- ===========================================================================
-- Step 4: Render "dept_header" for department 10 (ACCOUNTING).
-- ===========================================================================
DECLARE
  l_tmpl_body CLOB;
  l_binds     rad_pdf_types.t_bind_array;
  l_doc       rad_pdf_types.t_doc_handle;
  l_pdf       BLOB;

  -- EMP / DEPT data resolved before rendering
  l_deptno    PLS_INTEGER   := 10;
  l_dname     DEPT.DNAME%TYPE;
  l_loc       DEPT.LOC%TYPE;
  l_emp_count PLS_INTEGER;
  l_manager   EMP.ENAME%TYPE;

  PROCEDURE write_pdf(p_blob IN BLOB, p_file IN VARCHAR2) IS
    l_fh  UTL_FILE.FILE_TYPE;
    l_raw RAW(16384);
    l_off PLS_INTEGER := 1;
    l_tot PLS_INTEGER;
    c_sz  CONSTANT PLS_INTEGER := 16384;
  BEGIN
    l_tot := DBMS_LOB.GETLENGTH(p_blob);
    l_fh  := UTL_FILE.FOPEN('RAD_PDF_DIR', p_file, 'WB', 32767);
    WHILE l_off <= l_tot LOOP
      l_raw := DBMS_LOB.SUBSTR(p_blob, LEAST(c_sz, l_tot - l_off + 1), l_off);
      UTL_FILE.PUT_RAW(l_fh, l_raw, TRUE);
      l_off := l_off + c_sz;
    END LOOP;
    UTL_FILE.FCLOSE(l_fh);
  END write_pdf;

BEGIN
  -- ── Resolve live data ───────────────────────────────────────────────────
  SELECT dname, loc INTO l_dname, l_loc FROM dept WHERE deptno = l_deptno;
  SELECT COUNT(*) INTO l_emp_count FROM emp WHERE deptno = l_deptno;
  BEGIN
    SELECT e.ename INTO l_manager
      FROM emp e
      JOIN dept d ON d.mgr = e.empno
     WHERE d.deptno = l_deptno
       AND ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_manager := NULL; END;

  -- ── Load template from the database table ───────────────────────────────
  SELECT body INTO l_tmpl_body FROM pdf_templates WHERE name = 'dept_header';

  -- ── Build binds ─────────────────────────────────────────────────────────
  l_binds(1).key := 'DEPT_NAME';    l_binds(1).value := l_dname;
  l_binds(2).key := 'DEPT_LOC';     l_binds(2).value := l_loc;
  l_binds(3).key := 'EMP_COUNT';    l_binds(3).value := TO_CHAR(l_emp_count);
  l_binds(4).key := 'GEN_DATE';     l_binds(4).value := TO_CHAR(SYSDATE, 'DD-Mon-YYYY');
  -- MANAGER_NAME is conditionally included by <if bind="MANAGER_NAME">:
  -- set it only when a manager was found; omit the bind entry otherwise.
  IF l_manager IS NOT NULL THEN
    l_binds(5).key := 'MANAGER_NAME'; l_binds(5).value := l_manager;
  END IF;

  -- ── Render ───────────────────────────────────────────────────────────────
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_tmpl_body, l_binds);
  l_pdf := rad_pdf.finalize(l_doc);

  write_pdf(l_pdf, 'sample12a_header.pdf');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('sample12a_header.pdf written.');

EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Step 5: Render "dept_full" for department 20 (RESEARCH).
-- ===========================================================================
DECLARE
  l_tmpl_body CLOB;
  l_binds     rad_pdf_types.t_bind_array;
  l_opts      rad_pdf_types.t_template_options;
  l_doc       rad_pdf_types.t_doc_handle;
  l_pdf       BLOB;

  l_deptno    PLS_INTEGER := 20;
  l_dname     DEPT.DNAME%TYPE;
  l_loc       DEPT.LOC%TYPE;

  PROCEDURE write_pdf(p_blob IN BLOB, p_file IN VARCHAR2) IS
    l_fh  UTL_FILE.FILE_TYPE;
    l_raw RAW(16384);
    l_off PLS_INTEGER := 1;
    l_tot PLS_INTEGER;
    c_sz  CONSTANT PLS_INTEGER := 16384;
  BEGIN
    l_tot := DBMS_LOB.GETLENGTH(p_blob);
    l_fh  := UTL_FILE.FOPEN('RAD_PDF_DIR', p_file, 'WB', 32767);
    WHILE l_off <= l_tot LOOP
      l_raw := DBMS_LOB.SUBSTR(p_blob, LEAST(c_sz, l_tot - l_off + 1), l_off);
      UTL_FILE.PUT_RAW(l_fh, l_raw, TRUE);
      l_off := l_off + c_sz;
    END LOOP;
    UTL_FILE.FCLOSE(l_fh);
  END write_pdf;

BEGIN
  SELECT dname, loc INTO l_dname, l_loc FROM dept WHERE deptno = l_deptno;

  SELECT body INTO l_tmpl_body FROM pdf_templates WHERE name = 'dept_full';

  l_binds(1).key := 'DEPT_NAME';    l_binds(1).value := l_dname;
  l_binds(2).key := 'DEPT_LOC';     l_binds(2).value := l_loc;
  l_binds(3).key := 'DEPTNO';       l_binds(3).value := TO_CHAR(l_deptno);
  -- FOOTER_NOTE omitted intentionally -> <if bind="FOOTER_NOTE"> block dropped

  l_opts.allow_queries := TRUE;

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_tmpl_body, l_binds, l_opts);
  l_pdf := rad_pdf.finalize(l_doc);

  write_pdf(l_pdf, 'sample12b_full.pdf');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('sample12b_full.pdf written.');

EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Step 6: Hot-update a template at runtime — no code change required.
-- Change the "dept_header" template to add a divider line below the title.
-- The next render picks up the updated CLOB automatically.
-- ===========================================================================
UPDATE pdf_templates
   SET body       = '<h1>Department Summary</h1>'
                 || '<hr color="003366"/>'
                 || '<spacer height="6pt"/>'
                 || '<p>Department: <b>#DEPT_NAME#</b>  |  '
                 ||   'Location: <b>#DEPT_LOC#</b></p>'
                 || '<p>Employees: <b>#EMP_COUNT#</b></p>'
                 || '<if bind="MANAGER_NAME">'
                 ||   '<p>Manager: <b>#MANAGER_NAME#</b></p>'
                 || '</if>'
                 || '<p><i>Generated on #GEN_DATE#</i></p>',
       updated_at = SYSDATE
 WHERE name = 'dept_header';

PROMPT Template "dept_header" updated (no application code change required).
