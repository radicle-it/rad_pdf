-- =============================================================================
-- sample07.sql  -  Label sheet: query2labels with t_label_def
-- =============================================================================
--
-- WHAT THIS SHOWS
--   • rad_pdf_types.t_label_def    - defines the physical layout of one label and
--                                 how many labels fit across and down the page
--   • rad_pdf_table.query2labels   - fills labels left-to-right, top-to-bottom,
--                                 exactly like peel-off label sheets
--   • Column definitions control how data appears inside each label cell
--
-- LABEL GEOMETRY (t_label_def fields, all in points)
--   max_columns  - labels per row              (default 2)
--   max_rows     - label rows per page         (default 8)
--   width        - width of one label          (default ~60 mm)
--   height       - height of one label         (default ~30 mm)
--   h_distance   - horizontal gap between labels
--   v_distance   - vertical gap between labels
--
--   The sample below targets Avery L7159 (or compatible) - 3 columns × 8 rows
--   = 24 labels per A4 page, each 70 × 37.1 mm.
--   For other sizes, look up the specification in the manufacturer's PDF
--   template library and convert mm → pt (1 mm = 2.8346 pt).
--
-- MULTI-LINE LABELS USING cell_row
--   Each column definition can be placed on a different text row inside the
--   label by setting cell_row:
--     cell_row = 1 → first line of the label
--     cell_row = 2 → second line (appears below the first)
--   This lets you stack a bold name on line 1 and an address on line 2
--   without needing separate label-height paragraphs.
--
-- NOTE: query2labels lives in rad_pdf_table, not in the rad_pdf facade.
--
-- HOW TO RUN
--   Same as sample01.sql - see its header for save/download options.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_cols  rad_pdf_types.t_columns;
  l_label rad_pdf_types.t_label_def;
  l_clr   rad_pdf_types.t_color_scheme;
BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Label sheet layout
  -- Avery L7159 / compatible: 3 × 8 = 24 labels per A4 page
  --   70 mm wide   = 70 × 2.8346 ≈ 198.4 pt
  --   37.1 mm tall = 37.1 × 2.8346 ≈ 105.2 pt
  --   No horizontal or vertical gap between labels
  -- =========================================================================
  l_label.max_columns := 3;
  l_label.max_rows    := 8;
  l_label.width       := 198.4;
  l_label.height      := 105.2;
  l_label.h_distance  := 0;
  l_label.v_distance  := 0;

  -- =========================================================================
  -- Column definitions
  -- Two columns stacked vertically inside each label:
  --   cell_row = 1 → company name (bold, larger)
  --   cell_row = 2 → mailing address (normal, smaller)
  -- Width equals the full label width for both rows.
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(2);

  l_cols(1).label               := NULL;     -- no column header row for labels
  l_cols(1).width               := 198.4;
  l_cols(1).cell_row            := 1;        -- first text line
  l_cols(1).data_fmt.font_style := 'B';
  l_cols(1).data_fmt.font_size  := 10;
  l_cols(1).data_fmt.align_h    := 'L';

  l_cols(2).label               := NULL;
  l_cols(2).width               := 198.4;
  l_cols(2).cell_row            := 2;        -- second text line
  l_cols(2).data_fmt.font_size  := 9;
  l_cols(2).data_fmt.align_h    := 'L';

  -- =========================================================================
  -- Color scheme - white background, thin grey border per label
  -- =========================================================================
  l_clr.header_paper  := 'FFFFFF';
  l_clr.header_ink    := '000000';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.odd_paper     := 'FFFFFF';
  l_clr.even_border   := 'BBBBBB';
  l_clr.odd_border    := 'BBBBBB';

  -- =========================================================================
  -- Build document
  -- =========================================================================
  l_doc := rad_pdf.new_document;

  -- query2labels is on rad_pdf_table, not on the rad_pdf facade.
  -- Replace the inline UNION ALL query with your own SELECT statement.
  rad_pdf_table.query2labels(l_doc,
    'SELECT full_name, address ' ||
    'FROM ( ' ||
    '  SELECT ''Acme Corporation''    full_name, ''1 Industrial Park, Milan 20100''     address FROM DUAL UNION ALL ' ||
    '  SELECT ''Beta Supplies Ltd.'',            ''42 Trade Street, Rome 00100''                 FROM DUAL UNION ALL ' ||
    '  SELECT ''Gamma Logistics'',               ''7 Harbour Way, Genoa 16100''                  FROM DUAL UNION ALL ' ||
    '  SELECT ''Delta Services'',                ''99 Business Ave, Turin 10100''                FROM DUAL UNION ALL ' ||
    '  SELECT ''Epsilon Group'',                 ''3 Commerce Blvd, Florence 50100''             FROM DUAL UNION ALL ' ||
    '  SELECT ''Zeta Partners'',                 ''15 Tech Lane, Bologna 40100''                 FROM DUAL UNION ALL ' ||
    '  SELECT ''Eta Consulting'',                ''8 Forum Square, Naples 80100''                FROM DUAL UNION ALL ' ||
    '  SELECT ''Theta Retail'',                  ''22 High Street, Venice 30100''                FROM DUAL UNION ALL ' ||
    '  SELECT ''Iota Ventures'',                 ''11 Gateway Plaza, Bari 70100''                FROM DUAL UNION ALL ' ||
    '  SELECT ''Kappa Systems'',                 ''5 Innovation Drive, Catania 95100''           FROM DUAL ' ||
    ')',
    l_cols,
    p_label  => l_label,
    p_colors => l_clr);

  -- =========================================================================
  -- Finalise
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF generated - size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  -- :rad_pdf := l_pdf;
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
