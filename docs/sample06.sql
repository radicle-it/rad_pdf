-- =============================================================================
-- sample06.sql  —  Grouped report: refcursor2table with break_field
-- =============================================================================
--
-- WHAT THIS SHOWS
--   • rad_pdf_table.refcursor2table — feeds a SYS_REFCURSOR into the table engine
--     instead of a static SQL string.  Use this whenever you need:
--       - Runtime PL/SQL bind variables (APEX page items, local variables)
--       - A cursor opened by a stored procedure that you cannot reproduce as a
--         plain VARCHAR2 string
--       - Protection against SQL injection (the query is pre-parsed by Oracle
--         before the BLOB is generated)
--   • t_table_options.break_field — inserts a visual separator row each time
--     the value in the nominated column changes.  Column numbering is 1-based.
--     The nominated column must be the primary ORDER BY column.
--
-- GROUPING MECHANICS
--   Setting break_field = 1 tells the table engine to watch column 1 and
--   insert a blank separator row whenever its value changes.  This visually
--   groups rows without hiding the group label.
--
--   IMPORTANT: the query must already be sorted by the break column.
--   RAD_PDF does not sort the data for you.
--
-- NOTE: refcursor2table is on rad_pdf_table, not on the rad_pdf facade.
--   rad_pdf.query2table only accepts VARCHAR2 / CLOB queries.
--   For cursors, call rad_pdf_table.refcursor2table directly.
--
-- HOW TO RUN
--   Same as sample01.sql — see its header for save/download options.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns;
  l_opts rad_pdf_types.t_table_options;
  l_clr  rad_pdf_types.t_color_scheme;

  -- SYS_REFCURSOR is Oracle's built-in weak ref-cursor type.
  -- Open it with OPEN ... FOR before passing it to refcursor2table.
  l_rc   SYS_REFCURSOR;
BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Column definitions — Department | Employee | Annual Salary
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(3);

  l_cols(1).label              := 'Department';
  l_cols(1).width              := 150;

  l_cols(2).label              := 'Employee';
  l_cols(2).width              := 170;

  l_cols(3).label              := 'Annual Salary ($)';
  l_cols(3).width              := 120;
  l_cols(3).data_fmt.align_h   := 'R';
  l_cols(3).header_fmt.align_h := 'C';
  l_cols(3).data_fmt.num_format := 'FM999,999,990';

  -- =========================================================================
  -- Color scheme — green header, alternating off-white / white rows
  -- =========================================================================
  l_clr.header_paper  := '2E6B3E';
  l_clr.header_ink    := 'FFFFFF';
  l_clr.header_border := '2E6B3E';
  l_clr.odd_paper     := 'F0FAF2';
  l_clr.odd_border    := 'C8E6C9';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.even_border   := 'C8E6C9';

  -- =========================================================================
  -- Table options — activate grouping by column 1 (Department)
  -- =========================================================================
  l_opts.break_field := 1;   -- insert separator when column 1 value changes

  -- =========================================================================
  -- Open the cursor
  -- ORDER BY dept is required for break_field to produce correct separators.
  -- In a real application the FROM clause would reference actual tables.
  -- =========================================================================
  OPEN l_rc FOR
    SELECT dept, emp_name, salary
    FROM (
      SELECT 'Engineering' dept, 'Alice Chen'     emp_name, 95000 salary FROM DUAL UNION ALL
      SELECT 'Engineering',      'Bob Kumar',               88000         FROM DUAL UNION ALL
      SELECT 'Engineering',      'Carol Osei',              102000        FROM DUAL UNION ALL
      SELECT 'Finance',          'David Moreau',            78000         FROM DUAL UNION ALL
      SELECT 'Finance',          'Eve Nakamura',            82000         FROM DUAL UNION ALL
      SELECT 'Marketing',        'Frank Delgado',           71000         FROM DUAL UNION ALL
      SELECT 'Marketing',        'Grace Liu',               74000         FROM DUAL UNION ALL
      SELECT 'Marketing',        'Henry Walsh',             69000         FROM DUAL
    )
    ORDER BY dept, emp_name;

  -- =========================================================================
  -- Build document
  -- =========================================================================
  l_doc := rad_pdf.new_document;

  rad_pdf.heading(l_doc, 'Employee Directory by Department', 1);
  rad_pdf.spacer (l_doc, 6);

  -- refcursor2table consumes and closes the cursor.
  -- Do not reference l_rc after this call.
  rad_pdf_table.refcursor2table(l_doc, l_rc, l_cols,
    p_colors  => l_clr,
    p_options => l_opts);

  rad_pdf.spacer(l_doc, 8);
  rad_pdf.write (l_doc, 'Salary figures as at Q1 2026.', 'caption');

  -- =========================================================================
  -- Finalise
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF generated — size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  -- :rad_pdf := l_pdf;
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
