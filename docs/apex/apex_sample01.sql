-- =============================================================================
-- apex_sample01.sql  -  Minimal APEX page process: generate and stream a PDF
-- =============================================================================
--
-- WHAT THIS SHOWS
--   The minimum code to generate a PDF inside Oracle APEX and deliver it as
--   a file download to the user's browser.
--
-- DATA
--   Uses the standard EMP table (always present in Oracle databases).
--
-- WHERE TO PUT THIS CODE
--   In APEX App Builder:
--     1. Open your page in Page Designer.
--     2. In the Processing panel, create a new process:
--          Type:   Execute Server-side Code
--          Point:  On Load - Before Header   (must run before any HTML output)
--          Name:   Download PDF
--     3. Paste this code into the PL/SQL Code area (omit SET SERVEROUTPUT ON).
--
-- HOW THE DOWNLOAD WORKS
--   1. owa_util.mime_header tells the browser to expect a PDF BLOB.
--   2. htp.p adds optional HTTP headers (size, filename, cache control).
--   3. owa_util.http_header_close finalises the HTTP headers.
--   4. wpg_docload.download_file streams the BLOB as the HTTP response body.
--   5. apex_application.stop_apex_engine prevents APEX from appending HTML.
--
-- PROCESS ORDER
--   The process must run BEFORE APEX has sent any HTML to the browser.
--   "On Load - Before Header" is the correct point.
--
-- PREREQUISITES
--   RAD_PDF installed in (or accessible from) the workspace schema.
--   See docs/apex/README.md for installation options.
-- =============================================================================

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns;
  i      PLS_INTEGER;
BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Column definitions
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(4);

  -- Set comfortable cell padding on every column.
  -- Oracle EXTEND creates NULL records; type-level defaults are NOT applied.
  FOR i IN 1..4 LOOP
    l_cols(i).data_fmt.margin_top  := 4;
    l_cols(i).data_fmt.margin_bot  := 4;
    l_cols(i).data_fmt.margin_left := 5;
    l_cols(i).data_fmt.margin_rgt  := 5;
    l_cols(i).header_fmt.margin_top  := 4;
    l_cols(i).header_fmt.margin_bot  := 4;
    l_cols(i).header_fmt.margin_left := 5;
    l_cols(i).header_fmt.margin_rgt  := 5;
  END LOOP;

  l_cols(1).label              := 'Emp#';
  l_cols(1).width              := 55;
  l_cols(1).data_fmt.align_h   := 'R';
  l_cols(1).header_fmt.align_h := 'C';

  l_cols(2).label := 'Name';
  l_cols(2).width := 120;

  l_cols(3).label := 'Job';
  l_cols(3).width := 110;

  l_cols(4).label              := 'Salary';
  l_cols(4).width              := 90;
  l_cols(4).data_fmt.align_h   := 'R';
  l_cols(4).header_fmt.align_h := 'C';
  l_cols(4).data_fmt.num_format := 'FM999,999,990.00';

  -- =========================================================================
  -- Build document
  -- =========================================================================
  l_doc := rad_pdf.new_document;

  rad_pdf.heading(l_doc, 'Employee List', 1);
  rad_pdf.write  (l_doc,
    'Generated: ' || TO_CHAR(SYSDATE, 'DD-MON-YYYY HH24:MI') ||
    '  |  User: ' || V('APP_USER'));
  rad_pdf.spacer (l_doc, 8);

  rad_pdf.query2table(l_doc,
    'SELECT empno, ename, job, sal FROM emp ORDER BY ename',
    l_cols);

  -- =========================================================================
  -- Finalise and stream
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  owa_util.mime_header('application/pdf', FALSE);
  htp.p('Content-Length: ' || DBMS_LOB.getlength(l_pdf));
  htp.p('Content-Disposition: attachment; filename="employees_' ||
        TO_CHAR(SYSDATE, 'YYYYMMDD') || '.pdf"');
  htp.p('Cache-Control: no-store, no-cache, must-revalidate');
  htp.p('Pragma: no-cache');
  owa_util.http_header_close;
  wpg_docload.download_file(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);

  apex_application.stop_apex_engine;
END;
