-- =============================================================================
-- sample20.sql  -  Native charts: bar, line and pie on a dashboard page
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A one-page "dashboard" with the three native chart types (v1.7.0),
--   all rendered as pure VECTOR graphics (axes, gridlines, bars, Bézier
--   pie slices) - no images, crisp at any zoom and print resolution:
--     1. Bar chart  - monthly revenue with value labels
--     2. Line chart - quarterly deltas (negative values supported)
--     3. Pie chart  - market share with legend and percentages
--
-- KEY TECHNIQUES
--   - rad_pdf.bar_chart / line_chart / pie_chart facade shortcuts
--   - rad_pdf_types.t_number_list (values) + t_text_list (labels):
--     dense 1..n collections
--   - "Nice numbers" y scale: gridline labels are always round values
--   - Default 10-colour palette; pass p_colors (t_rgb_list) to override -
--     colours cycle when there are more data points than colours
--   - Line charts support negative values: the zero axis is drawn inside
--     the plot
--   - The current document font is saved and restored around each chart
--
-- DATA
--   Self-contained; replace the literals with cursor loops over your data.
--
-- HOW TO RUN
--   Same as sample01.sql - see its header for output options.
--
-- PREREQUISITES
--   RAD_PDF v1.7.0+ installed (run src/install.sql).
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_v   rad_pdf_types.t_number_list;
  l_l   rad_pdf_types.t_text_list;
  l_c   rad_pdf_types.t_rgb_list;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 14);
  rad_pdf_canvas.write_text(l_doc, 'Dashboard vendite 2026', 20, 275, 'mm');

  -- ---------------------------------------------------------------------
  -- 1. Bar chart: monthly revenue
  -- ---------------------------------------------------------------------
  l_v(1) := 120; l_v(2) := 340; l_v(3) := 90; l_v(4) := 410; l_v(5) := 260;
  l_l(1) := 'Gen'; l_l(2) := 'Feb'; l_l(3) := 'Mar'; l_l(4) := 'Apr'; l_l(5) := 'Mag';
  rad_pdf.bar_chart(l_doc, l_v,
                    p_x => 15, p_y => 195, p_width => 85, p_height => 60,
                    p_labels => l_l,
                    p_title  => 'Fatturato mensile (k EUR)',
                    p_unit   => 'mm');

  -- ---------------------------------------------------------------------
  -- 2. Line chart: quarterly deltas (negatives supported)
  -- ---------------------------------------------------------------------
  l_v.DELETE; l_l.DELETE;
  l_v(1) := 15; l_v(2) := -8; l_v(3) := 22; l_v(4) := 5; l_v(5) := -3; l_v(6) := 30;
  FOR i IN 1 .. 6 LOOP l_l(i) := 'Q' || i; END LOOP;
  rad_pdf.line_chart(l_doc, l_v,
                     p_x => 110, p_y => 195, p_width => 85, p_height => 60,
                     p_labels => l_l,
                     p_title  => 'Delta trimestrale (%)',
                     p_unit   => 'mm');

  -- ---------------------------------------------------------------------
  -- 3. Pie chart: market share with custom corporate colours
  -- ---------------------------------------------------------------------
  l_v.DELETE; l_l.DELETE;
  l_v(1) := 45; l_v(2) := 25; l_v(3) := 18; l_v(4) := 12;
  l_l(1) := 'Nord'; l_l(2) := 'Centro'; l_l(3) := 'Sud'; l_l(4) := 'Estero';
  l_c(1) := '003366'; l_c(2) := '4E79A7'; l_c(3) := '8CB4D8'; l_c(4) := 'C5D9EC';
  rad_pdf.pie_chart(l_doc, l_v,
                    p_cx => 55, p_cy => 130, p_radius => 28,
                    p_labels => l_l,
                    p_colors => l_c,
                    p_title  => 'Quota mercato',
                    p_unit   => 'mm');

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('PDF generated: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');

  -- Option B - save to an Oracle Directory:
  -- rad_pdf.save(l_pdf, 'PDF_OUT', 'sample20_charts.pdf');

  -- Option C - SQL Developer bind:
  -- :rad_pdf := l_pdf;

  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
