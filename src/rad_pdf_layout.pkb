CREATE OR REPLACE PACKAGE BODY rad_pdf_layout IS
/*
  rad_pdf_layout body — Phase 7 of the RAD_PDF modular refactoring.

  Coordinate system: PDF origin = lower-left, y increases upward.
  Frame: x = left margin, y = upper edge of content area (pt from bottom),
         width / height in pt.
*/

  TYPE t_table_def_map IS TABLE OF rad_pdf_types.t_table_def INDEX BY PLS_INTEGER;

  TYPE t_layout_state IS RECORD (
    flowables     rad_pdf_types.t_flowable_list,
    table_defs    t_table_def_map,
    template      rad_pdf_types.t_page_template,
    total_pages   PLS_INTEGER := 0,
    next_table_id PLS_INTEGER := 1
  );
  TYPE t_layout_map IS TABLE OF t_layout_state INDEX BY PLS_INTEGER;
  g_layout t_layout_map;

-- ---------------------------------------------------------------------------
  PROCEDURE ensure_state(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_s t_layout_state;
  BEGIN
    IF NOT g_layout.EXISTS(p_doc) THEN
      g_layout(p_doc) := l_s;
    END IF;
  END ensure_state;

-- ---------------------------------------------------------------------------
-- Return the content frame for p_doc based on template overrides + canvas state.
-- Frame.y is the UPPER edge of the content area (PDF coords, pt from bottom).
-- ---------------------------------------------------------------------------
  FUNCTION get_content_frame(p_doc IN rad_pdf_types.t_doc_handle) RETURN rad_pdf_types.t_frame IS
    l_f    rad_pdf_types.t_frame;
    l_tmpl rad_pdf_types.t_page_template;
    l_pf   rad_pdf_types.t_page_format;
    l_pw   NUMBER;
    l_ph   NUMBER;
    l_mt   NUMBER;
    l_mb   NUMBER;
    l_ml   NUMBER;
    l_mr   NUMBER;
  BEGIN
    l_tmpl := g_layout(p_doc).template;
    l_pw   := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_page_width);
    l_ph   := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_page_height);
    IF l_tmpl.page_format_name IS NOT NULL THEN
      l_pf := rad_pdf_units.page_format(l_tmpl.page_format_name);
      l_pw := l_pf.width;
      l_ph := l_pf.height;
    END IF;
    IF l_tmpl.page_width  IS NOT NULL THEN l_pw := l_tmpl.page_width;  END IF;
    IF l_tmpl.page_height IS NOT NULL THEN l_ph := l_tmpl.page_height; END IF;
    l_mt := NVL(l_tmpl.margin_top,    rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_top));
    l_mb := NVL(l_tmpl.margin_bottom, rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_bot));
    l_ml := NVL(l_tmpl.margin_left,   rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_left));
    l_mr := NVL(l_tmpl.margin_right,  rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_right));
    l_f.x      := l_ml;
    l_f.y      := l_ph - l_mt;
    l_f.width  := l_pw - l_ml - l_mr;
    l_f.height := l_ph - l_mt - l_mb;
    RETURN l_f;
  END get_content_frame;

-- ---------------------------------------------------------------------------
-- Apply template geometry (page format + margins) to the current page.
-- ---------------------------------------------------------------------------
  PROCEDURE apply_template_to_page(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_tmpl rad_pdf_types.t_page_template;
    l_pf   rad_pdf_types.t_page_format;
    l_mar  rad_pdf_types.t_margins;
  BEGIN
    l_tmpl := g_layout(p_doc).template;
    IF l_tmpl.page_format_name IS NOT NULL THEN
      rad_pdf_canvas.set_page_format(p_doc, rad_pdf_units.page_format(l_tmpl.page_format_name));
    ELSIF l_tmpl.page_width IS NOT NULL OR l_tmpl.page_height IS NOT NULL THEN
      l_pf.width  := NVL(l_tmpl.page_width,
                         rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_page_width));
      l_pf.height := NVL(l_tmpl.page_height,
                         rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_page_height));
      rad_pdf_canvas.set_page_format(p_doc, l_pf);
    END IF;
    IF l_tmpl.margin_top    IS NOT NULL OR l_tmpl.margin_bottom IS NOT NULL OR
       l_tmpl.margin_left   IS NOT NULL OR l_tmpl.margin_right  IS NOT NULL THEN
      l_mar.top    := NVL(l_tmpl.margin_top,
                          rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_top));
      l_mar.bottom := NVL(l_tmpl.margin_bottom,
                          rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_bot));
      l_mar.left   := NVL(l_tmpl.margin_left,
                          rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_left));
      l_mar.right  := NVL(l_tmpl.margin_right,
                          rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_right));
      rad_pdf_canvas.set_margins(p_doc, l_mar);
    END IF;
  END apply_template_to_page;

-- ---------------------------------------------------------------------------
-- Measure a single flowable (dry-run, no PDF output).
-- Sets the current canvas font to match the flowable style (side effect).
-- Returns height in pt.
-- ---------------------------------------------------------------------------
  FUNCTION measure_flowable(p_doc   IN rad_pdf_types.t_doc_handle,
                            p_flow  IN rad_pdf_types.t_flowable,
                            p_frame IN rad_pdf_types.t_frame) RETURN NUMBER IS
    l_style  rad_pdf_types.t_cell_format;
    l_text   VARCHAR2(32767);
  BEGIN
    CASE p_flow.flow_type
      WHEN rad_pdf_types.c_flow_paragraph THEN
        l_style := rad_pdf_styles.get(NVL(p_flow.style_name, 'body'));
        rad_pdf_canvas.set_font(p_doc, l_style.font_name, l_style.font_style, l_style.font_size);
        l_text := DBMS_LOB.SUBSTR(p_flow.text, 32767, 1);
        RETURN rad_pdf_canvas.measure_wrapped(p_doc, l_text, p_frame.width);
      WHEN rad_pdf_types.c_flow_heading THEN
        l_style := rad_pdf_styles.get('h' || TO_CHAR(NVL(p_flow.level, 1)));
        rad_pdf_canvas.set_font(p_doc, l_style.font_name, l_style.font_style, l_style.font_size);
        l_text := DBMS_LOB.SUBSTR(p_flow.text, 32767, 1);
        RETURN rad_pdf_canvas.measure_wrapped(p_doc, l_text, p_frame.width);
      WHEN rad_pdf_types.c_flow_spacer THEN
        RETURN NVL(p_flow.spacer_h, 0);
      WHEN rad_pdf_types.c_flow_hline THEN
        RETURN 2;
      WHEN rad_pdf_types.c_flow_image THEN
        DECLARE
          l_img_w NUMBER;
          l_img_h NUMBER;
        BEGIN
          IF p_flow.img_width IS NOT NULL AND p_flow.img_height IS NOT NULL THEN
            l_img_w := LEAST(p_flow.img_width, p_frame.width);
            l_img_h := p_flow.img_height * l_img_w / p_flow.img_width;
          ELSIF p_flow.img_height IS NOT NULL THEN
            l_img_h := p_flow.img_height;
          ELSE
            l_img_h := p_frame.height;
          END IF;
          RETURN LEAST(l_img_h, p_frame.height);
        END;
      WHEN rad_pdf_types.c_flow_table THEN
        IF g_layout(p_doc).table_defs.EXISTS(p_flow.table_ref_id) AND
           NOT g_layout(p_doc).table_defs(p_flow.table_ref_id).streaming THEN
          RETURN rad_pdf_table.measure_table(p_doc, p_flow.table_ref_id, p_frame.width);
        END IF;
        RETURN 0;
      ELSE
        RETURN 0;
    END CASE;
  END measure_flowable;

-- ---------------------------------------------------------------------------
-- Render a single flowable onto the current page at the given y position.
-- ---------------------------------------------------------------------------
  PROCEDURE render_flowable(p_doc   IN rad_pdf_types.t_doc_handle,
                            p_flow  IN rad_pdf_types.t_flowable,
                            p_frame IN rad_pdf_types.t_frame,
                            p_y     IN NUMBER) IS
    l_style  rad_pdf_types.t_cell_format;
    l_text   VARCHAR2(32767);
    l_lw     NUMBER;
    l_lc     rad_pdf_types.t_rgb;
  BEGIN
    CASE p_flow.flow_type
      WHEN rad_pdf_types.c_flow_paragraph THEN
        l_style := rad_pdf_styles.get(NVL(p_flow.style_name, 'body'));
        rad_pdf_canvas.set_font(p_doc, l_style.font_name, l_style.font_style, l_style.font_size);
        rad_pdf_canvas.set_color(p_doc, NVL(l_style.font_color, '000000'));
        l_text := DBMS_LOB.SUBSTR(p_flow.text, 32767, 1);
        rad_pdf_canvas.write_wrapped(p_doc, l_text, p_frame.x, p_y, p_frame.width,
                                 NVL(l_style.align_h, 'L'), 'pt');
      WHEN rad_pdf_types.c_flow_heading THEN
        l_style := rad_pdf_styles.get('h' || TO_CHAR(NVL(p_flow.level, 1)));
        rad_pdf_canvas.set_font(p_doc, l_style.font_name, l_style.font_style, l_style.font_size);
        rad_pdf_canvas.set_color(p_doc, NVL(l_style.font_color, '000000'));
        l_text := DBMS_LOB.SUBSTR(p_flow.text, 32767, 1);
        rad_pdf_canvas.write_wrapped(p_doc, l_text, p_frame.x, p_y, p_frame.width,
                                 NVL(l_style.align_h, 'L'), 'pt');
      WHEN rad_pdf_types.c_flow_spacer THEN
        NULL;
      WHEN rad_pdf_types.c_flow_hline THEN
        l_lc := NVL(p_flow.style_name, '000000');
        l_lw := NVL(p_flow.img_width, 0.5);
        rad_pdf_canvas.h_line(p_doc, p_frame.x, p_y - 1, p_frame.width, l_lw, l_lc, 'pt');
      WHEN rad_pdf_types.c_flow_image THEN
        rad_pdf_canvas.put_image(p_doc, p_flow.image_id,
                             p_frame.x, p_y,
                             LEAST(NVL(p_flow.img_width, p_frame.width), p_frame.width),
                             p_flow.measured_h,
                             'L', 'T', 'pt');
      WHEN rad_pdf_types.c_flow_table THEN
        rad_pdf_table.draw_table(p_doc, p_flow.table_ref_id,
                             p_frame.x, p_y, p_frame.width);
      ELSE NULL;
    END CASE;
  END render_flowable;

-- ---------------------------------------------------------------------------
-- Public: set_template
-- ---------------------------------------------------------------------------
  PROCEDURE set_template(p_doc      IN rad_pdf_types.t_doc_handle,
                         p_template IN rad_pdf_types.t_page_template) IS
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    g_layout(p_doc).template := p_template;
  END set_template;

-- ---------------------------------------------------------------------------
  PROCEDURE add(p_doc  IN rad_pdf_types.t_doc_handle,
                p_flow IN rad_pdf_types.t_flowable) IS
    l_idx PLS_INTEGER;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    IF g_layout(p_doc).flowables.COUNT = 0 THEN
      l_idx := 1;
    ELSE
      l_idx := g_layout(p_doc).flowables.LAST + 1;
    END IF;
    g_layout(p_doc).flowables(l_idx) := p_flow;
  END add;

-- ---------------------------------------------------------------------------
-- Flowable constructors
-- ---------------------------------------------------------------------------
  FUNCTION paragraph(p_text IN VARCHAR2, p_style IN VARCHAR2 DEFAULT 'body')
    RETURN rad_pdf_types.t_flowable IS
    l_f   rad_pdf_types.t_flowable;
    l_len PLS_INTEGER;
  BEGIN
    l_f.flow_type  := rad_pdf_types.c_flow_paragraph;
    l_f.style_name := NVL(p_style, 'body');
    DBMS_LOB.CREATETEMPORARY(l_f.text, TRUE);
    l_len := NVL(LENGTH(p_text), 0);
    IF l_len > 0 THEN
      DBMS_LOB.WRITEAPPEND(l_f.text, l_len, p_text);
    END IF;
    RETURN l_f;
  END paragraph;

-- ---------------------------------------------------------------------------
  FUNCTION paragraph(p_text IN CLOB, p_style IN VARCHAR2 DEFAULT 'body')
    RETURN rad_pdf_types.t_flowable IS
    l_f   rad_pdf_types.t_flowable;
    l_len NUMBER;
  BEGIN
    l_f.flow_type  := rad_pdf_types.c_flow_paragraph;
    l_f.style_name := NVL(p_style, 'body');
    DBMS_LOB.CREATETEMPORARY(l_f.text, TRUE);
    l_len := DBMS_LOB.GETLENGTH(p_text);
    IF l_len > 0 THEN
      DBMS_LOB.COPY(l_f.text, p_text, l_len);
    END IF;
    RETURN l_f;
  END paragraph;

-- ---------------------------------------------------------------------------
  FUNCTION heading(p_text IN VARCHAR2, p_level IN PLS_INTEGER DEFAULT 1)
    RETURN rad_pdf_types.t_flowable IS
    l_f   rad_pdf_types.t_flowable;
    l_len PLS_INTEGER;
  BEGIN
    l_f.flow_type := rad_pdf_types.c_flow_heading;
    l_f.level     := NVL(p_level, 1);
    DBMS_LOB.CREATETEMPORARY(l_f.text, TRUE);
    l_len := NVL(LENGTH(p_text), 0);
    IF l_len > 0 THEN
      DBMS_LOB.WRITEAPPEND(l_f.text, l_len, p_text);
    END IF;
    RETURN l_f;
  END heading;

-- ---------------------------------------------------------------------------
  FUNCTION image(p_image_id IN PLS_INTEGER,
                 p_width    IN NUMBER DEFAULT NULL,
                 p_height   IN NUMBER DEFAULT NULL)
    RETURN rad_pdf_types.t_flowable IS
    l_f rad_pdf_types.t_flowable;
  BEGIN
    l_f.flow_type  := rad_pdf_types.c_flow_image;
    l_f.image_id   := p_image_id;
    l_f.img_width  := p_width;
    l_f.img_height := p_height;
    RETURN l_f;
  END image;

-- ---------------------------------------------------------------------------
  FUNCTION spacer(p_height IN NUMBER) RETURN rad_pdf_types.t_flowable IS
    l_f rad_pdf_types.t_flowable;
  BEGIN
    l_f.flow_type := rad_pdf_types.c_flow_spacer;
    l_f.spacer_h  := NVL(p_height, 0);
    RETURN l_f;
  END spacer;

-- ---------------------------------------------------------------------------
-- h_rule: color stored in style_name, line thickness stored in img_width.
-- ---------------------------------------------------------------------------
  FUNCTION h_rule(p_color IN rad_pdf_types.t_rgb DEFAULT '000000',
                  p_width IN NUMBER           DEFAULT 0.5)
    RETURN rad_pdf_types.t_flowable IS
    l_f rad_pdf_types.t_flowable;
  BEGIN
    l_f.flow_type  := rad_pdf_types.c_flow_hline;
    l_f.style_name := NVL(p_color, '000000');
    l_f.img_width  := NVL(p_width, 0.5);
    RETURN l_f;
  END h_rule;

-- ---------------------------------------------------------------------------
  FUNCTION page_break RETURN rad_pdf_types.t_flowable IS
    l_f rad_pdf_types.t_flowable;
  BEGIN
    l_f.flow_type := rad_pdf_types.c_flow_pagebreak;
    RETURN l_f;
  END page_break;

-- ---------------------------------------------------------------------------
  FUNCTION register_table(p_doc       IN rad_pdf_types.t_doc_handle,
                          p_table_def IN rad_pdf_types.t_table_def) RETURN PLS_INTEGER IS
    l_id PLS_INTEGER;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    l_id := g_layout(p_doc).next_table_id;
    g_layout(p_doc).table_defs(l_id)  := p_table_def;
    g_layout(p_doc).next_table_id     := l_id + 1;
    RETURN l_id;
  END register_table;

-- ---------------------------------------------------------------------------
  FUNCTION get_table_def(p_doc       IN rad_pdf_types.t_doc_handle,
                         p_table_ref IN PLS_INTEGER) RETURN rad_pdf_types.t_table_def IS
    l_empty rad_pdf_types.t_table_def;
  BEGIN
    IF g_layout.EXISTS(p_doc) AND g_layout(p_doc).table_defs.EXISTS(p_table_ref) THEN
      RETURN g_layout(p_doc).table_defs(p_table_ref);
    END IF;
    RETURN l_empty;
  END get_table_def;

-- ---------------------------------------------------------------------------
  FUNCTION has_flowables(p_doc IN rad_pdf_types.t_doc_handle) RETURN BOOLEAN IS
  BEGIN
    IF NOT g_layout.EXISTS(p_doc) THEN RETURN FALSE; END IF;
    RETURN g_layout(p_doc).flowables.COUNT > 0;
  END has_flowables;

-- ---------------------------------------------------------------------------
-- render: measure pass → render pass → run_page_procs
-- ---------------------------------------------------------------------------
  PROCEDURE render(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_frame     rad_pdf_types.t_frame;
    l_remaining NUMBER;
    l_page_nr   PLS_INTEGER := 1;
    l_idx       PLS_INTEGER;
    l_h         NUMBER;
    l_current_y NUMBER;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);

    -- Apply template geometry to the first (existing) page.
    apply_template_to_page(p_doc);

    -- Register header/footer procs so run_page_procs picks them up.
    IF g_layout(p_doc).template.header_proc IS NOT NULL THEN
      rad_pdf_canvas.add_page_proc(p_doc, g_layout(p_doc).template.header_proc);
    END IF;
    IF g_layout(p_doc).template.footer_proc IS NOT NULL THEN
      rad_pdf_canvas.add_page_proc(p_doc, g_layout(p_doc).template.footer_proc);
    END IF;

    -- MEASURE PASS
    l_frame     := get_content_frame(p_doc);
    l_remaining := l_frame.height;

    l_idx := g_layout(p_doc).flowables.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      IF g_layout(p_doc).flowables(l_idx).flow_type = rad_pdf_types.c_flow_pagebreak THEN
        g_layout(p_doc).flowables(l_idx).page_break_before := TRUE;
        l_remaining := l_frame.height;
        l_page_nr   := l_page_nr + 1;
      ELSE
        l_h := measure_flowable(p_doc, g_layout(p_doc).flowables(l_idx), l_frame);
        IF l_h > l_remaining AND l_remaining < l_frame.height THEN
          g_layout(p_doc).flowables(l_idx).page_break_before := TRUE;
          l_remaining := l_frame.height;
          l_page_nr   := l_page_nr + 1;
        END IF;
        g_layout(p_doc).flowables(l_idx).measured_h := l_h;
        l_remaining := GREATEST(l_remaining - l_h, 0);
      END IF;
      l_idx := g_layout(p_doc).flowables.NEXT(l_idx);
    END LOOP;
    g_layout(p_doc).total_pages := l_page_nr;

    -- RENDER PASS
    apply_template_to_page(p_doc);
    l_frame     := get_content_frame(p_doc);
    l_current_y := l_frame.y;

    l_idx := g_layout(p_doc).flowables.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      IF g_layout(p_doc).flowables(l_idx).page_break_before THEN
        rad_pdf_canvas.new_page(p_doc);
        apply_template_to_page(p_doc);
        l_frame     := get_content_frame(p_doc);
        l_current_y := l_frame.y;
      END IF;

      IF g_layout(p_doc).flowables(l_idx).flow_type != rad_pdf_types.c_flow_pagebreak THEN
        render_flowable(p_doc, g_layout(p_doc).flowables(l_idx), l_frame, l_current_y);
        l_current_y := l_current_y - g_layout(p_doc).flowables(l_idx).measured_h;
      END IF;

      l_idx := g_layout(p_doc).flowables.NEXT(l_idx);
    END LOOP;

    -- POST-RENDER
    rad_pdf_canvas.run_page_procs(p_doc, g_layout(p_doc).total_pages);
  END render;

-- ---------------------------------------------------------------------------
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_idx  PLS_INTEGER;
    l_tidx PLS_INTEGER;
  BEGIN
    IF NOT g_layout.EXISTS(p_doc) THEN RETURN; END IF;
    l_idx := g_layout(p_doc).flowables.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      IF g_layout(p_doc).flowables(l_idx).text IS NOT NULL THEN
        DBMS_LOB.FREETEMPORARY(g_layout(p_doc).flowables(l_idx).text);
      END IF;
      l_idx := g_layout(p_doc).flowables.NEXT(l_idx);
    END LOOP;
    l_tidx := g_layout(p_doc).table_defs.FIRST;
    WHILE l_tidx IS NOT NULL LOOP
      IF g_layout(p_doc).table_defs(l_tidx).query_clob IS NOT NULL THEN
        DBMS_LOB.FREETEMPORARY(g_layout(p_doc).table_defs(l_tidx).query_clob);
      END IF;
      l_tidx := g_layout(p_doc).table_defs.NEXT(l_tidx);
    END LOOP;
    g_layout.DELETE(p_doc);
  END close_doc;

END rad_pdf_layout;
/
