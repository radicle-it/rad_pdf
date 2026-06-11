CREATE OR REPLACE PACKAGE rad_pdf_chart AUTHID DEFINER IS
/*
  rad_pdf_chart — native vector charts for RAD_PDF (v1.7.0).
  Oracle 19c+.  AUTHID DEFINER.  Phase 13 of the modular install.

  Stateless: holds no per-document state and requires no close_doc hook
  (same model as rad_pdf_template and rad_pdf_barcode).

  Depends on: rad_pdf_types, rad_pdf_units, rad_pdf_ctx, rad_pdf_canvas,
  rad_pdf_codec.

  All charts are PURE VECTOR: axes, gridlines, bars, lines and pie slices
  (cubic-Bézier arcs) are drawn with rad_pdf_canvas primitives — no images.
  Single data series per chart.  The current document font is saved and
  restored around label drawing.

  Colours: pass p_colors to control them, or leave the default for the
  built-in 10-colour palette (colours cycle when there are more data
  points than colours).
*/

-- ---------------------------------------------------------------------------
-- Empty-collection defaults (index-by tables cannot have literal defaults)
-- ---------------------------------------------------------------------------
  FUNCTION no_labels RETURN rad_pdf_types.t_text_list;
  FUNCTION no_colors RETURN rad_pdf_types.t_rgb_list;

-- ---------------------------------------------------------------------------
-- Bar chart (vertical bars).
--
-- The chart fills the p_width × p_height box with lower-left corner at
-- (p_x, p_y): title strip (when p_title is set), y-axis scale labels,
-- gridlines, bars, optional value labels above the bars and category
-- labels below them.
--
-- p_values: dense 1..n table, every value >= 0 (c_err_validation otherwise).
-- p_labels: optional category labels, same 1..n indexes.
-- p_colors: bar colours; default palette cycles.
-- p_show_values: print each value above its bar (default TRUE).
-- ---------------------------------------------------------------------------
  PROCEDURE bar_chart(
    p_doc         IN rad_pdf_types.t_doc_handle,
    p_values      IN rad_pdf_types.t_number_list,
    p_x           IN NUMBER,
    p_y           IN NUMBER,
    p_width       IN NUMBER,
    p_height      IN NUMBER,
    p_labels      IN rad_pdf_types.t_text_list DEFAULT no_labels(),
    p_colors      IN rad_pdf_types.t_rgb_list  DEFAULT no_colors(),
    p_show_values IN BOOLEAN                   DEFAULT TRUE,
    p_title       IN VARCHAR2                  DEFAULT NULL,
    p_unit        IN rad_pdf_types.t_unit      DEFAULT 'pt');

-- ---------------------------------------------------------------------------
-- Line chart (single series, points joined by straight segments).
--
-- Same box/axis layout as bar_chart.  Negative values are supported: the
-- y scale spans nice bounds around [min, max] (zero is included when all
-- values are >= 0).  p_colors(1) sets the line colour (default palette
-- colour 1); markers are small filled squares (suppress with
-- p_show_markers => FALSE).
-- ---------------------------------------------------------------------------
  PROCEDURE line_chart(
    p_doc          IN rad_pdf_types.t_doc_handle,
    p_values       IN rad_pdf_types.t_number_list,
    p_x            IN NUMBER,
    p_y            IN NUMBER,
    p_width        IN NUMBER,
    p_height       IN NUMBER,
    p_labels       IN rad_pdf_types.t_text_list DEFAULT no_labels(),
    p_colors       IN rad_pdf_types.t_rgb_list  DEFAULT no_colors(),
    p_show_markers IN BOOLEAN                   DEFAULT TRUE,
    p_title        IN VARCHAR2                  DEFAULT NULL,
    p_unit         IN rad_pdf_types.t_unit      DEFAULT 'pt');

-- ---------------------------------------------------------------------------
-- Pie chart.
--
-- Slices start at 12 o'clock and proceed clockwise, drawn as filled
-- cubic-Bézier arc paths with a thin white separator stroke.
-- p_values: every value >= 0, total > 0 (c_err_validation otherwise).
-- p_legend: colour swatch + label + percentage at the right of the pie
-- (shown when labels are supplied; percentages always included).
-- (p_cx, p_cy) is the CENTRE of the pie; p_radius its radius.
-- ---------------------------------------------------------------------------
  PROCEDURE pie_chart(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_values  IN rad_pdf_types.t_number_list,
    p_cx      IN NUMBER,
    p_cy      IN NUMBER,
    p_radius  IN NUMBER,
    p_labels  IN rad_pdf_types.t_text_list DEFAULT no_labels(),
    p_colors  IN rad_pdf_types.t_rgb_list  DEFAULT no_colors(),
    p_legend  IN BOOLEAN                   DEFAULT TRUE,
    p_title   IN VARCHAR2                  DEFAULT NULL,
    p_unit    IN rad_pdf_types.t_unit      DEFAULT 'pt');

END rad_pdf_chart;
/
