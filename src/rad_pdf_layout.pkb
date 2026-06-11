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
  -- Word atom: one non-space token from a run, with its resolved style name.
  TYPE t_atom IS RECORD (
    word         VARCHAR2(32767),
    style_name   VARCHAR2(110),
    space_before BOOLEAN := FALSE,   -- TRUE = space must precede this atom
    is_br        BOOLEAN := FALSE    -- TRUE = forced line-break marker
  );
  TYPE t_atom_list IS TABLE OF t_atom INDEX BY PLS_INTEGER;

  -- Registered run set per flowable (keyed by para_runs_ref_id).
  TYPE t_runs_entry IS RECORD (
    runs       rad_pdf_types.t_inline_run_list,
    base_style VARCHAR2(110) := 'body'
  );
  TYPE t_runs_registry IS TABLE OF t_runs_entry INDEX BY PLS_INTEGER;

  TYPE t_layout_state IS RECORD (
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
-- Private: expand a t_inline_run_list into a flat word-atom list.
-- Each atom is a single non-space token from a run, tagged with its style.
-- Space handling:
--   • space_before=TRUE  → a space separates this atom from the previous one
--   • space_before=FALSE → atoms are adjacent (e.g. mid-word style change)
--   • is_br=TRUE         → forced line-break (from <br/>); word is NULL
-- ---------------------------------------------------------------------------
  PROCEDURE expand_atoms(
    p_runs  IN  rad_pdf_types.t_inline_run_list,
    p_atoms OUT t_atom_list,
    p_count OUT PLS_INTEGER
  ) IS
    l_text    VARCHAR2(32767);
    l_len     PLS_INTEGER;
    l_pos     PLS_INTEGER;
    l_ws      PLS_INTEGER;
    l_word    VARCHAR2(32767);
    l_skipped BOOLEAN;
    l_first   BOOLEAN;
    l_prev_sp BOOLEAN := FALSE;   -- did the previous run end with a space?
    l_atom    t_atom;
    i         PLS_INTEGER;
  BEGIN
    p_count := 0;
    i := p_runs.FIRST;
    WHILE i IS NOT NULL LOOP
      IF p_runs(i).is_br THEN
        p_count := p_count + 1;
        p_atoms(p_count).word         := NULL;
        p_atoms(p_count).style_name   := NVL(p_runs(i).style_name, 'body');
        p_atoms(p_count).space_before := FALSE;
        p_atoms(p_count).is_br        := TRUE;
        l_prev_sp := FALSE;
      ELSE
        l_text  := NVL(p_runs(i).text, '');
        l_len   := NVL(LENGTH(l_text), 0);
        l_pos   := 1;
        l_first := TRUE;
        WHILE l_pos <= l_len LOOP
          -- Skip whitespace
          l_skipped := FALSE;
          WHILE l_pos <= l_len AND SUBSTR(l_text, l_pos, 1) = ' ' LOOP
            l_skipped := TRUE;
            l_pos     := l_pos + 1;
          END LOOP;
          EXIT WHEN l_pos > l_len;
          -- Extract next word (non-space run)
          l_ws := l_pos;
          WHILE l_pos <= l_len AND SUBSTR(l_text, l_pos, 1) != ' ' LOOP
            l_pos := l_pos + 1;
          END LOOP;
          l_word := SUBSTR(l_text, l_ws, l_pos - l_ws);
          -- Build atom
          p_count := p_count + 1;
          p_atoms(p_count).word       := l_word;
          p_atoms(p_count).style_name := NVL(p_runs(i).style_name, 'body');
          p_atoms(p_count).is_br      := FALSE;
          IF l_first THEN
            -- First word of run: space_before = prev run ended with space
            --                    OR this run starts with space(s).
            p_atoms(p_count).space_before := l_prev_sp OR l_skipped;
            l_first := FALSE;
          ELSE
            -- Subsequent words within same run: always space-separated.
            p_atoms(p_count).space_before := TRUE;
          END IF;
        END LOOP;
        -- Record whether this run ended with a space.
        l_prev_sp := (l_len > 0 AND SUBSTR(l_text, l_len, 1) = ' ');
      END IF;
      i := p_runs.NEXT(i);
    END LOOP;
  END expand_atoms;

-- ---------------------------------------------------------------------------
-- Private: measure height of a PARA_RUNS flowable (no rendering).
-- ---------------------------------------------------------------------------
  FUNCTION measure_para_runs(
    p_doc    IN rad_pdf_types.t_doc_handle,
    p_ref_id IN PLS_INTEGER,
    p_w      IN NUMBER
  ) RETURN NUMBER IS
    l_atoms    t_atom_list;
    l_n        PLS_INTEGER;
    l_entry    t_runs_entry;
    l_base_sty rad_pdf_types.t_cell_format;
    l_cur_sty  rad_pdf_types.t_cell_format;
    l_lead     NUMBER;
    l_lines    PLS_INTEGER := 0;
    l_line_w   NUMBER      := 0;
    l_word_w   NUMBER;
    l_space_w  NUMBER;
    l_first    BOOLEAN := TRUE;
    j          PLS_INTEGER;
  BEGIN
    IF NOT g_layout.EXISTS(p_doc) THEN RETURN 0; END IF;
    IF NOT g_layout(p_doc).runs_defs.EXISTS(p_ref_id) THEN RETURN 0; END IF;
    l_entry    := g_layout(p_doc).runs_defs(p_ref_id);
    l_base_sty := rad_pdf_styles.get(NVL(l_entry.base_style, 'body'));
    l_lead     := l_base_sty.font_size * 1.2;
    expand_atoms(l_entry.runs, l_atoms, l_n);
    j := 1;
    WHILE j <= l_n LOOP
      IF l_atoms(j).is_br THEN
        -- Forced line break; flush current line
        IF NOT l_first THEN
          l_lines  := l_lines + 1;
          l_line_w := 0;
          l_first  := TRUE;
        END IF;
      ELSE
        l_cur_sty := rad_pdf_styles.get(l_atoms(j).style_name);
        rad_pdf_canvas.set_font(p_doc,
          l_cur_sty.font_name, l_cur_sty.font_style, l_cur_sty.font_size);
        l_word_w  := rad_pdf_canvas.text_width(p_doc, l_atoms(j).word);
        l_space_w := rad_pdf_canvas.text_width(p_doc, ' ');
        IF l_first THEN
          l_line_w := l_word_w;
          l_first  := FALSE;
        ELSIF l_atoms(j).space_before THEN
          IF l_line_w + l_space_w + l_word_w > p_w THEN
            l_lines  := l_lines + 1;
            l_line_w := l_word_w;
          ELSE
            l_line_w := l_line_w + l_space_w + l_word_w;
          END IF;
        ELSE
          -- Adjacent (no space): mid-word style change
          IF l_line_w + l_word_w > p_w THEN
            l_lines  := l_lines + 1;
            l_line_w := l_word_w;
          ELSE
            l_line_w := l_line_w + l_word_w;
          END IF;
        END IF;
      END IF;
      j := j + 1;
    END LOOP;
    IF NOT l_first THEN
      l_lines := l_lines + 1;   -- last (or only) line
    END IF;
    RETURN l_lines * l_lead;
  END measure_para_runs;

-- ---------------------------------------------------------------------------
-- Private: render a PARA_RUNS flowable onto the current page.
-- Uses a nested flush_line procedure to emit completed lines with alignment.
-- ---------------------------------------------------------------------------
  PROCEDURE render_para_runs(
    p_doc    IN rad_pdf_types.t_doc_handle,
    p_ref_id IN PLS_INTEGER,
    p_frame  IN rad_pdf_types.t_frame,
    p_y      IN NUMBER
  ) IS
    l_atoms  t_atom_list;
    l_n      PLS_INTEGER;
    l_entry  t_runs_entry;
    l_base   rad_pdf_types.t_cell_format;
    l_cur    rad_pdf_types.t_cell_format;
    l_lead   NUMBER;
    l_x      NUMBER := p_frame.x;
    l_y      NUMBER := p_y;
    l_w      NUMBER := p_frame.width;
    l_align  rad_pdf_types.t_align_h;

    -- Line segment buffer
    TYPE t_seg IS RECORD (
      word        VARCHAR2(32767),
      style_name  VARCHAR2(110),
      word_width  NUMBER,
      space_width NUMBER,
      space_before BOOLEAN := FALSE
    );
    TYPE t_seg_list IS TABLE OF t_seg INDEX BY PLS_INTEGER;
    l_segs      t_seg_list;
    l_seg_count PLS_INTEGER := 0;
    l_line_w    NUMBER      := 0;
    l_first     BOOLEAN     := TRUE;
    l_word_w    NUMBER;
    l_space_w   NUMBER;
    j           PLS_INTEGER;

    -- Nested: flush current line to PDF
    PROCEDURE flush_line IS
      l_total NUMBER := 0;
      l_off_x NUMBER;
      l_cur_x NUMBER;
      l_sty   rad_pdf_types.t_cell_format;
      k       PLS_INTEGER;
    BEGIN
      IF l_seg_count = 0 THEN RETURN; END IF;
      -- Compute total line width (sum words + inter-word spaces)
      k := 1;
      WHILE k <= l_seg_count LOOP
        IF k > 1 AND l_segs(k).space_before THEN
          l_total := l_total + l_segs(k).space_width;
        END IF;
        l_total := l_total + l_segs(k).word_width;
        k := k + 1;
      END LOOP;
      -- Alignment offset
      l_off_x := CASE l_align
                   WHEN 'R' THEN l_x + (l_w - l_total)
                   WHEN 'C' THEN l_x + (l_w - l_total) / 2
                   ELSE l_x
                 END;
      l_cur_x := l_off_x;
      -- Draw each segment
      k := 1;
      WHILE k <= l_seg_count LOOP
        IF k > 1 AND l_segs(k).space_before THEN
          l_cur_x := l_cur_x + l_segs(k).space_width;
        END IF;
        l_sty := rad_pdf_styles.get(l_segs(k).style_name);
        rad_pdf_canvas.set_font(p_doc,
          l_sty.font_name, l_sty.font_style, l_sty.font_size);
        rad_pdf_canvas.set_color(p_doc, NVL(l_sty.font_color, '000000'));
        rad_pdf_canvas.write_text(p_doc, l_segs(k).word, l_cur_x, l_y, 'pt');
        l_cur_x := l_cur_x + l_segs(k).word_width;
        k := k + 1;
      END LOOP;
      -- Advance y by leading; reset line buffer
      l_y         := l_y - l_lead;
      l_seg_count := 0;
      l_line_w    := 0;
      l_first     := TRUE;
    END flush_line;

  BEGIN
    IF NOT g_layout.EXISTS(p_doc) THEN RETURN; END IF;
    IF NOT g_layout(p_doc).runs_defs.EXISTS(p_ref_id) THEN RETURN; END IF;
    l_entry := g_layout(p_doc).runs_defs(p_ref_id);
    l_base  := rad_pdf_styles.get(NVL(l_entry.base_style, 'body'));
    l_lead  := l_base.font_size * 1.2;
    l_align := NVL(l_base.align_h, 'L');
    expand_atoms(l_entry.runs, l_atoms, l_n);
    IF l_n = 0 THEN RETURN; END IF;

    j := 1;
    WHILE j <= l_n LOOP
      IF l_atoms(j).is_br THEN
        flush_line;
      ELSE
        l_cur   := rad_pdf_styles.get(l_atoms(j).style_name);
        rad_pdf_canvas.set_font(p_doc,
          l_cur.font_name, l_cur.font_style, l_cur.font_size);
        l_word_w  := rad_pdf_canvas.text_width(p_doc, l_atoms(j).word);
        l_space_w := rad_pdf_canvas.text_width(p_doc, ' ');
        IF l_first THEN
          l_seg_count := l_seg_count + 1;
          l_segs(l_seg_count).word        := l_atoms(j).word;
          l_segs(l_seg_count).style_name  := l_atoms(j).style_name;
          l_segs(l_seg_count).word_width  := l_word_w;
          l_segs(l_seg_count).space_width := l_space_w;
          l_segs(l_seg_count).space_before := FALSE;
          l_line_w := l_word_w;
          l_first  := FALSE;
        ELSIF l_atoms(j).space_before THEN
          IF l_line_w + l_space_w + l_word_w > l_w THEN
            flush_line;
            l_seg_count := l_seg_count + 1;
            l_segs(l_seg_count).word        := l_atoms(j).word;
            l_segs(l_seg_count).style_name  := l_atoms(j).style_name;
            l_segs(l_seg_count).word_width  := l_word_w;
            l_segs(l_seg_count).space_width := l_space_w;
            l_segs(l_seg_count).space_before := FALSE;
            l_line_w := l_word_w;
          ELSE
            l_seg_count := l_seg_count + 1;
            l_segs(l_seg_count).word        := l_atoms(j).word;
            l_segs(l_seg_count).style_name  := l_atoms(j).style_name;
            l_segs(l_seg_count).word_width  := l_word_w;
            l_segs(l_seg_count).space_width := l_space_w;
            l_segs(l_seg_count).space_before := TRUE;
            l_line_w := l_line_w + l_space_w + l_word_w;
          END IF;
        ELSE
          -- Adjacent (no space): mid-word style change
          IF l_line_w + l_word_w > l_w THEN
            flush_line;
            l_seg_count := l_seg_count + 1;
            l_segs(l_seg_count).word        := l_atoms(j).word;
            l_segs(l_seg_count).style_name  := l_atoms(j).style_name;
            l_segs(l_seg_count).word_width  := l_word_w;
            l_segs(l_seg_count).space_width := l_space_w;
            l_segs(l_seg_count).space_before := FALSE;
            l_line_w := l_word_w;
          ELSE
            l_seg_count := l_seg_count + 1;
            l_segs(l_seg_count).word        := l_atoms(j).word;
            l_segs(l_seg_count).style_name  := l_atoms(j).style_name;
            l_segs(l_seg_count).word_width  := l_word_w;
            l_segs(l_seg_count).space_width := l_space_w;
            l_segs(l_seg_count).space_before := FALSE;
            l_line_w := l_line_w + l_word_w;
          END IF;
        END IF;
      END IF;
      j := j + 1;
    END LOOP;
    flush_line;   -- emit last (or only) line
  END render_para_runs;

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
      WHEN rad_pdf_types.c_flow_para_runs THEN
        RETURN measure_para_runs(p_doc, p_flow.para_runs_ref_id, p_frame.width);
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
        -- p_y is the top of the heading: the exact outline destination.
        IF NVL(p_flow.bookmark, FALSE) THEN
          rad_pdf_canvas.add_bookmark(p_doc, SUBSTR(l_text, 1, 500),
                                      NVL(p_flow.level, 1), p_y => p_y);
        END IF;
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
      WHEN rad_pdf_types.c_flow_para_runs THEN
        render_para_runs(p_doc, p_flow.para_runs_ref_id, p_frame, p_y);
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
    -- runs_defs holds only VARCHAR2 data; no FREETEMPORARY needed.
    g_layout(p_doc).runs_defs.DELETE;
    g_layout.DELETE(p_doc);
  END close_doc;

END rad_pdf_layout;
/
