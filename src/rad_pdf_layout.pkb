CREATE OR REPLACE PACKAGE BODY rad_pdf_layout IS
/*
  rad_pdf_layout body — Phase 7 of the RAD_PDF modular refactoring.

  Coordinate system: PDF origin = lower-left, y increases upward.
  Frame: x = left margin, y = upper edge of content area (pt from bottom),
         width / height in pt.
*/

  TYPE t_table_def_map IS TABLE OF rad_pdf_types.t_table_def INDEX BY PLS_INTEGER;

  -- ---------------------------------------------------------------------------
  -- PARA_RUNS support: inline mixed-style paragraphs
  -- ---------------------------------------------------------------------------
  -- Registered run set per flowable (keyed by para_runs_ref_id).
  TYPE t_runs_entry IS RECORD (
    runs       rad_pdf_types.t_inline_run_list,
    base_style VARCHAR2(110) := 'body'
  );
  TYPE t_runs_registry IS TABLE OF t_runs_entry INDEX BY PLS_INTEGER;

  TYPE t_plan_map IS TABLE OF rad_pdf_text.t_plan INDEX BY PLS_INTEGER;
  TYPE t_layout_state IS RECORD (
    plans         t_plan_map,
    flowables     rad_pdf_types.t_flowable_list,
    table_defs    t_table_def_map,
    runs_defs     t_runs_registry,
    template      rad_pdf_types.t_page_template,
    total_pages   PLS_INTEGER := 0,
    next_table_id PLS_INTEGER := 1,
    next_runs_id  PLS_INTEGER := 1
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
-- Paint prepared lines in maximal page-sized batches. No tokenization, style
-- resolution or width calculations occur in the rendering pass.
-- ---------------------------------------------------------------------------
  PROCEDURE paint_plan(p_doc IN rad_pdf_types.t_doc_handle,
                       p_plan IN rad_pdf_text.t_plan,
                       p_frame IN rad_pdf_types.t_frame,p_y IN OUT NUMBER) IS
    l_first PLS_INTEGER := 1;
    l_last PLS_INTEGER;
    l_top NUMBER;
  BEGIN
    WHILE l_first<=p_plan.lines.COUNT LOOP
      IF p_plan.lines(l_first).height>p_frame.height THEN
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_layout,'Text line exceeds content frame height');
      END IF;
      IF p_y-p_plan.lines(l_first).height<p_frame.y-p_frame.height THEN
        rad_pdf_canvas.new_page(p_doc); apply_template_to_page(p_doc); p_y := p_frame.y;
      END IF;
      l_top := p_y;
      l_last := l_first;
      WHILE l_last<=p_plan.lines.COUNT
            AND p_y-p_plan.lines(l_last).height>=p_frame.y-p_frame.height LOOP
        p_y := p_y-p_plan.lines(l_last).height;
        l_last := l_last+1;
      END LOOP;
      rad_pdf_canvas.paint_lines(p_doc,p_plan,p_frame.x,l_top,l_first,l_last-1);
      l_first := l_last;
    END LOOP;
  END paint_plan;

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
  FUNCTION heading(p_text     IN VARCHAR2,
                   p_level    IN PLS_INTEGER DEFAULT 1,
                   p_bookmark IN BOOLEAN     DEFAULT FALSE)
    RETURN rad_pdf_types.t_flowable IS
    l_f   rad_pdf_types.t_flowable;
    l_len PLS_INTEGER;
  BEGIN
    l_f.flow_type := rad_pdf_types.c_flow_heading;
    l_f.level     := NVL(p_level, 1);
    l_f.bookmark  := NVL(p_bookmark, FALSE);
    l_f.keep_with_next := TRUE;
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
  FUNCTION qrcode(p_value IN VARCHAR2,
                  p_size  IN NUMBER,
                  p_ec    IN VARCHAR2                DEFAULT 'M',
                  p_color IN rad_pdf_types.t_rgb     DEFAULT '000000',
                  p_align IN rad_pdf_types.t_align_h DEFAULT 'L')
    RETURN rad_pdf_types.t_flowable IS
    l_f   rad_pdf_types.t_flowable;
    l_len PLS_INTEGER := NVL(LENGTH(p_value), 0);
  BEGIN
    IF l_len = 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_layout.qrcode: p_value must not be NULL', TRUE);
    END IF;
    IF NVL(p_size, 0) <= 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_layout.qrcode: p_size must be > 0', TRUE);
    END IF;
    l_f.flow_type  := rad_pdf_types.c_flow_qrcode;
    l_f.img_width  := p_size;
    l_f.style_name := NVL(p_color, '000000');
    l_f.qr_ec      := NVL(UPPER(p_ec), 'M');
    l_f.qr_align   := CASE WHEN UPPER(p_align) IN ('L','C','R')
                           THEN UPPER(p_align) ELSE 'L' END;
    DBMS_LOB.CREATETEMPORARY(l_f.text, TRUE);
    DBMS_LOB.WRITEAPPEND(l_f.text, l_len, p_value);
    RETURN l_f;
  END qrcode;

-- ---------------------------------------------------------------------------
  FUNCTION paragraph_runs(
    p_doc   IN rad_pdf_types.t_doc_handle,
    p_runs  IN rad_pdf_types.t_inline_run_list,
    p_style IN VARCHAR2 DEFAULT 'body'
  ) RETURN rad_pdf_types.t_flowable IS
    l_f      rad_pdf_types.t_flowable;
    l_ref_id PLS_INTEGER;
    l_entry  t_runs_entry;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    l_ref_id           := g_layout(p_doc).next_runs_id;
    l_entry.runs       := p_runs;
    l_entry.base_style := NVL(p_style, 'body');
    g_layout(p_doc).runs_defs(l_ref_id) := l_entry;
    g_layout(p_doc).next_runs_id        := l_ref_id + 1;
    l_f.flow_type        := rad_pdf_types.c_flow_para_runs;
    l_f.para_runs_ref_id := l_ref_id;
    l_f.style_name       := NVL(p_style, 'body');
    RETURN l_f;
  END paragraph_runs;

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
-- render: prepare sources → draw with live cursor → actual page callbacks
-- ---------------------------------------------------------------------------
  PROCEDURE render(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_frame rad_pdf_types.t_frame;
    l_y NUMBER;
    l_idx PLS_INTEGER;
    l_h NUMBER;
    l_flow rad_pdf_types.t_flowable;
    l_next_idx PLS_INTEGER;
    l_sz NUMBER;
    l_x NUMBER;
    l_img_w NUMBER;
    l_img_h NUMBER;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    apply_template_to_page(p_doc);
    l_frame := get_content_frame(p_doc);
    IF l_frame.width <= 0 OR l_frame.height <= 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_layout, 'Margins leave no content frame');
    END IF;
    IF g_layout(p_doc).template.n_columns != 1 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_layout, 'Multiple columns are not supported');
    END IF;
    IF g_layout(p_doc).template.header_proc IS NOT NULL THEN
      rad_pdf_canvas.add_page_proc(p_doc,g_layout(p_doc).template.header_proc);
    END IF;
    IF g_layout(p_doc).template.footer_proc IS NOT NULL THEN
      rad_pdf_canvas.add_page_proc(p_doc,g_layout(p_doc).template.footer_proc);
    END IF;
    -- Prepare text once and fetch each table once, including refcursor tables.
    l_idx := g_layout(p_doc).flowables.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      l_flow := g_layout(p_doc).flowables(l_idx);
      CASE l_flow.flow_type
        WHEN rad_pdf_types.c_flow_paragraph THEN
          g_layout(p_doc).plans(l_idx) := rad_pdf_text.prepare(p_doc,l_flow.text,
            NVL(l_flow.style_name,'body'),l_frame.width);
        WHEN rad_pdf_types.c_flow_heading THEN
          g_layout(p_doc).plans(l_idx) := rad_pdf_text.prepare(p_doc,l_flow.text,
            'h'||TO_CHAR(NVL(l_flow.level,1)),l_frame.width);
        WHEN rad_pdf_types.c_flow_para_runs THEN
          g_layout(p_doc).plans(l_idx) := rad_pdf_text.prepare_runs(p_doc,
            g_layout(p_doc).runs_defs(l_flow.para_runs_ref_id).runs,
            g_layout(p_doc).runs_defs(l_flow.para_runs_ref_id).base_style,l_frame.width);
        WHEN rad_pdf_types.c_flow_table THEN
          rad_pdf_table.prepare_table(p_doc,l_flow.table_ref_id);
        ELSE NULL;
      END CASE;
      IF g_layout(p_doc).plans.EXISTS(l_idx) THEN
        l_flow.measured_h := g_layout(p_doc).plans(l_idx).height;
      END IF;
      g_layout(p_doc).flowables(l_idx) := l_flow;
      l_idx := g_layout(p_doc).flowables.NEXT(l_idx);
    END LOOP;

    l_y := l_frame.y;
    l_idx := g_layout(p_doc).flowables.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      l_flow := g_layout(p_doc).flowables(l_idx);
      l_h := NVL(l_flow.measured_h,0);
      IF g_layout(p_doc).plans.EXISTS(l_idx) THEN
        -- Keep a fitting paragraph together; longer paragraphs split by line.
        IF l_h <= l_frame.height AND l_y-l_h < l_frame.y-l_frame.height THEN
          rad_pdf_canvas.new_page(p_doc); apply_template_to_page(p_doc); l_y := l_frame.y;
        END IF;
        IF NVL(l_flow.keep_with_next,FALSE) THEN
          l_next_idx := g_layout(p_doc).flowables.NEXT(l_idx);
          IF l_next_idx IS NOT NULL THEN
            l_sz := l_h;
            IF g_layout(p_doc).plans.EXISTS(l_next_idx)
               AND g_layout(p_doc).plans(l_next_idx).lines.COUNT>0 THEN
              l_sz := l_sz+g_layout(p_doc).plans(l_next_idx).lines(1).height;
            END IF;
            IF l_sz <= l_frame.height AND l_y-l_sz < l_frame.y-l_frame.height THEN
              rad_pdf_canvas.new_page(p_doc); apply_template_to_page(p_doc); l_y := l_frame.y;
            END IF;
          END IF;
        END IF;
        IF NVL(l_flow.bookmark,FALSE) THEN
          rad_pdf_canvas.add_bookmark(p_doc,DBMS_LOB.SUBSTR(l_flow.text,500,1),
                                      NVL(l_flow.level,1),p_y=>l_y);
        END IF;
        paint_plan(p_doc,g_layout(p_doc).plans(l_idx),l_frame,l_y);
      ELSIF l_flow.flow_type = rad_pdf_types.c_flow_table THEN
        rad_pdf_table.draw_table(p_doc,l_flow.table_ref_id,l_frame.x,l_y,l_frame.width,l_y);
      ELSIF l_flow.flow_type = rad_pdf_types.c_flow_pagebreak THEN
        rad_pdf_canvas.new_page(p_doc); apply_template_to_page(p_doc); l_y := l_frame.y;
      ELSE
        CASE l_flow.flow_type
          WHEN rad_pdf_types.c_flow_spacer THEN l_h := GREATEST(NVL(l_flow.spacer_h,0),0);
          WHEN rad_pdf_types.c_flow_hline THEN l_h := 2;
          WHEN rad_pdf_types.c_flow_qrcode THEN l_h := l_flow.img_width;
          WHEN rad_pdf_types.c_flow_image THEN
            rad_pdf_images.get_image_dimensions(p_doc,l_flow.image_id,l_img_w,l_img_h);
            l_sz := NVL(l_flow.img_width,
                      CASE WHEN l_flow.img_height IS NOT NULL
                           THEN l_flow.img_height*l_img_w/l_img_h ELSE l_frame.width END);
            l_h := NVL(l_flow.img_height,l_sz*l_img_h/l_img_w);
            IF l_sz <= 0 OR l_h <= 0 THEN
              RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_layout,'Image dimensions must be positive');
            END IF;
            l_x := LEAST(1,l_frame.width/l_sz,l_frame.height/l_h);
            l_sz := l_sz*l_x; l_h := l_h*l_x;
          ELSE RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_layout,'Unknown flowable type');
        END CASE;
        IF l_h > l_frame.height THEN
          RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_layout,'Flowable exceeds content frame height');
        END IF;
        IF l_y-l_h < l_frame.y-l_frame.height THEN
          rad_pdf_canvas.new_page(p_doc); apply_template_to_page(p_doc); l_y := l_frame.y;
        END IF;
        IF l_flow.flow_type = rad_pdf_types.c_flow_hline THEN
          rad_pdf_canvas.h_line(p_doc,l_frame.x,l_y-1,l_frame.width,
                                NVL(l_flow.img_width,0.5),l_flow.style_name,'pt');
        ELSIF l_flow.flow_type = rad_pdf_types.c_flow_image THEN
          rad_pdf_canvas.put_image(p_doc,l_flow.image_id,l_frame.x,l_y,l_sz,l_h,'L','T','pt');
        ELSIF l_flow.flow_type = rad_pdf_types.c_flow_qrcode THEN
          l_x := l_frame.x+CASE l_flow.qr_align WHEN 'C' THEN (l_frame.width-l_h)/2
                                                    WHEN 'R' THEN l_frame.width-l_h ELSE 0 END;
          rad_pdf_barcode.qrcode(p_doc,DBMS_LOB.SUBSTR(l_flow.text,4000,1),
            l_x,l_y-l_h,l_h,l_flow.qr_ec,l_flow.style_name,'pt');
        END IF;
        l_y := l_y-l_h;
      END IF;
      l_idx := g_layout(p_doc).flowables.NEXT(l_idx);
    END LOOP;
    g_layout(p_doc).total_pages := rad_pdf_serial.page_count(p_doc);
    rad_pdf_canvas.run_page_procs(p_doc,g_layout(p_doc).total_pages);
  END render;

-- ---------------------------------------------------------------------------
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_idx  PLS_INTEGER;
    l_tidx PLS_INTEGER;
  BEGIN
    IF NOT g_layout.EXISTS(p_doc) THEN RETURN; END IF;
    l_idx := g_layout(p_doc).flowables.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      IF DBMS_LOB.ISTEMPORARY(g_layout(p_doc).flowables(l_idx).text)=1 THEN
        DBMS_LOB.FREETEMPORARY(g_layout(p_doc).flowables(l_idx).text);
      END IF;
      l_idx := g_layout(p_doc).flowables.NEXT(l_idx);
    END LOOP;
    l_tidx := g_layout(p_doc).table_defs.FIRST;
    WHILE l_tidx IS NOT NULL LOOP
      IF DBMS_LOB.ISTEMPORARY(g_layout(p_doc).table_defs(l_tidx).query_clob)=1 THEN
        DBMS_LOB.FREETEMPORARY(g_layout(p_doc).table_defs(l_tidx).query_clob);
      END IF;
      l_tidx := g_layout(p_doc).table_defs.NEXT(l_tidx);
    END LOOP;
    -- runs_defs holds only VARCHAR2 data; no FREETEMPORARY needed.
    g_layout(p_doc).runs_defs.DELETE;
    g_layout.DELETE(p_doc);
  END close_doc;

END rad_pdf_layout;
/
