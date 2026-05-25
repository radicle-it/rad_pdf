-- sample11.sql - Template engine example (non-APEX)
--
-- Demonstrates rad_pdf_template.render:
--   - Bind placeholder substitution (#KEY#)
--   - Block tags: <h1>, <h2>, <p>, <spacer>, <hr>, <pagebreak>
--   - Inline tags inside <p>: <b>, <i>, <br/>
--   - <table> tag with registered column set (requires allow_queries)
--
-- Run in SQL*Plus from repo root.
-- The file is saved to the Oracle directory RAD_PDF_DIR.
-- Create the directory first:
--   CREATE OR REPLACE DIRECTORY rad_pdf_dir AS '/tmp';
--   GRANT READ, WRITE ON DIRECTORY rad_pdf_dir TO <your_schema>;

SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  -- -------------------------------------------------------------------------
  -- Column set for the <table> tag: three columns of the project summary.
  -- -------------------------------------------------------------------------
  l_cols  rad_pdf_types.t_columns;

  -- -------------------------------------------------------------------------
  -- Template stored in a CLOB (simulates a template loaded from a DB table).
  -- -------------------------------------------------------------------------
  l_tmpl  CLOB;

  -- -------------------------------------------------------------------------
  -- Bind values: replace #PLACEHOLDER# tokens in the template.
  -- -------------------------------------------------------------------------
  l_binds rad_pdf_types.t_bind_array;

  -- -------------------------------------------------------------------------
  -- Options: enable query execution for the <table> tag.
  -- -------------------------------------------------------------------------
  l_opts  rad_pdf_types.t_template_options;

  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;

  -- Helper: append a VARCHAR2 chunk to a CLOB.
  PROCEDURE wapp(p_clob IN OUT NOCOPY CLOB, p_str IN VARCHAR2) IS
  BEGIN
    IF p_str IS NOT NULL THEN
      DBMS_LOB.WRITEAPPEND(p_clob, LENGTH(p_str), p_str);
    END IF;
  END wapp;

BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Register column definitions for the <table> tag.
  -- -------------------------------------------------------------------------
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(3);

  -- Column 1: Project ID
  l_cols(1).label               := 'ID';
  l_cols(1).width               := 40;
  l_cols(1).header_fmt.align_h  := 'C';
  l_cols(1).data_fmt.align_h    := 'C';

  -- Column 2: Project Name
  l_cols(2).label               := 'Project';
  l_cols(2).width               := 180;

  -- Column 3: Status
  l_cols(3).label               := 'Status';
  l_cols(3).width               := 80;
  l_cols(3).header_fmt.align_h  := 'C';
  l_cols(3).data_fmt.align_h    := 'C';

  rad_pdf_template.register_columns('PROJ_COLS', l_cols);

  -- -------------------------------------------------------------------------
  -- 2. Build the template CLOB (in practice this would come from a DB table).
  -- -------------------------------------------------------------------------
  DBMS_LOB.CREATETEMPORARY(l_tmpl, TRUE);

  wapp(l_tmpl, '<h1>Project Status Report</h1>');
  wapp(l_tmpl, '<h2>Period: #PERIOD#</h2>');
  wapp(l_tmpl, '<p>Prepared by: <b>#AUTHOR#</b></p>');
  wapp(l_tmpl, '<spacer height="8pt"/>');
  wapp(l_tmpl, '<hr color="336699" width="1"/>');
  wapp(l_tmpl, '<spacer height="8pt"/>');

  wapp(l_tmpl, '<h2>Executive Summary</h2>');
  wapp(l_tmpl, '<p>');
  wapp(l_tmpl,   'This report summarises the status of <b>#TOTAL# active projects</b> ');
  wapp(l_tmpl,   'as of #PERIOD#.<br/>');
  wapp(l_tmpl,   'All figures have been reviewed and approved by the project office.');
  wapp(l_tmpl, '</p>');

  wapp(l_tmpl, '<spacer height="12pt"/>');

  wapp(l_tmpl, '<h2>Active Projects</h2>');
  wapp(l_tmpl, '<table columns="PROJ_COLS"');
  wapp(l_tmpl,        ' query="SELECT p.project_id, p.project_name, p.status');
  wapp(l_tmpl,                 ' FROM projects p');
  wapp(l_tmpl,                 ' WHERE p.status != ''CLOSED''');
  wapp(l_tmpl,                 ' ORDER BY p.project_id"');
  wapp(l_tmpl,        ' allow_query="true"/>');

  wapp(l_tmpl, '<pagebreak/>');

  wapp(l_tmpl, '<h2>Notes</h2>');
  wapp(l_tmpl, '<p>');
  wapp(l_tmpl,   'For questions regarding this report, contact ');
  wapp(l_tmpl,   '<i>#CONTACT#</i>.');
  wapp(l_tmpl, '</p>');

  -- -------------------------------------------------------------------------
  -- 3. Set bind values.
  -- -------------------------------------------------------------------------
  l_binds(1).key   := 'PERIOD';  l_binds(1).value := 'Q2 2026';
  l_binds(2).key   := 'AUTHOR';  l_binds(2).value := 'R. Capancioni';
  l_binds(3).key   := 'TOTAL';   l_binds(3).value := '12';
  l_binds(4).key   := 'CONTACT'; l_binds(4).value := 'pmo@example.com';

  -- -------------------------------------------------------------------------
  -- 4. Enable query execution (required for <table> tags).
  -- -------------------------------------------------------------------------
  l_opts.allow_queries := TRUE;

  -- -------------------------------------------------------------------------
  -- 5. Render the template.
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_tmpl, l_binds, l_opts);
  DBMS_LOB.FREETEMPORARY(l_tmpl);

  -- -------------------------------------------------------------------------
  -- 6. Save the PDF.
  -- -------------------------------------------------------------------------
  rad_pdf.save(l_doc, 'RAD_PDF_DIR', 'sample11_template.pdf');
  DBMS_OUTPUT.PUT_LINE('sample11_template.pdf written to RAD_PDF_DIR.');

EXCEPTION
  WHEN OTHERS THEN
    IF DBMS_LOB.ISTEMPORARY(l_tmpl) = 1 THEN DBMS_LOB.FREETEMPORARY(l_tmpl); END IF;
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
/
