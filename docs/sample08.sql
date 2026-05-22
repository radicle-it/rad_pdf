-- =============================================================================
-- sample08.sql  —  Wide table in landscape orientation
-- =============================================================================
--
-- WHAT THIS SHOWS
--   • rad_pdf.set_page_orientation — switches the current page to LANDSCAPE,
--     swapping width and height.  A4 landscape becomes 842 × 595 pt instead
--     of the default 595 × 842 pt portrait.
--   • How to lay out a wide table (7 columns) that would overflow in portrait
--     but fits comfortably after switching orientation.
--
-- WHEN TO USE LANDSCAPE
--   Use landscape when your table has many columns and the total column width
--   exceeds the portrait printable area (~510 pt for A4 with default margins).
--   Landscape A4 provides ~786 pt of printable width (842 - 2 × 28 pt margin).
--
-- IMPORTANT: call set_page_orientation immediately after new_document, before
--   adding any content.  It changes the geometry of the current page only.
--   If you call new_page() later, subsequent pages will also be landscape
--   because the page format is stored per-document, not per-page.
--
-- HOW TO RUN
--   Same as sample01.sql — see its header for save/download options.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns;
  l_clr  rad_pdf_types.t_color_scheme;
BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Column definitions
  -- 7 columns totalling 620 pt — fits landscape A4 (~786 pt printable),
  -- but would overflow portrait A4 (~510 pt printable).
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(7);

  l_cols(1).label              := 'Month';
  l_cols(1).width              := 55;

  l_cols(2).label              := 'New Clients';
  l_cols(2).width              := 80;
  l_cols(2).data_fmt.align_h   := 'R';
  l_cols(2).header_fmt.align_h := 'C';

  l_cols(3).label              := 'Revenue ($K)';
  l_cols(3).width              := 95;
  l_cols(3).data_fmt.align_h   := 'R';
  l_cols(3).header_fmt.align_h := 'C';
  l_cols(3).data_fmt.num_format := 'FM999,990.0';

  l_cols(4).label              := 'Expenses ($K)';
  l_cols(4).width              := 95;
  l_cols(4).data_fmt.align_h   := 'R';
  l_cols(4).header_fmt.align_h := 'C';
  l_cols(4).data_fmt.num_format := 'FM999,990.0';

  l_cols(5).label              := 'Gross Profit';
  l_cols(5).width              := 95;
  l_cols(5).data_fmt.align_h   := 'R';
  l_cols(5).header_fmt.align_h := 'C';
  l_cols(5).data_fmt.num_format := 'FM999,990.0';

  l_cols(6).label              := 'Margin %';
  l_cols(6).width              := 75;
  l_cols(6).data_fmt.align_h   := 'R';
  l_cols(6).header_fmt.align_h := 'C';
  l_cols(6).data_fmt.num_format := 'FM990.0';

  l_cols(7).label              := 'YoY Change';
  l_cols(7).width              := 75;
  l_cols(7).data_fmt.align_h   := 'C';
  l_cols(7).header_fmt.align_h := 'C';

  -- Deep teal color scheme
  l_clr.header_paper  := '1B5E7B';
  l_clr.header_ink    := 'FFFFFF';
  l_clr.header_border := '1B5E7B';
  l_clr.odd_paper     := 'E8F4F8';
  l_clr.odd_border    := 'B0D4E0';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.even_border   := 'B0D4E0';

  -- =========================================================================
  -- New document — switch to landscape before adding any content
  -- =========================================================================
  l_doc := rad_pdf.new_document;
  rad_pdf.set_page_orientation(l_doc, 'LANDSCAPE');

  rad_pdf.heading(l_doc, 'Annual Performance Summary 2025', 1);
  rad_pdf.write  (l_doc,
    'Monthly breakdown of revenue, expenses, and margin. ' ||
    'All figures in thousands of USD.');
  rad_pdf.spacer (l_doc, 8);

  rad_pdf.query2table(l_doc,
    'SELECT mon, new_clients, revenue, expenses, ' ||
    '       revenue - expenses             AS gross_profit, ' ||
    '       ROUND((revenue - expenses) / revenue * 100, 1) AS margin_pct, ' ||
    '       yoy_change ' ||
    'FROM ( ' ||
    '  SELECT ''Jan'' mon,  8 new_clients, 410.0 revenue, 295.0 expenses, ''+14%'' yoy_change FROM DUAL UNION ALL ' ||
    '  SELECT ''Feb'',      6,             390.5,          278.0,          ''+11%''           FROM DUAL UNION ALL ' ||
    '  SELECT ''Mar'',     11,             445.0,          301.0,          ''+18%''           FROM DUAL UNION ALL ' ||
    '  SELECT ''Apr'',      9,             430.2,          290.5,          ''+15%''           FROM DUAL UNION ALL ' ||
    '  SELECT ''May'',      7,             415.8,          283.0,          ''+12%''           FROM DUAL UNION ALL ' ||
    '  SELECT ''Jun'',     13,             490.0,          318.0,          ''+22%''           FROM DUAL UNION ALL ' ||
    '  SELECT ''Jul'',     10,             460.0,          305.0,          ''+19%''           FROM DUAL UNION ALL ' ||
    '  SELECT ''Aug'',      8,             435.5,          294.0,          ''+16%''           FROM DUAL UNION ALL ' ||
    '  SELECT ''Sep'',     12,             475.0,          312.0,          ''+21%''           FROM DUAL UNION ALL ' ||
    '  SELECT ''Oct'',     14,             510.0,          330.0,          ''+24%''           FROM DUAL UNION ALL ' ||
    '  SELECT ''Nov'',     11,             488.0,          316.0,          ''+20%''           FROM DUAL UNION ALL ' ||
    '  SELECT ''Dec'',     15,             525.0,          338.0,          ''+26%''           FROM DUAL ' ||
    ')',
    l_cols,
    p_colors => l_clr);

  -- =========================================================================
  -- Finalise
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF generated — size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  -- :rad_pdf := l_pdf;
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
