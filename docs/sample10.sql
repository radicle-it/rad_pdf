-- =============================================================================
-- sample10.sql  -  Table with text wrapping in cells
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A table where one column has wrap = TRUE, causing long text to flow across
--   multiple lines within the cell. Row heights adjust dynamically to fit the
--   wrapped content.
--
-- KEY TECHNIQUES
--   - wrap = TRUE on t_column_def enables multi-line cell text
--   - Row height is computed per row based on actual wrapped content
--   - Columns without wrap = TRUE use the fixed row height as usual
--   - wrap is FALSE by default; existing tables are unaffected
--   - Oracle EXTEND creates NULL records: all margin fields must be set explicitly
--
-- DATA
--   Uses a synthetic NOTES table built with a WITH clause so no schema objects
--   are needed. Replace with a real table query in your environment.
--
-- HOW TO RUN
--   Option A - SQL*Plus or SQL Developer:
--     Run as-is; the file size is printed to confirm success.
--
--   Option B - Save to file via Oracle Directory:
--     Uncomment the rad_pdf.save() call and set your directory name.
--     CREATE OR REPLACE DIRECTORY PDF_OUT AS '/tmp/rad_pdf';
--     GRANT WRITE ON DIRECTORY PDF_OUT TO your_schema;
--
--   Option C - SQL Developer bind variable:
--     Uncomment the ":rad_pdf := l_pdf" line, then right-click the BLOB result
--     and choose Save As.
--
-- PREREQUISITES
--   RAD_PDF packages installed in the current schema (run src/install.sql).
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns;
  l_clr  rad_pdf_types.t_color_scheme;
  i      PLS_INTEGER;
BEGIN
  rad_pdf_styles.load_defaults;

  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- Column definitions
  -- 3 columns: ID (narrow), Subject (medium), Notes (wide, wrap enabled)
  -- Total width = 42 + 120 + 328 = 490 pt (fits A4 with 42 pt margins each side)
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(3);

  -- Oracle EXTEND creates NULL records; set all margin fields explicitly.
  FOR i IN 1..3 LOOP
    l_cols(i).data_fmt.margin_top    := 5;
    l_cols(i).data_fmt.margin_bot    := 5;
    l_cols(i).data_fmt.margin_left   := 6;
    l_cols(i).data_fmt.margin_rgt    := 6;
    l_cols(i).header_fmt.margin_top  := 5;
    l_cols(i).header_fmt.margin_bot  := 5;
    l_cols(i).header_fmt.margin_left := 6;
    l_cols(i).header_fmt.margin_rgt  := 6;
  END LOOP;

  l_cols(1).label              := '#';
  l_cols(1).width              := 42;
  l_cols(1).data_fmt.align_h   := 'C';
  l_cols(1).header_fmt.align_h := 'C';

  l_cols(2).label := 'Subject';
  l_cols(2).width := 120;

  -- wrap = TRUE: text overflows across lines; row height grows to fit.
  l_cols(3).label            := 'Notes';
  l_cols(3).width            := 328;
  l_cols(3).wrap             := TRUE;

  -- =========================================================================
  -- Color scheme
  -- =========================================================================
  l_clr.header_paper  := '2C4770';
  l_clr.header_ink    := 'FFFFFF';
  l_clr.header_border := '2C4770';
  l_clr.odd_paper     := 'EEF2F8';
  l_clr.odd_border    := 'B0C4DE';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.even_border   := 'B0C4DE';

  -- =========================================================================
  -- Document content
  -- =========================================================================
  rad_pdf.heading(l_doc, 'Project Notes', 1);
  rad_pdf.write  (l_doc,
    'The Notes column uses wrap = TRUE. Each row grows vertically to fit ' ||
    'its content; other columns remain at the same height.');
  rad_pdf.spacer (l_doc, 8);

  rad_pdf.query2table(l_doc,
    'WITH notes (id, subject, note_text) AS (' ||
    '  SELECT 1, ''Kickoff'','                 ||
    '    ''Initial project kickoff completed. Team alignment achieved on '  ||
    '    scope and timeline. Action items distributed to all leads.'' '     ||
    '  FROM dual UNION ALL '                                                ||
    '  SELECT 2, ''Architecture Review'','                                  ||
    '    ''Reviewed the proposed three-tier architecture. Decision: adopt ' ||
    '    microservices for the reporting layer. Security review scheduled ' ||
    '    for next sprint.'' '                                               ||
    '  FROM dual UNION ALL '                                                ||
    '  SELECT 3, ''Performance'','                                          ||
    '    ''Query optimisation reduced average response time from 4.2 s to ' ||
    '    0.8 s. Index strategy documented in the wiki.'' '                  ||
    '  FROM dual UNION ALL '                                                ||
    '  SELECT 4, ''Release'','                                              ||
    '    ''Go-live confirmed. Rollback plan approved by change board. '     ||
    '    Monitoring dashboards updated.'' '                                 ||
    '  FROM dual '                                                          ||
    ') '                                                                    ||
    'SELECT id, subject, note_text FROM notes ORDER BY id',
    l_cols,
    p_colors => l_clr);

  rad_pdf.spacer(l_doc, 6);
  rad_pdf.write (l_doc,
    'Rows 2 and 3 contain longer text and expand automatically.', 'caption');

  -- =========================================================================
  -- Finalise
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');

  -- Option B: save to file
  -- rad_pdf.save(l_pdf, 'PDF_OUT', 'wrap_demo.pdf');

  -- Option C: SQL Developer bind variable
  -- :rad_pdf := l_pdf;

  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
