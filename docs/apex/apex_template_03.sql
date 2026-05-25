-- apex_template_03.sql  —  Inline formatting: <b>, <i>, <br/>
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Mixing plain text with bold and italic runs inside a single paragraph:
--     <b>...</b>   bold run
--     <i>...</i>   italic run
--     <br/>        forced line break within the paragraph
--
--   When a paragraph contains ANY inline tag, the layout engine renders all
--   runs on the same word-wrapped line (PARA_RUNS flowable).  This is the
--   correct behaviour — text does not "jump" to separate lines.
--
-- APEX SETUP
--   Page item: P1_DEPTNO (department number)
--   Process: Execute Server-side Code — On Load - Before Header
--
-- EMP / DEPT USAGE
--   Lists all employees in the selected department with formatted salary.
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_dname  DEPT.DNAME%TYPE;
  l_loc    DEPT.LOC%TYPE;

  -- Build a paragraph listing every employee in the department.
  -- We accumulate names into a VARCHAR2 and use <br/> to separate them.
  l_roster VARCHAR2(32767);

  CURSOR c_emp(p_deptno NUMBER) IS
    SELECT ename, job,
           TO_CHAR(sal, 'FM999,990.00') AS sal_fmt,
           TO_CHAR(hiredate, 'DD-Mon-YYYY') AS hire_fmt
      FROM emp
     WHERE deptno = p_deptno
     ORDER BY ename;

BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Resolve department data
  -- -------------------------------------------------------------------------
  SELECT dname, loc
    INTO l_dname, l_loc
    FROM dept
   WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  -- -------------------------------------------------------------------------
  -- 2. Build the employee list paragraph.
  --    Each line: "ENAME (job)   Salary: 99,999.00   Hired: DD-Mon-YYYY"
  --    Employee name is bold, job is italic, salary is bold, rest is plain.
  --    Lines are separated by <br/>.
  -- -------------------------------------------------------------------------
  l_roster := '';
  FOR r IN c_emp(TO_NUMBER(:P1_DEPTNO)) LOOP
    IF l_roster IS NOT NULL THEN
      l_roster := l_roster || '<br/>';
    END IF;
    l_roster := l_roster
      || '<b>' || r.ename || '</b>'
      || ' (<i>' || INITCAP(r.job) || '</i>)'
      || '   Salary: <b>' || r.sal_fmt || '</b>'
      || '   Hired: ' || r.hire_fmt;
  END LOOP;

  IF l_roster IS NULL THEN
    l_roster := '<i>No employees in this department.</i>';
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Build binds
  -- -------------------------------------------------------------------------
  l_binds(1).key   := 'DNAME';
  l_binds(1).value := l_dname;

  l_binds(2).key   := 'LOC';
  l_binds(2).value := INITCAP(l_loc);

  l_binds(3).key   := 'DEPTNO';
  l_binds(3).value := :P1_DEPTNO;

  l_binds(4).key   := 'ROSTER';
  -- The roster already contains template tags (<b>, <i>, <br/>).
  -- raw=TRUE tells render() NOT to escape the value — otherwise < and >
  -- would be converted to &lt; and &gt; and the tags would appear as text.
  l_binds(4).value := l_roster;
  l_binds(4).raw   := TRUE;

  l_binds(5).key   := 'GEN_DATE';
  l_binds(5).value := TO_CHAR(SYSDATE, 'DD Month YYYY');

  -- -------------------------------------------------------------------------
  -- 4. Template
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,
    '<h1>Department #DNAME#</h1>'                                          ||
    '<p>Location: <b>#LOC#</b>   Department no.: <b>#DEPTNO#</b></p>'     ||
    '<spacer height="10pt"/>'                                              ||
    '<hr color="003366"/>'                                                 ||
    '<spacer height="8pt"/>'                                               ||

    -- This paragraph header uses <b> and <i> — it goes through PARA_RUNS
    -- so the bold/italic text appears inline with the plain text.
    '<h2>Employee Roster</h2>'                                             ||
    '<p>#ROSTER#</p>'                                                      ||

    '<spacer height="14pt"/>'                                              ||
    '<hr color="AAAAAA" width="0.5"/>'                                     ||

    -- A paragraph that mixes bold, italic, and plain text in one line.
    '<p>This report covers <b>department #DEPTNO#</b> '                   ||
    '(<i>#DNAME#</i>).  Generated on <b>#GEN_DATE#</b>.</p>',
    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="dept_' ||
        :P1_DEPTNO || '_roster.pdf"');
  OWA_UTIL.HTTP_HEADER_CLOSE;
  WPG_DOCLOAD.DOWNLOAD_FILE(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  APEX_APPLICATION.STOP_APEX_ENGINE;

EXCEPTION
  WHEN APEX_APPLICATION.E_STOP_APEX_ENGINE THEN RAISE;
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
