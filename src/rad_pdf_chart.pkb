CREATE OR REPLACE PACKAGE BODY rad_pdf_chart IS
/*
  rad_pdf_chart body — Phase 13: native vector charts (v1.7.0).

  Layout model (bar/line): the given box is divided into an optional title
  strip (top), a y-label gutter (left), the plot area, and an optional
  category-label strip (bottom).  The y scale uses "nice numbers"
  (1/2/5 × 10^k steps) so gridline labels are round values.

  Pie slices are filled paths made of straight edges plus cubic-Bézier arc
  segments (max 90° per segment, standard k = 4/3·tan(Δ/4) control-point
  construction).
*/

  c_pi CONSTANT NUMBER := ACOS(-1);

  -- Tableau-10 palette
  TYPE t_pal IS VARRAY(10) OF VARCHAR2(6);
  c_palette CONSTANT t_pal := t_pal('4E79A7','F28E2B','E15759','76B7B5',
                                    '59A14F','EDC948','B07AA1','FF9DA7',
                                    '9C755F','BAB0AC');

-- ---------------------------------------------------------------------------
-- Empty-collection defaults
-- ---------------------------------------------------------------------------
  FUNCTION no_labels RETURN rad_pdf_types.t_text_list IS
    l rad_pdf_types.t_text_list;
  BEGIN
    RETURN l;
  END no_labels;

  FUNCTION no_colors RETURN rad_pdf_types.t_rgb_list IS
    l rad_pdf_types.t_rgb_list;
  BEGIN
    RETURN l;
  END no_colors;

-- ---------------------------------------------------------------------------
-- PRIVATE helpers
-- ---------------------------------------------------------------------------
  FUNCTION pick_color(p_colors IN rad_pdf_types.t_rgb_list,
                      p_i      IN PLS_INTEGER) RETURN rad_pdf_types.t_rgb IS
  BEGIN
    IF p_colors.COUNT > 0 THEN
      RETURN p_colors(MOD(p_i - 1, p_colors.COUNT) + 1);
    END IF;
    RETURN c_palette(MOD(p_i - 1, c_palette.COUNT) + 1);
  END pick_color;

  -- Dense 1..n check; returns n.
  FUNCTION check_values(p_values IN rad_pdf_types.t_number_list,
                        p_caller IN VARCHAR2,
                        p_min_ok IN NUMBER DEFAULT NULL)  -- NULL = any value
    RETURN PLS_INTEGER IS
    l_n PLS_INTEGER := p_values.COUNT;
  BEGIN
    IF l_n = 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        p_caller || ': p_values must not be empty', TRUE);
    END IF;
    FOR i IN 1 .. l_n LOOP
      IF NOT p_values.EXISTS(i) OR p_values(i) IS NULL THEN
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
          p_caller || ': p_values must be dense 1..' || l_n
          || ' with non-NULL values', TRUE);
      END IF;
      IF p_min_ok IS NOT NULL AND p_values(i) < p_min_ok THEN
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
          p_caller || ': value at index ' || i || ' is negative', TRUE);
      END IF;
    END LOOP;
    RETURN l_n;
  END check_values;

  -- "Nice numbers" y scale: lo/hi snapped to a 1/2/5×10^k step, ~4 steps.
  PROCEDURE nice_scale(p_min IN NUMBER, p_max IN NUMBER,
                       o_lo OUT NUMBER, o_hi OUT NUMBER, o_step OUT NUMBER) IS
    l_min   NUMBER := p_min;
    l_max   NUMBER := p_max;
    l_raw   NUMBER;
    l_mag   NUMBER;
    l_norm  NUMBER;
  BEGIN
    IF l_max = l_min THEN
      l_max := l_min + 1;
    END IF;
    l_raw  := (l_max - l_min) / 4;
    l_mag  := POWER(10, FLOOR(LOG(10, l_raw)));
    l_norm := l_raw / l_mag;
    o_step := l_mag * CASE
                        WHEN l_norm <= 1 THEN 1
                        WHEN l_norm <= 2 THEN 2
                        WHEN l_norm <= 5 THEN 5
                        ELSE 10
                      END;
    o_lo := FLOOR(l_min / o_step) * o_step;
    o_hi := CEIL (l_max / o_step) * o_step;
    IF o_hi = o_lo THEN
      o_hi := o_lo + o_step;
    END IF;
  END nice_scale;

  PROCEDURE save_font(p_doc IN rad_pdf_types.t_doc_handle,
                      o_idx OUT PLS_INTEGER, o_size OUT NUMBER) IS
  BEGIN
    o_idx  := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_font_idx);
    o_size := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_font_size);
  END save_font;

  PROCEDURE restore_font(p_doc IN rad_pdf_types.t_doc_handle,
                         p_idx IN PLS_INTEGER, p_size IN NUMBER) IS
  BEGIN
    rad_pdf_canvas.set_color(p_doc, '000000');
    IF p_idx IS NOT NULL THEN
      rad_pdf_canvas.set_font(p_doc, p_idx, p_size);
    END IF;
  END restore_font;

  -- Truncate p_txt until it fits p_max_w at the current font.
  FUNCTION fit_text(p_doc IN rad_pdf_types.t_doc_handle,
                    p_txt IN VARCHAR2, p_max_w IN NUMBER) RETURN VARCHAR2 IS
    l_txt VARCHAR2(200) := p_txt;
  BEGIN
    WHILE LENGTH(l_txt) > 1
          AND rad_pdf_canvas.text_width(p_doc, l_txt) > p_max_w LOOP
      l_txt := SUBSTR(l_txt, 1, LENGTH(l_txt) - 1);
    END LOOP;
    RETURN l_txt;
  END fit_text;

  PROCEDURE centered_text(p_doc IN rad_pdf_types.t_doc_handle,
                          p_txt IN VARCHAR2,
                          p_cx IN NUMBER, p_y IN NUMBER) IS
    l_tw NUMBER := rad_pdf_canvas.text_width(p_doc, p_txt);
  BEGIN
    rad_pdf_canvas.write_text(p_doc, p_txt, p_cx - l_tw / 2, p_y, 'pt');
  END centered_text;

  -- Shared axis frame for bar/line.  Computes the plot rectangle inside the
  -- chart box, draws title, gridlines, y labels and the axes.
  -- Labels use the CURRENT document font (p_fidx) so charts stay
  -- PDF/A-compatible when an embedded font is active (Helvetica would
  -- violate the embedding requirement).  Title is drawn at size 9, labels
  -- at size 7, in the current face (no bold variant is forced).
  PROCEDURE draw_frame(p_doc    IN rad_pdf_types.t_doc_handle,
                       p_fidx   IN PLS_INTEGER,
                       p_x      IN NUMBER,  p_y IN NUMBER,
                       p_w      IN NUMBER,  p_h IN NUMBER,
                       p_title  IN VARCHAR2,
                       p_has_lbl IN BOOLEAN,
                       p_lo     IN NUMBER, p_hi IN NUMBER, p_step IN NUMBER,
                       o_px     OUT NUMBER, o_py OUT NUMBER,
                       o_pw     OUT NUMBER, o_ph OUT NUMBER) IS
    c_gutter  CONSTANT NUMBER := 34;   -- left, y-scale labels
    c_pad     CONSTANT NUMBER := 4;
    l_title_h NUMBER := CASE WHEN p_title IS NULL THEN 0 ELSE 14 END;
    l_lbl_h   NUMBER := CASE WHEN p_has_lbl THEN 12 ELSE 0 END;
    l_v       NUMBER;
    l_gy      NUMBER;
    l_lbl     VARCHAR2(40);
    l_zero_y  NUMBER;
  BEGIN
    o_px := p_x + c_gutter;
    o_py := p_y + l_lbl_h;
    o_pw := p_w - c_gutter - c_pad;
    o_ph := p_h - l_lbl_h - l_title_h - c_pad;
    IF o_pw < 20 OR o_ph < 20 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_chart: chart box too small for the plot area', TRUE);
    END IF;

    IF p_title IS NOT NULL THEN
      rad_pdf_canvas.set_font(p_doc, p_fidx, 9);
      rad_pdf_canvas.set_color(p_doc, '000000');
      centered_text(p_doc, p_title, o_px + o_pw / 2, p_y + p_h - 10);
    END IF;

    -- gridlines + y labels
    rad_pdf_canvas.set_font(p_doc, p_fidx, 7);
    rad_pdf_canvas.set_color(p_doc, '666666');
    l_v := p_lo;
    WHILE l_v <= p_hi + p_step / 1000 LOOP
      l_gy := o_py + (l_v - p_lo) / (p_hi - p_lo) * o_ph;
      rad_pdf_canvas.h_line(p_doc, o_px, l_gy, o_pw, 0.4, 'DDDDDD', 'pt');
      l_lbl := rad_pdf_codec.fmt(l_v, 2);
      rad_pdf_canvas.write_text(p_doc, l_lbl,
        o_px - 4 - rad_pdf_canvas.text_width(p_doc, l_lbl), l_gy - 2.5, 'pt');
      l_v := l_v + p_step;
    END LOOP;

    -- axes: y axis; x axis on the zero line when visible, else at the bottom
    -- (v_line draws DOWNWARD from p_y, so pass the top of the plot)
    rad_pdf_canvas.v_line(p_doc, o_px, o_py + o_ph, o_ph, 0.8, '000000', 'pt');
    IF p_lo < 0 AND p_hi > 0 THEN
      l_zero_y := o_py + (0 - p_lo) / (p_hi - p_lo) * o_ph;
    ELSE
      l_zero_y := o_py;
    END IF;
    rad_pdf_canvas.h_line(p_doc, o_px, l_zero_y, o_pw, 0.8, '000000', 'pt');
  END draw_frame;

-- ---------------------------------------------------------------------------
-- bar_chart
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
    p_unit        IN rad_pdf_types.t_unit      DEFAULT 'pt') IS
    l_n     PLS_INTEGER;
    l_x     NUMBER := rad_pdf_units.to_pt(p_x,      p_unit);
    l_y     NUMBER := rad_pdf_units.to_pt(p_y,      p_unit);
    l_w     NUMBER := rad_pdf_units.to_pt(p_width,  p_unit);
    l_h     NUMBER := rad_pdf_units.to_pt(p_height, p_unit);
    l_max   NUMBER := 0;
    l_lo    NUMBER; l_hi NUMBER; l_step NUMBER;
    l_px    NUMBER; l_py NUMBER; l_pw NUMBER; l_ph NUMBER;
    l_slot  NUMBER;
    l_bw    NUMBER;
    l_bx    NUMBER;
    l_bh    NUMBER;
    l_fidx  PLS_INTEGER; l_fsize NUMBER;
    l_txt   VARCHAR2(200);
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    l_n := check_values(p_values, 'rad_pdf_chart.bar_chart', p_min_ok => 0);
    FOR i IN 1 .. l_n LOOP
      l_max := GREATEST(l_max, p_values(i));
    END LOOP;
    nice_scale(0, l_max, l_lo, l_hi, l_step);

    save_font(p_doc, l_fidx, l_fsize);
    draw_frame(p_doc, l_fidx, l_x, l_y, l_w, l_h, p_title,
               p_labels.COUNT > 0, l_lo, l_hi, l_step,
               l_px, l_py, l_pw, l_ph);

    l_slot := l_pw / l_n;
    l_bw   := l_slot * 0.7;

    FOR i IN 1 .. l_n LOOP
      l_bx := l_px + (i - 1) * l_slot + l_slot * 0.15;
      l_bh := (p_values(i) - l_lo) / (l_hi - l_lo) * l_ph;
      IF l_bh > 0 THEN
        rad_pdf_canvas.rect(p_doc, l_bx, l_py, l_bw, l_bh,
                            p_line_color => NULL,
                            p_fill_color => pick_color(p_colors, i),
                            p_unit       => 'pt');
      END IF;
      IF NVL(p_show_values, FALSE) THEN
        rad_pdf_canvas.set_font(p_doc, l_fidx, 7);
        rad_pdf_canvas.set_color(p_doc, '333333');
        centered_text(p_doc, rad_pdf_codec.fmt(p_values(i), 2),
                      l_bx + l_bw / 2, LEAST(l_py + l_bh + 2, l_py + l_ph - 7));
      END IF;
      IF p_labels.EXISTS(i) AND p_labels(i) IS NOT NULL THEN
        rad_pdf_canvas.set_font(p_doc, l_fidx, 7);
        rad_pdf_canvas.set_color(p_doc, '000000');
        l_txt := fit_text(p_doc, p_labels(i), l_slot);
        centered_text(p_doc, l_txt, l_bx + l_bw / 2, l_y + 2);
      END IF;
    END LOOP;
    restore_font(p_doc, l_fidx, l_fsize);
  END bar_chart;

-- ---------------------------------------------------------------------------
-- line_chart
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
    p_unit         IN rad_pdf_types.t_unit      DEFAULT 'pt') IS
    l_n     PLS_INTEGER;
    l_x     NUMBER := rad_pdf_units.to_pt(p_x,      p_unit);
    l_y     NUMBER := rad_pdf_units.to_pt(p_y,      p_unit);
    l_w     NUMBER := rad_pdf_units.to_pt(p_width,  p_unit);
    l_h     NUMBER := rad_pdf_units.to_pt(p_height, p_unit);
    l_min   NUMBER;
    l_max   NUMBER;
    l_lo    NUMBER; l_hi NUMBER; l_step NUMBER;
    l_px    NUMBER; l_py NUMBER; l_pw NUMBER; l_ph NUMBER;
    l_slot  NUMBER;
    l_color rad_pdf_types.t_rgb;
    l_path  rad_pdf_types.t_path;
    l_e     rad_pdf_types.t_path_element;
    l_cx    NUMBER;
    l_cy    NUMBER;
    l_fidx  PLS_INTEGER; l_fsize NUMBER;
    l_txt   VARCHAR2(200);
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    l_n := check_values(p_values, 'rad_pdf_chart.line_chart');
    l_min := p_values(1);
    l_max := p_values(1);
    FOR i IN 2 .. l_n LOOP
      l_min := LEAST(l_min, p_values(i));
      l_max := GREATEST(l_max, p_values(i));
    END LOOP;
    IF l_min >= 0 THEN
      l_min := 0;  -- anchor the scale at zero for all-positive series
    END IF;
    nice_scale(l_min, l_max, l_lo, l_hi, l_step);

    save_font(p_doc, l_fidx, l_fsize);
    draw_frame(p_doc, l_fidx, l_x, l_y, l_w, l_h, p_title,
               p_labels.COUNT > 0, l_lo, l_hi, l_step,
               l_px, l_py, l_pw, l_ph);

    l_slot  := l_pw / l_n;
    l_color := pick_color(p_colors, 1);

    -- polyline
    FOR i IN 1 .. l_n LOOP
      l_cx := l_px + (i - 0.5) * l_slot;
      l_cy := l_py + (p_values(i) - l_lo) / (l_hi - l_lo) * l_ph;
      l_e.element_type := CASE WHEN i = 1 THEN rad_pdf_types.c_move_to
                               ELSE rad_pdf_types.c_line_to END;
      l_e.x1 := l_cx;
      l_e.y1 := l_cy;
      l_path(i - 1) := l_e;
    END LOOP;
    rad_pdf_canvas.path(p_doc, l_path,
                        p_line_color => l_color,
                        p_fill_color => NULL,
                        p_line_width => 1.2);

    -- markers + category labels
    FOR i IN 1 .. l_n LOOP
      l_cx := l_px + (i - 0.5) * l_slot;
      l_cy := l_py + (p_values(i) - l_lo) / (l_hi - l_lo) * l_ph;
      IF NVL(p_show_markers, FALSE) THEN
        rad_pdf_canvas.rect(p_doc, l_cx - 1.6, l_cy - 1.6, 3.2, 3.2,
                            p_line_color => NULL,
                            p_fill_color => l_color,
                            p_unit       => 'pt');
      END IF;
      IF p_labels.EXISTS(i) AND p_labels(i) IS NOT NULL THEN
        rad_pdf_canvas.set_font(p_doc, l_fidx, 7);
        rad_pdf_canvas.set_color(p_doc, '000000');
        l_txt := fit_text(p_doc, p_labels(i), l_slot);
        centered_text(p_doc, l_txt, l_cx, l_y + 2);
      END IF;
    END LOOP;
    restore_font(p_doc, l_fidx, l_fsize);
  END line_chart;

-- ---------------------------------------------------------------------------
-- pie_chart
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
    p_unit    IN rad_pdf_types.t_unit      DEFAULT 'pt') IS
    l_n     PLS_INTEGER;
    l_cx    NUMBER := rad_pdf_units.to_pt(p_cx,     p_unit);
    l_cy    NUMBER := rad_pdf_units.to_pt(p_cy,     p_unit);
    l_r     NUMBER := rad_pdf_units.to_pt(p_radius, p_unit);
    l_total NUMBER := 0;
    l_a     NUMBER;            -- current angle (radians)
    l_a2    NUMBER;
    l_fidx  PLS_INTEGER; l_fsize NUMBER;
    l_ly    NUMBER;

    -- Build one slice path: centre → arc start → arc (≤90° Bézier
    -- segments) → close.  Angles in radians, clockwise (decreasing).
    PROCEDURE draw_slice(p_from IN NUMBER, p_to IN NUMBER,
                         p_color IN rad_pdf_types.t_rgb) IS
      l_path rad_pdf_types.t_path;
      l_e    rad_pdf_types.t_path_element;
      l_i    PLS_INTEGER := 0;
      l_sa   NUMBER := p_from;
      l_ea   NUMBER;
      l_k    NUMBER;
      l_segs PLS_INTEGER := CEIL(ABS(p_to - p_from) / (c_pi / 2));

      PROCEDURE add(p_el rad_pdf_types.t_path_element) IS
      BEGIN
        l_path(l_i) := p_el;
        l_i := l_i + 1;
      END add;
    BEGIN
      l_e.element_type := rad_pdf_types.c_move_to;
      l_e.x1 := l_cx;  l_e.y1 := l_cy;
      add(l_e);
      l_e.element_type := rad_pdf_types.c_line_to;
      l_e.x1 := l_cx + l_r * COS(l_sa);
      l_e.y1 := l_cy + l_r * SIN(l_sa);
      add(l_e);
      FOR s IN 1 .. l_segs LOOP
        l_ea := p_from + (p_to - p_from) * s / l_segs;
        l_k  := 4 / 3 * TAN((l_ea - l_sa) / 4);
        l_e.element_type := rad_pdf_types.c_curve_to;
        l_e.x1 := l_cx + l_r * (COS(l_sa) - l_k * SIN(l_sa));
        l_e.y1 := l_cy + l_r * (SIN(l_sa) + l_k * COS(l_sa));
        l_e.x2 := l_cx + l_r * (COS(l_ea) + l_k * SIN(l_ea));
        l_e.y2 := l_cy + l_r * (SIN(l_ea) - l_k * COS(l_ea));
        l_e.x3 := l_cx + l_r * COS(l_ea);
        l_e.y3 := l_cy + l_r * SIN(l_ea);
        add(l_e);
        l_e.x2 := NULL; l_e.y2 := NULL; l_e.x3 := NULL; l_e.y3 := NULL;
        l_sa := l_ea;
      END LOOP;
      l_e.element_type := rad_pdf_types.c_close;
      l_e.x1 := NULL; l_e.y1 := NULL;
      add(l_e);
      rad_pdf_canvas.path(p_doc, l_path,
                          p_line_color => 'FFFFFF',
                          p_fill_color => p_color,
                          p_line_width => 0.7);
    END draw_slice;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    l_n := check_values(p_values, 'rad_pdf_chart.pie_chart', p_min_ok => 0);
    FOR i IN 1 .. l_n LOOP
      l_total := l_total + p_values(i);
    END LOOP;
    IF l_total <= 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_chart.pie_chart: total of p_values must be > 0', TRUE);
    END IF;
    IF l_r <= 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_chart.pie_chart: p_radius must be > 0', TRUE);
    END IF;

    save_font(p_doc, l_fidx, l_fsize);

    IF p_title IS NOT NULL THEN
      rad_pdf_canvas.set_font(p_doc, l_fidx, 9);
      rad_pdf_canvas.set_color(p_doc, '000000');
      centered_text(p_doc, p_title, l_cx, l_cy + l_r + 8);
    END IF;

    -- slices: start at 12 o'clock, clockwise
    l_a := c_pi / 2;
    FOR i IN 1 .. l_n LOOP
      IF p_values(i) > 0 THEN
        l_a2 := l_a - 2 * c_pi * p_values(i) / l_total;
        draw_slice(l_a, l_a2, pick_color(p_colors, i));
        l_a := l_a2;
      END IF;
    END LOOP;

    -- legend at the right of the pie
    IF NVL(p_legend, FALSE) AND p_labels.COUNT > 0 THEN
      rad_pdf_canvas.set_font(p_doc, l_fidx, 7);
      l_ly := l_cy + l_r - 7;
      FOR i IN 1 .. l_n LOOP
        rad_pdf_canvas.rect(p_doc, l_cx + l_r + 12, l_ly, 7, 7,
                            p_line_color => NULL,
                            p_fill_color => pick_color(p_colors, i),
                            p_unit       => 'pt');
        rad_pdf_canvas.set_color(p_doc, '000000');
        rad_pdf_canvas.write_text(p_doc,
          NVL(CASE WHEN p_labels.EXISTS(i) THEN p_labels(i) END, 'Series ' || i)
          || ' (' || rad_pdf_codec.fmt(p_values(i) / l_total * 100, 1) || '%)',
          l_cx + l_r + 22, l_ly + 1, 'pt');
        l_ly := l_ly - 11;
      END LOOP;
    END IF;
    restore_font(p_doc, l_fidx, l_fsize);
  END pie_chart;

END rad_pdf_chart;
/
