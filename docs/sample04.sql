-- =============================================================================
-- sample04.sql  —  Table report: query2table with column definitions
-- =============================================================================
--
-- WHAT THIS SHOWS
--   How to produce a formatted table from a SQL query using rad_pdf.query2table.
--   • rad_pdf_types.t_columns      — nested table of t_column_def records; defines
--                                 label, width, alignment, and number format
--                                 for each column
--   • rad_pdf_types.t_color_scheme — six color fields controlling the header row
--                                 and alternating data row backgrounds/borders
--   • rad_pdf_types.t_table_options — positioning overrides (start_x / start_y)
--                                 and row-height settings
--   • The layout engine handles page breaks automatically when the table is
--     taller than the printable area — no manual page management needed
--
-- COLUMN WIDTH ARITHMETIC
--   Column widths are in points by default (pt).  A4 portrait printable width
--   is approximately 510 pt (595 minus left + right margins of ~28 pt each).
--   The four columns here total 390 pt, leaving comfortable padding.
--   To use mm or cm, set p_options.unit := 'mm' and supply widths in mm.
--
-- ALIGNMENT CODES
--   'L' left  (default for text columns)
--   'C' center
--   'R' right  (use for numbers)
--   'J' justify
--
-- NUMBER FORMATS
--   num_format uses the same Oracle TO_CHAR format mask as SQL.
--   FM prefix suppresses leading spaces.  Examples:
--     'FM999,999.00'    →  1,234.56
--     'FM999,990.0'     →  1,234.5  (trailing zero when < 1000)
--     'FM$999,999,990'  →  $1,234,567
--
-- HOW TO RUN
--   Same as sample01.sql — see its header for save/download options.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_info rad_pdf_types.t_doc_info;
  l_pdf  BLOB;

  -- t_columns is a nested table (varray) of t_column_def records.
  -- Always initialise it with the empty constructor, then EXTEND.
  l_cols rad_pdf_types.t_columns;

  -- t_color_scheme holds header and two alternating row styles (odd / even).
  l_clr  rad_pdf_types.t_color_scheme;

  -- t_table_options controls positioning, row heights, break groups, etc.
  l_opts rad_pdf_types.t_table_options;
BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Column definitions
  -- Widths are in points.  Total: 40 + 190 + 90 + 70 = 390 pt.
  -- header_fmt controls the header cell; data_fmt controls every data row.
  -- Fields not set inherit the package defaults (Helvetica 10 pt, left-aligned).
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(4);   -- must EXTEND before assigning subscripts

  -- Column 1: row number — narrow, data right-aligned, header centered
  l_cols(1).label              := '#';
  l_cols(1).width              := 40;
  l_cols(1).data_fmt.align_h   := 'R';
  l_cols(1).header_fmt.align_h := 'C';

  -- Column 2: product name — wider, left-aligned (default)
  l_cols(2).label              := 'Product Name';
  l_cols(2).width              := 190;

  -- Column 3: unit price — right-aligned with FM format mask
  l_cols(3).label              := 'Unit Price';
  l_cols(3).width              := 90;
  l_cols(3).data_fmt.align_h   := 'R';
  l_cols(3).data_fmt.num_format := 'FM999,999.00';

  -- Column 4: yes/no flag — narrow, centered
  l_cols(4).label              := 'In Stock';
  l_cols(4).width              := 70;
  l_cols(4).data_fmt.align_h   := 'C';

  -- =========================================================================
  -- Color scheme
  -- Header: white text on navy blue.  Odd rows: light blue stripe.
  -- All color values are 6-character hex RGB strings — no '#' prefix.
  -- =========================================================================
  l_clr.header_paper  := '003366';   -- navy background
  l_clr.header_ink    := 'FFFFFF';   -- white text on header
  l_clr.header_border := '003366';
  l_clr.even_paper    := 'FFFFFF';   -- white rows
  l_clr.odd_paper     := 'EEF4FF';   -- light blue stripe on odd rows
  l_clr.even_border   := 'CCCCCC';
  l_clr.odd_border    := 'CCCCCC';

  -- =========================================================================
  -- Table options
  -- start_x = 0 / start_y = 0 means follow the layout engine cursor.
  -- Override these to place the table at a fixed absolute position (in pt).
  -- =========================================================================
  l_opts.unit    := 'pt';
  l_opts.start_x := 0;
  l_opts.start_y := 0;

  -- =========================================================================
  -- Document metadata and opening content
  -- =========================================================================
  l_info.title  := 'Product Catalogue';
  l_info.author := 'RAD_PDF Sample';
  l_doc := rad_pdf.new_document(p_info => l_info);

  rad_pdf.heading(l_doc, 'Product Catalogue', 1);
  rad_pdf.write  (l_doc, 'Showing all products currently in inventory.');
  rad_pdf.spacer (l_doc, 10);

  -- =========================================================================
  -- Render the table
  -- The query runs with the caller's privileges (AUTHID CURRENT_USER) at
  -- finalize time.  Any SELECT the caller can execute is valid here.
  -- CONNECT BY LEVEL is a convenient way to generate test data without a table.
  -- =========================================================================
  rad_pdf.query2table(l_doc,
    'SELECT ' ||
    '  LEVEL                          AS num, ' ||
    '  ''Product '' || TO_CHAR(LEVEL) AS product_name, ' ||
    '  ROUND(9.99 + LEVEL * 4.50, 2) AS unit_price, ' ||
    '  CASE WHEN MOD(LEVEL,3)=0 ' ||
    '       THEN ''No'' ELSE ''Yes'' END AS in_stock ' ||
    'FROM DUAL CONNECT BY LEVEL <= 15',
    l_cols,
    p_colors  => l_clr,
    p_options => l_opts);

  -- =========================================================================
  -- Footer text
  -- 'caption' is a built-in style: Helvetica Italic 8 pt, grey
  -- =========================================================================
  rad_pdf.spacer(l_doc, 12);
  rad_pdf.write (l_doc, 'End of catalogue.', 'caption');

  -- =========================================================================
  -- Finalise
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF generated — size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  -- :rad_pdf := l_pdf;
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
