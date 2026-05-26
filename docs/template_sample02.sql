-- =============================================================================
-- template_sample02.sql  -  Template engine: bind substitution and inline markup
-- =============================================================================
--
-- WHAT THIS SHOWS
--   • Bind array (t_bind_array / t_bind_entry): key / value pairs substituted
--     into #KEY# tokens in the template string at render time.
--   • Auto-escaping: bind values containing & < > are entity-encoded by
--     default (raw=FALSE).  Never call escape_value() manually - the engine
--     does it for you.  Set raw=TRUE only for values that already contain
--     trusted inline markup (e.g. a pre-built run of <b>/<color> tags).
--   • Inline markup inside <p>, <h1>–<h6>:
--       <b>bold</b>          bold run
--       <i>italic</i>        italic run
--       <br/>                forced line break (stays in the same paragraph)
--   • Conditional blocks: <if bind="KEY">...</if>
--       Rendered only when the bind value for KEY is non-NULL and non-empty.
--       Suppressed blocks are removed before token substitution, so tokens
--       inside a FALSE block never raise "no such bind" errors.
--
-- DATA
--   Uses the classic Oracle EMP / DEPT demo tables.
--   If they are not present in your schema, run:
--     @$ORACLE_HOME/rdbms/admin/utlsampl.sql
--   or replace the SELECT with any equivalent query.
--
-- HOW TO RUN
--   Same as template_sample01.sql - see its header for save/download options.
--
-- PREREQUISITES
--   RAD_PDF packages installed in the current schema (src/install.sql).
--   EMP and DEPT demo tables accessible from the current schema.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;

  -- Employee data resolved before building the bind array.
  l_ename  EMP.ENAME%TYPE;
  l_job    EMP.JOB%TYPE;
  l_sal    EMP.SAL%TYPE;
  l_comm   EMP.COMM%TYPE;
  l_hdate  EMP.HIREDATE%TYPE;
  l_mgr    EMP.MGR%TYPE;
  l_dname  DEPT.DNAME%TYPE;
  l_loc    DEPT.LOC%TYPE;
  l_mgr_name EMP.ENAME%TYPE;
BEGIN
  -- Resolve employee data.  KING is the top earner in the SCOTT schema;
  -- replace with any valid ENAME or use a bind variable.
  SELECT e.ename, e.job, e.sal, e.comm, e.hiredate, e.mgr,
         d.dname, d.loc
    INTO l_ename, l_job, l_sal, l_comm, l_hdate, l_mgr,
         l_dname, l_loc
    FROM emp e
    JOIN dept d ON d.deptno = e.deptno
   WHERE e.ename = 'KING';

  -- Resolve manager name (KING has no manager; handle NULL gracefully).
  BEGIN
    SELECT ename INTO l_mgr_name FROM emp WHERE empno = l_mgr;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_mgr_name := NULL; END;

  -- --------------------------------------------------------------------------
  -- Build the bind array.  Keys are case-insensitive at substitution time.
  -- Values are auto-escaped: & → &amp;  < → &lt;  > → &gt;
  -- --------------------------------------------------------------------------
  l_binds(1).key   := 'ENAME';  l_binds(1).value := INITCAP(l_ename);
  l_binds(2).key   := 'JOB';   l_binds(2).value := INITCAP(l_job);
  l_binds(3).key   := 'SAL';   l_binds(3).value := TO_CHAR(l_sal, 'FM999,990.00');
  l_binds(4).key   := 'DNAME'; l_binds(4).value := INITCAP(l_dname);
  l_binds(5).key   := 'LOC';   l_binds(5).value := INITCAP(l_loc);
  l_binds(6).key   := 'HDATE'; l_binds(6).value := TO_CHAR(l_hdate, 'DD Month YYYY');

  -- COMM is NULL for KING; the <if bind="COMM"> block will be suppressed.
  IF l_comm IS NOT NULL THEN
    l_binds(7).key   := 'COMM';
    l_binds(7).value := TO_CHAR(l_comm, 'FM999,990.00');
  END IF;

  -- MGR_NAME may be NULL; the <if bind="MGR_NAME"> block handles it.
  IF l_mgr_name IS NOT NULL THEN
    l_binds(8).key   := 'MGR_NAME';
    l_binds(8).value := INITCAP(l_mgr_name);
  END IF;

  -- --------------------------------------------------------------------------
  -- Render.
  -- --------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,

    -- Inline markup inside a heading: #ENAME# is replaced by the bind value.
    '<h1>Employee Profile - <b>#ENAME#</b></h1>'                               ||

    -- Paragraph with inline bold and <br/> line breaks.
    '<p>'
      || '<b>Department:</b> #DNAME# - #LOC#<br/>'
      || '<b>Job title:</b>  #JOB#<br/>'
      || '<b>Hired:</b>      #HDATE#<br/>'
      || '<b>Salary:</b>     #SAL#'
      || '</p>'                                                                 ||

    -- Conditional block: rendered only when COMM is non-NULL and non-empty.
    -- If COMM was never added to the bind array the block is silently removed.
    '<if bind="COMM">'
      || '<p><b>Commission:</b> #COMM#</p>'
      || '</if>'                                                                ||

    -- Conditional block for manager (absent when the employee has no manager).
    '<if bind="MGR_NAME">'
      || '<p><b>Reports to:</b> <i>#MGR_NAME#</i></p>'
      || '</if>'                                                                ||

    '<spacer height="10pt"/>'                                                   ||
    '<hr color="CCCCCC" width="0.5"/>'                                          ||
    '<spacer height="8pt"/>'                                                    ||
    '<p style="caption">Report generated: '
      || TO_CHAR(SYSDATE, 'DD Month YYYY HH24:MI')
      || '</p>',

    l_binds);   -- pass the bind array as the third argument

  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF generated - size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  -- :rad_pdf := l_pdf;
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE(
      'Employee KING not found - are EMP/DEPT demo tables loaded?');
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
/
