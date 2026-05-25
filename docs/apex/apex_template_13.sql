-- apex_template_13.sql  —  DB-driven templates
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Loading a template CLOB from a database table at render time.
--   This lets content teams update PDF layouts without touching application
--   code or redeploying packages.
--
--   Pattern:
--     1. A PDF_TEMPLATES table stores one CLOB per named template.
--     2. The page process SELECT ... INTO to load the CLOB.
--     3. render() is called with the live CLOB and a fresh bind array.
--     4. Updating a template is a plain UPDATE — no code change.
--
--   Prerequisites (run once as DBA/schema owner):
--
--     CREATE TABLE pdf_templates (
--       name        VARCHAR2(100) NOT NULL PRIMARY KEY,
--       description VARCHAR2(500),
--       body        CLOB          NOT NULL,
--       updated_at  DATE DEFAULT SYSDATE NOT NULL
--     );
--
--   Then insert the templates shown at the bottom of this file.
--
-- APEX SETUP
--   Page items:
--     P1_DEPTNO       (number field — department to render)
--     P1_TEMPLATE_NAME (text field or select list — name in pdf_templates)
--   Process: Execute Server-side Code — On Load - Before Header
-- ===========================================================================

DECLARE
  l_doc       rad_pdf_types.t_doc_handle;
  l_pdf       BLOB;
  l_binds     rad_pdf_types.t_bind_array;
  l_opts      rad_pdf_types.t_template_options;

  -- Template CLOB loaded from the database
  l_tmpl_body CLOB;

  -- Data resolved from EMP / DEPT
  l_dname  DEPT.DNAME%TYPE;
  l_loc    DEPT.LOC%TYPE;
  l_count  PLS_INTEGER;
  l_mgr    EMP.ENAME%TYPE;

BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Resolve live data
  -- -------------------------------------------------------------------------
  SELECT dname, loc INTO l_dname, l_loc
    FROM dept WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  SELECT COUNT(*) INTO l_count FROM emp WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  BEGIN
    -- Highest-paid employee = department "manager" for this demo
    SELECT ename INTO l_mgr
      FROM (SELECT ename FROM emp
             WHERE deptno = TO_NUMBER(:P1_DEPTNO)
             ORDER BY sal DESC)
     WHERE ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_mgr := NULL; END;

  -- -------------------------------------------------------------------------
  -- 2. Load the template from the database table.
  --    The template name comes from the APEX page item P1_TEMPLATE_NAME.
  --    If the template does not exist, NO_DATA_FOUND is raised and caught.
  -- -------------------------------------------------------------------------
  SELECT body
    INTO l_tmpl_body
    FROM pdf_templates
   WHERE name = :P1_TEMPLATE_NAME;

  -- -------------------------------------------------------------------------
  -- 3. Build binds.
  --    The bind keys must match the #TOKEN# names in the stored template.
  --    Adding extra keys is harmless — unknown tokens are left verbatim.
  -- -------------------------------------------------------------------------
  l_binds(1).key := 'DEPT_NAME';  l_binds(1).value := l_dname;
  l_binds(2).key := 'DEPT_LOC';   l_binds(2).value := INITCAP(l_loc);
  l_binds(3).key := 'DEPTNO';     l_binds(3).value := :P1_DEPTNO;
  l_binds(4).key := 'EMP_COUNT';  l_binds(4).value := TO_CHAR(l_count);
  l_binds(5).key := 'GEN_DATE';
  l_binds(5).value := TO_CHAR(SYSDATE, 'DD Month YYYY HH24:MI');

  -- MANAGER_NAME is conditional in the templates (<if bind="MANAGER_NAME">).
  -- Only add it when the value is non-NULL so the <if> block fires correctly.
  IF l_mgr IS NOT NULL THEN
    l_binds(6).key := 'MANAGER_NAME'; l_binds(6).value := INITCAP(l_mgr);
  END IF;

  -- For templates that contain a <table> tag
  l_opts.allow_queries := TRUE;

  -- -------------------------------------------------------------------------
  -- 4. Render with the loaded CLOB — exactly the same as passing a literal
  --    template string, but the content comes from the database.
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_tmpl_body, l_binds, l_opts);
  DBMS_LOB.FREETEMPORARY(l_tmpl_body);   -- free after render

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="dept_' ||
        :P1_DEPTNO || '.pdf"');
  OWA_UTIL.HTTP_HEADER_CLOSE;
  WPG_DOCLOAD.DOWNLOAD_FILE(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  APEX_APPLICATION.STOP_APEX_ENGINE;

EXCEPTION
  WHEN APEX_APPLICATION.E_STOP_APEX_ENGINE THEN RAISE;
  WHEN NO_DATA_FOUND THEN
    APEX_ERROR.ADD_ERROR(
      p_message          => 'Template "' || :P1_TEMPLATE_NAME || '" not found.',
      p_display_location => apex_error.c_inline_in_notification);
  WHEN OTHERS THEN
    IF l_tmpl_body IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_tmpl_body) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_tmpl_body);
    END IF;
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;

-- ===========================================================================
-- SETUP: insert sample templates into pdf_templates.
-- Run this once in SQL Workshop or SQL*Plus.
-- ===========================================================================
/*
DECLARE
  PROCEDURE upsert(p_name VARCHAR2, p_desc VARCHAR2, p_body CLOB) IS
  BEGIN
    MERGE INTO pdf_templates t USING (SELECT p_name AS n FROM DUAL) s
    ON (t.name = s.n)
    WHEN MATCHED THEN UPDATE SET body = p_body, updated_at = SYSDATE
    WHEN NOT MATCHED THEN INSERT (name, description, body)
                         VALUES  (p_name, p_desc, p_body);
  END;
BEGIN

  -- Template 1: "dept_summary" — header only, no table
  upsert('dept_summary', 'Department summary (no table)',
    '<h1>Department Summary</h1>'                              ||
    '<spacer height="6pt"/>'                                   ||
    '<p>Department: <b>#DEPT_NAME#</b></p>'                   ||
    '<p>Location:   <b>#DEPT_LOC#</b></p>'                    ||
    '<p>Employees:  <b>#EMP_COUNT#</b></p>'                   ||
    '<spacer height="10pt"/>'                                  ||
    '<hr color="336699"/>'                                     ||
    '<spacer height="8pt"/>'                                   ||
    '<if bind="MANAGER_NAME">'
      || '<p>Top earner: <b>#MANAGER_NAME#</b></p>'
      || '</if>'                                               ||
    '<p style="caption">Generated: #GEN_DATE#</p>');

  -- Template 2: "dept_roster" — with employee table (allow_query required)
  upsert('dept_roster', 'Department roster with employee table',
    '<h1>#DEPT_NAME# — Employee Roster</h1>'                 ||
    '<p>Location: <b>#DEPT_LOC#</b>   Dept: <b>#DEPTNO#</b></p>' ||
    '<spacer height="8pt"/>'                                  ||
    '<hr color="336699"/>'                                    ||
    '<spacer height="14pt"/>'                                 ||
    '<h2>Employees</h2>'                                      ||
    '<table columns="EMP_ROSTER"'                             ||
    ' query="SELECT empno, ename, INITCAP(job),'             ||
    '               TO_CHAR(hiredate,''DD-Mon-YYYY''), sal'  ||
    '          FROM emp WHERE deptno = #DEPTNO# ORDER BY ename"' ||
    ' row_height="15pt" header_bg="336699"'                   ||
    ' border_color="AAAAAA" allow_query="true"/>'             ||
    '<spacer height="8pt"/>'                                  ||
    '<p style="caption">Generated: #GEN_DATE#</p>');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Templates inserted.');
END;
/
*/
