-- =============================================================================
-- sample03.sql  -  Canvas API: precise positioning without the layout engine
-- =============================================================================
--
-- WHAT THIS SHOWS
--   The canvas API gives you absolute control over where every element appears.
--   Unlike the layout engine (rad_pdf.write / rad_pdf.heading), you specify exact
--   x / y coordinates in points (pt) from the lower-left corner of the page.
--
--   • rad_pdf_canvas.set_font    - choose font family, style, size
--   • rad_pdf_canvas.set_color   - set ink (text / line) colour
--   • rad_pdf_canvas.write_text  - place a string at an exact position
--   • rad_pdf_canvas.rect        - draw a filled and/or bordered rectangle
--   • rad_pdf_canvas.h_line      - draw a horizontal line
--   • rad_pdf_canvas.polygon     - draw an arbitrary filled polygon
--
-- COORDINATE SYSTEM
--   Origin (0, 0) is the BOTTOM-LEFT corner of the page.
--   Y increases UPWARD.  A4 portrait is 595 × 842 pt.
--   Example reference points:
--     Top of printable area ≈ y 800
--     Bottom of printable area ≈ y 40
--     Left margin ≈ x 50
--     Right margin ≈ x 545
--
-- WHEN TO USE THE CANVAS API
--   Use it for: watermarks, company letterhead, diagrams, custom grids,
--   direct drawing on top of layout-engine content.
--   Use the layout engine (sample01/02) for flowing text and tables.
--
-- HOW TO RUN
--   Same as sample01.sql - see its header for save/download options.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;

  -- t_number_list is used for polygon vertex coordinates
  l_xs  rad_pdf_types.t_number_list;
  l_ys  rad_pdf_types.t_number_list;
BEGIN
  -- new_document always creates the first page automatically
  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- Title bar: filled dark-blue rectangle + white text on top of it
  -- =========================================================================

  -- rect(doc, x, y, width, height, border_color, fill_color, line_width, unit)
  -- x/y is the LOWER-LEFT corner of the rectangle
  rad_pdf_canvas.rect(l_doc,
    50, 770,          -- lower-left corner: x=50, y=770
    495, 30,          -- width=495, height=30
    p_line_color => '003366',
    p_fill_color => '003366',   -- solid navy blue fill
    p_unit       => 'pt');

  -- Switch to white ink for text on the dark background
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 16);
  rad_pdf_canvas.set_color(l_doc, 'FFFFFF');   -- white

  -- write_text(doc, text, x, y, unit)
  -- y=779 places the baseline 9 pt above the rectangle bottom (y=770)
  rad_pdf_canvas.write_text(l_doc, 'RAD_PDF - Canvas Drawing Sample', 58, 779, 'pt');

  -- =========================================================================
  -- Body text (back to black)
  -- =========================================================================
  rad_pdf_canvas.set_color(l_doc, '000000');
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'N', 10);
  rad_pdf_canvas.write_text(l_doc,
    'Each element is placed at an explicit coordinate in points.', 50, 750, 'pt');

  -- =========================================================================
  -- Horizontal separator line
  -- h_line(doc, x, y, width, thickness, color, unit)
  -- =========================================================================
  rad_pdf_canvas.h_line(l_doc, 50, 740, 495, 0.5, '808080', 'pt');

  -- =========================================================================
  -- Simple data table drawn manually with canvas calls
  -- =========================================================================
  DECLARE
    l_y NUMBER := 720;   -- y position of the first row (moves down each iteration)
  BEGIN
    -- Column headers
    rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 9);
    rad_pdf_canvas.write_text(l_doc, 'Column A',  50, l_y, 'pt');
    rad_pdf_canvas.write_text(l_doc, 'Column B', 200, l_y, 'pt');
    rad_pdf_canvas.write_text(l_doc, 'Column C', 380, l_y, 'pt');

    -- Data rows
    rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'N', 9);
    FOR i IN 1..5 LOOP
      l_y := l_y - 14;   -- move 14 pt down for each row
      rad_pdf_canvas.write_text(l_doc, 'Row ' || i || ' - A',       50, l_y, 'pt');
      rad_pdf_canvas.write_text(l_doc, TO_CHAR(i * 1000),           200, l_y, 'pt');
      rad_pdf_canvas.write_text(l_doc, TO_CHAR(ROUND(i*3.14159,2)), 380, l_y, 'pt');
    END LOOP;
  END;

  -- =========================================================================
  -- Polygon - a triangle with a light-blue fill
  -- Each vertex is an entry in the l_xs / l_ys index-by tables.
  -- =========================================================================
  l_xs(1) := 50;   l_ys(1) := 620;   -- bottom-left vertex
  l_xs(2) := 150;  l_ys(2) := 620;   -- bottom-right vertex
  l_xs(3) := 100;  l_ys(3) := 680;   -- top vertex

  -- polygon(doc, xs, ys, border_color, fill_color, line_width)
  rad_pdf_canvas.polygon(l_doc, l_xs, l_ys, '003366', 'CCE0FF', 1);

  -- Label below the shape
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'I', 8);
  rad_pdf_canvas.write_text(l_doc, 'polygon()', 70, 605, 'pt');

  -- =========================================================================
  -- Rectangle with border only (no fill)
  -- =========================================================================
  rad_pdf_canvas.rect(l_doc, 200, 620, 120, 60,
    p_line_color => '003366',
    p_fill_color => NULL,          -- NULL = transparent (no fill)
    p_line_width => 1.5,
    p_unit       => 'pt');
  rad_pdf_canvas.write_text(l_doc, 'rect() - no fill', 210, 605, 'pt');

  -- =========================================================================
  -- Finalise - the canvas-only path skips the layout engine entirely
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF generated - size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  -- :rad_pdf := l_pdf;
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
