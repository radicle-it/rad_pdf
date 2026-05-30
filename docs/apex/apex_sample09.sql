-- =============================================================================
-- apex_sample09.sql  -  Conditional watermark in APEX
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A document that conditionally stamps a "DRAFT" watermark based on the
--   value of an APEX page item (P1_IS_DRAFT). If the item equals 'Y', the
--   watermark is applied; otherwise the document is produced without one.
--   A second example shows checking an APEX authorization scheme instead.
--
-- KEY TECHNIQUES
--   - rad_pdf.set_watermark: register watermark only when needed
--   - rad_pdf.clear_watermark: remove it if conditions change (not needed here
--     but shown for completeness)
--   - :P1_IS_DRAFT APEX bind variable drives the conditional logic
--   - rad_pdf.set_watermark replaces any previous call - safe to call inside
--     a loop or condition block without checking first
--   - Opacity and angle are tunable per-call without code changes
--
-- CONDITIONAL WATERMARK STRATEGIES
--   Strategy 1 (this file): page item P1_IS_DRAFT = 'Y'
--   Strategy 2: APEX authorization scheme (see example at bottom of file)
--   Strategy 3: query-based (e.g. document status column from a table)
--
-- COLUMN STRATEGY
--   EmpNo   - fixed 42 pt
--   Name    - auto-width (fits the longest employee name)
--   Job     - auto-width
--   Hired   - auto-width
--   Salary  - fixed 72 pt, right-aligned, formatted
--
-- DATA
--   Uses EMP / DEPT (Scott schema). Replace with your own query.
--
-- WHERE TO PUT THIS CODE
--   Processing -> Execute Server-side Code
--   Point:  On Load - Before Header
--
-- PAGE ITEMS REQUIRED
--   P1_IS_DRAFT  VARCHAR2(1)  default 'N'
--   Set to 'Y' to enable the watermark, 'N' to disable it.
--
-- PREREQUISITES
--   RAD_PDF v1.4.0+ installed in the workspace schema (or with synonyms).
--   See docs/apex/README.md.
-- =============================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_cols   rad_pdf_types.t_columns;
  l_clr    rad_pdf_types.t_color_scheme;
  i        PLS_INTEGER;

  -- Read the page item that controls draft status.
  -- In a real app this might come from a status column: v('P1_STATUS') = 'DRAFT'
  l_is_draft BOOLEAN := (NVL(:P1_IS_DRAFT, 'N') = 'Y');

  l_today  VARCHAR2(30) := TO_CHAR(SYSDATE, 'DD-MON-YYYY');

BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- Conditional watermark
  -- The call is inside the IF block so no watermark state is set when the
  -- condition is false. If you prefer, always call set_watermark and
  -- conditionally call clear_watermark, but the IF approach is cleaner.
  -- =========================================================================
  IF l_is_draft THEN
    rad_pdf.set_watermark(
      p_doc       => l_doc,
      p_text      => 'DRAFT',
      p_font_name => 'Helvetica',
      p_font_size => 72,
      p_color     => 'C0C0C0',
      p_opacity   => 0.3,
      p_angle     => 45,
      p_layer     => 'UNDER');
  END IF;

  -- =========================================================================
  -- Column definitions
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(5);

  FOR i IN 1..5 LOOP
    l_cols(i).data_fmt.margin_top    := 4;
    l_cols(i).data_fmt.margin_bot    := 4;
    l_cols(i).data_fmt.margin_left   := 5;
    l_cols(i).data_fmt.margin_rgt    := 5;
    l_cols(i).header_fmt.margin_top  := 4;
    l_cols(i).header_fmt.margin_bot  := 4;
    l_cols(i).header_fmt.margin_left := 5;
    l_cols(i).header_fmt.margin_rgt  := 5;
    l_cols(i).header_fmt.font_style  := 'B';
    l_cols(i).header_fmt.back_color  := '1A3A5C';
    l_cols(i).header_fmt.font_color  := 'FFFFFF';
    l_cols(i).header_fmt.border      := rad_pdf_types.c_border_all;
    l_cols(i).data_fmt.border        := rad_pdf_types.c_border_all;
  END LOOP;

  l_cols(1).label              := 'No';
  l_cols(1).width              := 42;
  l_cols(1).header_fmt.align_h := 'C';
  l_cols(1).data_fmt.align_h   := 'C';

  l_cols(2).label      := 'Name';
  l_cols(2).width      := 50;
  l_cols(2).auto_width := TRUE;

  l_cols(3).label      := 'Job';
  l_cols(3).width      := 40;
  l_cols(3).auto_width := TRUE;

  l_cols(4).label              := 'Hired';
  l_cols(4).width              := 50;
  l_cols(4).auto_width         := TRUE;
  l_cols(4).header_fmt.align_h := 'C';
  l_cols(4).data_fmt.align_h   := 'C';

  l_cols(5).label               := 'Salary';
  l_cols(5).width               := 72;
  l_cols(5).header_fmt.align_h  := 'R';
  l_cols(5).data_fmt.align_h    := 'R';
  l_cols(5).data_fmt.num_format := '999,990.00';

  -- =========================================================================
  -- Color scheme
  -- =========================================================================
  l_clr.header_paper  := '1A3A5C';
  l_clr.header_ink    := 'FFFFFF';
  l_clr.header_border := '1A3A5C';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.odd_paper     := 'EAF0FB';
  l_clr.even_border   := 'AAAAAA';
  l_clr.odd_border    := 'AAAAAA';

  -- =========================================================================
  -- Document content
  -- =========================================================================
  rad_pdf.heading(l_doc, 'Employee Roster', 1);
  rad_pdf.write(l_doc,
    CASE WHEN l_is_draft
         THEN 'This is a draft report. The watermark indicates the document '
           || 'has not yet been approved for distribution.'
         ELSE 'Final approved employee roster.'
    END);

  rad_pdf.query2table(l_doc,
    'SELECT TO_CHAR(empno),'
    || ' INITCAP(ename),'
    || ' INITCAP(job),'
    || ' TO_CHAR(hiredate, ''DD-Mon-YYYY''),'
    || ' sal'
    || ' FROM emp'
    || ' ORDER BY ename',
    l_cols,
    p_colors => l_clr);

  rad_pdf.write(l_doc, 'Generated: ' || l_today);

  -- =========================================================================
  -- Output
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="employee_roster.pdf"');
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

-- =============================================================================
-- Alternative: Authorization-scheme-based watermark
-- =============================================================================
-- Replace the conditional block above with the following snippet to apply the
-- watermark whenever the current APEX user does NOT hold the 'REPORT_APPROVER'
-- authorization scheme (i.e. they can see only draft-level documents):
--
--   IF NOT APEX_AUTHORIZATION.IS_AUTHORIZED('REPORT_APPROVER') THEN
--     rad_pdf.set_watermark(
--       p_doc       => l_doc,
--       p_text      => 'INTERNAL USE ONLY',
--       p_font_name => 'Helvetica',
--       p_font_size => 48,
--       p_color     => 'FF0000',
--       p_opacity   => 0.15,
--       p_angle     => 45,
--       p_layer     => 'UNDER');
--   END IF;
--
-- Combining both strategies is also valid:
--   IF l_is_draft THEN
--     rad_pdf.set_watermark(l_doc, 'DRAFT', p_opacity => 0.3);
--   ELSIF NOT APEX_AUTHORIZATION.IS_AUTHORIZED('REPORT_APPROVER') THEN
--     rad_pdf.set_watermark(l_doc, 'RESTRICTED', p_opacity => 0.2);
--   END IF;
-- =============================================================================
