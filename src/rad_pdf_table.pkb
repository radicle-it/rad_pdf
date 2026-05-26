CREATE OR REPLACE PACKAGE BODY rad_pdf_table IS
/*
  rad_pdf_table body — Phase 7 of the RAD_PDF modular refactoring.
  AUTHID CURRENT_USER: SQL queries execute with the caller's privileges.

  Column widths in t_column_def are in points (after unit conversion).
  draw_table scales widths proportionally to fill p_width.
*/

-- ---------------------------------------------------------------------------
-- Private cache: (doc_handle → (table_ref → cached rows))
-- ---------------------------------------------------------------------------
  TYPE t_row_values   IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;
  TYPE t_cached_rows  IS TABLE OF t_row_values    INDEX BY PLS_INTEGER;
  TYPE t_table_cache  IS RECORD (
    data      t_cached_rows,
    row_count PLS_INTEGER := 0,
    col_count PLS_INTEGER := 0
  );
  TYPE t_cache_by_ref IS TABLE OF t_table_cache   INDEX BY PLS_INTEGER;
  TYPE t_cache_by_doc IS TABLE OF t_cache_by_ref  INDEX BY PLS_INTEGER;
  g_table_cache t_cache_by_doc;

-- ---------------------------------------------------------------------------
  PROCEDURE ensure_cache(p_doc IN rad_pdf_types.t_doc_handle,
                         p_ref IN PLS_INTEGER) IS
    l_empty_ref t_cache_by_ref;
    l_tc        t_table_cache;
  BEGIN
    IF NOT g_table_cache.EXISTS(p_doc) THEN
      g_table_cache(p_doc) := l_empty_ref;
    END IF;
    IF NOT g_table_cache(p_doc).EXISTS(p_ref) THEN
      g_table_cache(p_doc)(p_ref) := l_tc;
    END IF;
  END ensure_cache;

-- ---------------------------------------------------------------------------
-- Fetch rows from an already-parsed (and optionally executed) DBMS_SQL
-- cursor into the document table cache.
-- p_execute = TRUE: the helper calls DBMS_SQL.EXECUTE (VARCHAR2 / CLOB queries).
-- p_execute = FALSE: cursor is already running (SYS_REFCURSOR → TO_CURSOR_NUMBER).
-- ---------------------------------------------------------------------------
  PROCEDURE fetch_into_cache(
    p_doc       IN rad_pdf_types.t_doc_handle,
    p_table_ref IN PLS_INTEGER,
    p_cursor    IN INTEGER,
    p_max_rows  IN PLS_INTEGER,
    p_execute   IN BOOLEAN DEFAULT FALSE
  ) IS
    l_desc   DBMS_SQL.DESC_TAB2;
    l_ncols  PLS_INTEGER;
    l_val    VARCHAR2(32767);
    l_dummy  INTEGER;
    l_row_nr PLS_INTEGER := 0;
  BEGIN
    DBMS_SQL.DESCRIBE_COLUMNS2(p_cursor, l_ncols, l_desc);
    g_table_cache(p_doc)(p_table_ref).col_count := l_ncols;
    FOR c IN 1..l_ncols LOOP
      DBMS_SQL.DEFINE_COLUMN(p_cursor, c, l_val, 32767);
    END LOOP;
    IF p_execute THEN l_dummy := DBMS_SQL.EXECUTE(p_cursor); END IF;
    LOOP
      EXIT WHEN DBMS_SQL.FETCH_ROWS(p_cursor) = 0;
      l_row_nr := l_row_nr + 1;
      FOR c IN 1..l_ncols LOOP
        DBMS_SQL.COLUMN_VALUE(p_cursor, c, l_val);
        g_table_cache(p_doc)(p_table_ref).data(l_row_nr)(c) := l_val;
      END LOOP;
      IF p_max_rows IS NOT NULL AND l_row_nr >= p_max_rows THEN EXIT; END IF;
    END LOOP;
    g_table_cache(p_doc)(p_table_ref).row_count := l_row_nr;
  END fetch_into_cache;

-- ---------------------------------------------------------------------------
-- Row height for a cell format, in pt (font + margins).
-- ---------------------------------------------------------------------------
  FUNCTION row_height(p_fmt IN rad_pdf_types.t_cell_format, p_override IN NUMBER)
    RETURN NUMBER IS
  BEGIN
    RETURN NVL(p_override,
           NVL(p_fmt.cell_height,
               NVL(p_fmt.font_size, 10) * 1.2
               + NVL(p_fmt.margin_top, 1) + NVL(p_fmt.margin_bot, 1)));
  END row_height;

-- ---------------------------------------------------------------------------
-- Scale column widths proportionally to fill p_total_width.
-- Returns array indexed by col position (1-based).
-- ---------------------------------------------------------------------------
  FUNCTION col_widths(p_cols        IN rad_pdf_types.t_columns,
                      p_total_width IN NUMBER,
                      p_unit        IN rad_pdf_types.t_unit) RETURN rad_pdf_types.t_number_list IS
    l_ws    rad_pdf_types.t_number_list;
    l_sum   NUMBER := 0;
    l_scale NUMBER;
    i       PLS_INTEGER;
  BEGIN
    i := p_cols.FIRST;
    WHILE i IS NOT NULL LOOP
      l_ws(i) := rad_pdf_units.to_pt(p_cols(i).width, p_unit);
      l_sum    := l_sum + l_ws(i);
      i        := p_cols.NEXT(i);
    END LOOP;
    IF l_sum > 0 THEN
      l_scale := p_total_width / l_sum;
      i := l_ws.FIRST;
      WHILE i IS NOT NULL LOOP
        l_ws(i) := l_ws(i) * l_scale;
        i        := l_ws.NEXT(i);
      END LOOP;
    END IF;
    RETURN l_ws;
  END col_widths;

-- ---------------------------------------------------------------------------
-- Draw a single cell: background, text, border.
-- p_x, p_y: lower-left corner of cell (PDF coords).
-- p_w, p_h: width and height in pt.
-- p_wrap: when TRUE text flows top-down via write_wrapped.
-- ---------------------------------------------------------------------------
  PROCEDURE draw_cell(p_doc   IN rad_pdf_types.t_doc_handle,
                      p_text  IN VARCHAR2,
                      p_x     IN NUMBER,
                      p_y     IN NUMBER,
                      p_w     IN NUMBER,
                      p_h     IN NUMBER,
                      p_fmt   IN rad_pdf_types.t_cell_format,
                      p_wrap  IN BOOLEAN DEFAULT FALSE) IS
    l_tx      NUMBER;
    l_ty      NUMBER;
    l_tw      NUMBER;
    l_inner_w NUMBER;
  BEGIN
    -- Background: p_x/p_y is the lower-left corner; rect takes lower-left coords.
    rad_pdf_canvas.rect(p_doc, p_x, p_y, p_w, p_h, NULL, p_fmt.back_color, 0, 'pt');
    -- Border
    IF NVL(p_fmt.border, 0) != rad_pdf_types.c_border_none THEN
      IF BITAND(p_fmt.border, rad_pdf_types.c_border_top) != 0 THEN
        rad_pdf_canvas.h_line(p_doc, p_x, p_y + p_h, p_w, NVL(p_fmt.line_size, 0.5), p_fmt.line_color, 'pt');
      END IF;
      IF BITAND(p_fmt.border, rad_pdf_types.c_border_bottom) != 0 THEN
        rad_pdf_canvas.h_line(p_doc, p_x, p_y, p_w, NVL(p_fmt.line_size, 0.5), p_fmt.line_color, 'pt');
      END IF;
      IF BITAND(p_fmt.border, rad_pdf_types.c_border_left) != 0 THEN
        rad_pdf_canvas.v_line(p_doc, p_x, p_y + p_h, p_h, NVL(p_fmt.line_size, 0.5), p_fmt.line_color, 'pt');
      END IF;
      IF BITAND(p_fmt.border, rad_pdf_types.c_border_right) != 0 THEN
        rad_pdf_canvas.v_line(p_doc, p_x + p_w, p_y + p_h, p_h, NVL(p_fmt.line_size, 0.5), p_fmt.line_color, 'pt');
      END IF;
    END IF;
    -- Text
    IF p_text IS NOT NULL AND LENGTH(p_text) > 0 THEN
      rad_pdf_canvas.set_font(p_doc, p_fmt.font_name, p_fmt.font_style, p_fmt.font_size);
      rad_pdf_canvas.set_color(p_doc, p_fmt.font_color);
      IF p_wrap THEN
        -- Wrapped: flow top-down from inside top margin
        l_tx      := p_x + NVL(p_fmt.margin_left, 1);
        l_ty      := p_y + p_h - NVL(p_fmt.margin_top, 1) - NVL(p_fmt.font_size, 9);
        l_inner_w := p_w - NVL(p_fmt.margin_left, 1) - NVL(p_fmt.margin_rgt, 1);
        rad_pdf_canvas.write_wrapped(p_doc, p_text, l_tx, l_ty, l_inner_w,
                                     NVL(p_fmt.align_h, 'L'), 'pt');
      ELSE
        l_tw := rad_pdf_canvas.text_width(p_doc, p_text);
        -- Vertically centre the text in the row.
        -- The constant 0.25 ≈ (cap_height_ratio − descender_ratio) / 2
        -- = (0.718 − 0.207) / 2 for Helvetica, which makes the visual
        -- midpoint between cap-ascenders and descenders coincide with the
        -- cell midpoint.  This keeps descenders inside the cell even when
        -- row_height overrides produce taller-than-minimum rows.
        -- Honour an explicit margin_bot (non-NULL) as a legacy bottom offset.
        IF p_fmt.margin_bot IS NOT NULL THEN
          l_ty := p_y + p_fmt.margin_bot;
        ELSE
          l_ty := p_y + p_h / 2 - NVL(p_fmt.font_size, 9) * 0.25;
        END IF;
        CASE p_fmt.align_h
          WHEN 'R' THEN l_tx := p_x + p_w - l_tw - NVL(p_fmt.margin_rgt,  1);
          WHEN 'C' THEN l_tx := p_x + (p_w - l_tw) / 2;
          ELSE           l_tx := p_x + NVL(p_fmt.margin_left, 1);
        END CASE;
        rad_pdf_canvas.write_text(p_doc, p_text, l_tx, l_ty, 'pt');
      END IF;
    END IF;
  END draw_cell;

-- ---------------------------------------------------------------------------
-- Compute actual height of a data row when one or more columns have wrap=TRUE.
-- For non-wrap columns the fixed row_height is used; for wrap columns the cell
-- height is measured via measure_wrapped. The max across all columns is returned.
-- ---------------------------------------------------------------------------
  FUNCTION wrapped_row_height(p_doc IN rad_pdf_types.t_doc_handle,
                               p_def IN rad_pdf_types.t_table_def,
                               p_ws  IN rad_pdf_types.t_number_list,
                               p_row IN t_row_values) RETURN NUMBER IS
    l_h      NUMBER := row_height(p_def.col_defs(p_def.col_defs.FIRST).data_fmt,
                                  p_def.options.t_row_height);
    l_ch     NUMBER;
    l_inner  NUMBER;
    l_fmt    rad_pdf_types.t_cell_format;
    l_text   VARCHAR2(32767);
    i        PLS_INTEGER;
  BEGIN
    i := p_def.col_defs.FIRST;
    WHILE i IS NOT NULL LOOP
      IF p_def.col_defs(i).wrap THEN
        l_fmt   := p_def.col_defs(i).data_fmt;
        l_text  := CASE WHEN p_row.EXISTS(i) THEN p_row(i) ELSE NULL END;
        IF l_text IS NOT NULL AND LENGTH(l_text) > 0 THEN
          rad_pdf_canvas.set_font(p_doc,
            NVL(l_fmt.font_name, 'Helvetica'),
            l_fmt.font_style,
            NVL(l_fmt.font_size, 9));
          l_inner := p_ws(i) - NVL(l_fmt.margin_left, 1) - NVL(l_fmt.margin_rgt, 1);
          l_ch    := rad_pdf_canvas.measure_wrapped(p_doc, l_text, l_inner, 'pt')
                     + NVL(l_fmt.margin_top, 1) + NVL(l_fmt.margin_bot, 1);
          IF l_ch > l_h THEN l_h := l_ch; END IF;
        END IF;
      END IF;
      i := p_def.col_defs.NEXT(i);
    END LOOP;
    RETURN l_h;
  END wrapped_row_height;

-- ---------------------------------------------------------------------------
-- Returns TRUE if any column in the definition has wrap = TRUE.
-- ---------------------------------------------------------------------------
  FUNCTION has_wrap_cols(p_def IN rad_pdf_types.t_table_def) RETURN BOOLEAN IS
    i PLS_INTEGER;
  BEGIN
    i := p_def.col_defs.FIRST;
    WHILE i IS NOT NULL LOOP
      IF NVL(p_def.col_defs(i).wrap, FALSE) THEN RETURN TRUE; END IF;
      i := p_def.col_defs.NEXT(i);
    END LOOP;
    RETURN FALSE;
  END has_wrap_cols;

-- ---------------------------------------------------------------------------
-- Draw header row starting at (p_x, p_y upper edge). Returns row height.
-- ---------------------------------------------------------------------------
  FUNCTION draw_header_row(p_doc   IN rad_pdf_types.t_doc_handle,
                           p_def   IN rad_pdf_types.t_table_def,
                           p_ws    IN rad_pdf_types.t_number_list,
                           p_x     IN NUMBER,
                           p_y     IN NUMBER) RETURN NUMBER IS
    l_h   NUMBER;
    l_cx  NUMBER := p_x;
    l_fmt rad_pdf_types.t_cell_format;
    i     PLS_INTEGER;
  BEGIN
    i   := p_def.col_defs.FIRST;
    l_h := row_height(p_def.col_defs(i).header_fmt, p_def.options.h_row_height);
    WHILE i IS NOT NULL LOOP
      l_fmt := p_def.col_defs(i).header_fmt;
      -- Apply header color scheme (parallel to even/odd in draw_data_row)
      l_fmt.font_color := p_def.color_scheme.header_ink;
      l_fmt.back_color := p_def.color_scheme.header_paper;
      l_fmt.line_color := p_def.color_scheme.header_border;
      -- Guard against NULL font fields when col_defs was built with EXTEND
      IF l_fmt.font_name IS NULL THEN l_fmt.font_name := 'Helvetica'; END IF;
      IF l_fmt.font_size IS NULL THEN l_fmt.font_size := 9; END IF;
      draw_cell(p_doc,
                NVL(p_def.col_defs(i).label, ''),
                l_cx, p_y - l_h,
                p_ws(i), l_h,
                l_fmt);
      l_cx := l_cx + p_ws(i);
      i    := p_def.col_defs.NEXT(i);
    END LOOP;
    RETURN l_h;
  END draw_header_row;

-- ---------------------------------------------------------------------------
-- Draw one data row. p_y = upper edge. Returns row height.
-- p_row_nr: 1-based row number (used for even/odd alternation).
-- ---------------------------------------------------------------------------
  FUNCTION draw_data_row(p_doc    IN rad_pdf_types.t_doc_handle,
                         p_def    IN rad_pdf_types.t_table_def,
                         p_ws     IN rad_pdf_types.t_number_list,
                         p_row    IN t_row_values,
                         p_row_nr IN PLS_INTEGER,
                         p_x      IN NUMBER,
                         p_y      IN NUMBER,
                         p_h_override IN NUMBER DEFAULT NULL) RETURN NUMBER IS
    l_h    NUMBER;
    l_cx   NUMBER := p_x;
    l_fmt  rad_pdf_types.t_cell_format;
    l_text VARCHAR2(32767);
    l_wrap BOOLEAN;
    i      PLS_INTEGER;
  BEGIN
    i := p_def.col_defs.FIRST;
    -- Use pre-computed height when provided (wrap mode), else fixed height
    l_h := NVL(p_h_override,
               row_height(p_def.col_defs(i).data_fmt, p_def.options.t_row_height));
    WHILE i IS NOT NULL LOOP
      l_fmt  := p_def.col_defs(i).data_fmt;
      l_wrap := NVL(p_def.col_defs(i).wrap, FALSE);
      -- Apply even/odd color scheme
      IF MOD(p_row_nr, 2) = 0 THEN
        l_fmt.font_color  := p_def.color_scheme.even_ink;
        l_fmt.back_color  := p_def.color_scheme.even_paper;
        l_fmt.line_color  := p_def.color_scheme.even_border;
      ELSE
        l_fmt.font_color  := p_def.color_scheme.odd_ink;
        l_fmt.back_color  := p_def.color_scheme.odd_paper;
        l_fmt.line_color  := p_def.color_scheme.odd_border;
      END IF;
      IF l_fmt.font_name IS NULL THEN l_fmt.font_name := 'Helvetica'; END IF;
      IF l_fmt.font_size IS NULL THEN l_fmt.font_size := 9; END IF;
      l_text := CASE WHEN p_row.EXISTS(i) THEN p_row(i) ELSE NULL END;
      IF l_text IS NOT NULL AND l_fmt.num_format IS NOT NULL THEN
        BEGIN
          l_text := TO_CHAR(TO_NUMBER(l_text), l_fmt.num_format);
        EXCEPTION
          WHEN OTHERS THEN NULL;
        END;
      END IF;
      draw_cell(p_doc,
                l_text,
                l_cx, p_y - l_h,
                p_ws(i), l_h,
                l_fmt,
                l_wrap);
      l_cx := l_cx + p_ws(i);
      i    := p_def.col_defs.NEXT(i);
    END LOOP;
    RETURN l_h;
  END draw_data_row;

-- ---------------------------------------------------------------------------
-- Build a t_flowable of type TABLE and register with rad_pdf_layout.
-- Called by table_flow variants.
-- ---------------------------------------------------------------------------
  FUNCTION build_table_flow(p_doc IN rad_pdf_types.t_doc_handle,
                             p_def IN rad_pdf_types.t_table_def)
    RETURN rad_pdf_types.t_flowable IS
    l_f   rad_pdf_types.t_flowable;
    l_ref PLS_INTEGER;
  BEGIN
    l_ref              := rad_pdf_layout.register_table(p_doc, p_def);
    l_f.flow_type      := rad_pdf_types.c_flow_table;
    l_f.table_ref_id   := l_ref;
    RETURN l_f;
  END build_table_flow;

-- ---------------------------------------------------------------------------
-- Public: table_flow (VARCHAR2 query)
-- ---------------------------------------------------------------------------
  FUNCTION table_flow(p_doc     IN rad_pdf_types.t_doc_handle,
                      p_query   IN VARCHAR2,
                      p_columns IN rad_pdf_types.t_columns,
                      p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                      p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options())
    RETURN rad_pdf_types.t_flowable IS
    l_def rad_pdf_types.t_table_def;
  BEGIN
    l_def.query_txt    := p_query;
    l_def.col_defs     := p_columns;
    l_def.color_scheme := p_colors;
    l_def.options      := p_options;
    RETURN build_table_flow(p_doc, l_def);
  END table_flow;

-- ---------------------------------------------------------------------------
  FUNCTION table_flow(p_doc     IN rad_pdf_types.t_doc_handle,
                      p_query   IN CLOB,
                      p_columns IN rad_pdf_types.t_columns,
                      p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                      p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options())
    RETURN rad_pdf_types.t_flowable IS
    l_def rad_pdf_types.t_table_def;
    l_len NUMBER;
  BEGIN
    l_len := DBMS_LOB.GETLENGTH(p_query);
    IF l_len > 0 THEN
      DBMS_LOB.CREATETEMPORARY(l_def.query_clob, TRUE);
      DBMS_LOB.COPY(l_def.query_clob, p_query, l_len);
    END IF;
    l_def.col_defs     := p_columns;
    l_def.color_scheme := p_colors;
    l_def.options      := p_options;
    RETURN build_table_flow(p_doc, l_def);
  END table_flow;

-- ---------------------------------------------------------------------------
  FUNCTION table_flow(p_doc     IN rad_pdf_types.t_doc_handle,
                      p_rc      IN OUT SYS_REFCURSOR,
                      p_columns IN rad_pdf_types.t_columns,
                      p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                      p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options())
    RETURN rad_pdf_types.t_flowable IS
    l_def    rad_pdf_types.t_table_def;
    l_flow   rad_pdf_types.t_flowable;
    l_ref    PLS_INTEGER;
    l_cur    INTEGER;
  BEGIN
    -- Refcursor data is cached immediately; streaming flag marks the measure pass as no-op.
    l_def.col_defs      := p_columns;
    l_def.color_scheme  := p_colors;
    l_def.options       := p_options;
    l_def.streaming     := TRUE;
    l_ref               := rad_pdf_layout.register_table(p_doc, l_def);
    l_flow.flow_type    := rad_pdf_types.c_flow_table;
    l_flow.table_ref_id := l_ref;
    ensure_cache(p_doc, l_ref);
    -- TO_CURSOR_NUMBER takes an already-opened refcursor; no EXECUTE needed.
    l_cur := DBMS_SQL.TO_CURSOR_NUMBER(p_rc);
    BEGIN
      fetch_into_cache(p_doc, l_ref, l_cur, p_options.max_rows, p_execute => FALSE);
      DBMS_SQL.CLOSE_CURSOR(l_cur);
    EXCEPTION
      WHEN OTHERS THEN
        BEGIN DBMS_SQL.CLOSE_CURSOR(l_cur); EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE;
    END;
    RETURN l_flow;
  END table_flow;

-- ---------------------------------------------------------------------------
  PROCEDURE query2table(p_doc IN rad_pdf_types.t_doc_handle, p_query IN VARCHAR2,
                        p_columns IN rad_pdf_types.t_columns,
                        p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                        p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options()) IS
  BEGIN
    rad_pdf_layout.add(p_doc, table_flow(p_doc, p_query, p_columns, p_colors, p_options));
  END query2table;

-- ---------------------------------------------------------------------------
  PROCEDURE query2table(p_doc IN rad_pdf_types.t_doc_handle, p_query IN CLOB,
                        p_columns IN rad_pdf_types.t_columns,
                        p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                        p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options()) IS
  BEGIN
    rad_pdf_layout.add(p_doc, table_flow(p_doc, p_query, p_columns, p_colors, p_options));
  END query2table;

-- ---------------------------------------------------------------------------
  PROCEDURE refcursor2table(p_doc IN rad_pdf_types.t_doc_handle,
                            p_rc  IN OUT SYS_REFCURSOR,
                            p_columns IN rad_pdf_types.t_columns,
                            p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                            p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options()) IS
  BEGIN
    rad_pdf_layout.add(p_doc, table_flow(p_doc, p_rc, p_columns, p_colors, p_options));
  END refcursor2table;

-- ---------------------------------------------------------------------------
-- Shared label-drawing loop used by query2labels and refcursor2labels.
-- Cursor must be ready for DESCRIBE + DEFINE + FETCH (no EXECUTE called here).
-- ---------------------------------------------------------------------------
  PROCEDURE draw_labels_from_cursor(
    p_doc     IN rad_pdf_types.t_doc_handle,
    p_cursor  IN INTEGER,
    p_columns IN rad_pdf_types.t_columns,
    p_label   IN rad_pdf_types.t_label_def,
    p_colors  IN rad_pdf_types.t_color_scheme,
    p_options IN rad_pdf_types.t_table_options,
    p_frame_x IN NUMBER,
    p_frame_y IN NUMBER
  ) IS
    l_ncols   PLS_INTEGER;
    l_desc    DBMS_SQL.DESC_TAB2;
    l_val     VARCHAR2(32767);
    l_row_nr  PLS_INTEGER := 0;
    l_col_pos PLS_INTEGER;
    l_row_pos PLS_INTEGER;
    l_cx      NUMBER;
    l_cy      NUMBER;
    l_c_idx   PLS_INTEGER;
  BEGIN
    DBMS_SQL.DESCRIBE_COLUMNS2(p_cursor, l_ncols, l_desc);
    FOR c IN 1..l_ncols LOOP
      DBMS_SQL.DEFINE_COLUMN(p_cursor, c, l_val, 32767);
    END LOOP;
    LOOP
      EXIT WHEN DBMS_SQL.FETCH_ROWS(p_cursor) = 0;
      l_row_nr  := l_row_nr + 1;
      l_col_pos := MOD(l_row_nr - 1, p_label.max_columns);
      l_row_pos := MOD(TRUNC((l_row_nr - 1) / p_label.max_columns), p_label.max_rows);
      IF l_row_nr > 1 AND l_col_pos = 0 AND l_row_pos = 0 THEN
        rad_pdf_canvas.new_page(p_doc);
      END IF;
      l_cx := p_frame_x + l_col_pos * (p_label.width + p_label.h_distance);
      l_cy := p_frame_y - l_row_pos * (p_label.height + p_label.v_distance);
      rad_pdf_canvas.rect(p_doc, l_cx, l_cy, p_label.width, p_label.height,
                      p_colors.header_border, NULL, 0.5, 'pt');
      l_c_idx := p_columns.FIRST;
      WHILE l_c_idx IS NOT NULL LOOP
        DBMS_SQL.COLUMN_VALUE(p_cursor, l_c_idx, l_val);
        IF l_val IS NOT NULL THEN
          rad_pdf_canvas.set_font(p_doc,
            p_columns(l_c_idx).data_fmt.font_name,
            p_columns(l_c_idx).data_fmt.font_style,
            p_columns(l_c_idx).data_fmt.font_size);
          rad_pdf_canvas.set_color(p_doc, p_columns(l_c_idx).data_fmt.font_color);
          rad_pdf_canvas.write_text(p_doc, l_val,
            l_cx + p_columns(l_c_idx).data_fmt.margin_left,
            l_cy - (l_c_idx - 1) * (p_columns(l_c_idx).data_fmt.font_size * 1.2 + 2)
                 - p_columns(l_c_idx).data_fmt.margin_top,
            'pt');
        END IF;
        l_c_idx := p_columns.NEXT(l_c_idx);
      END LOOP;
      IF p_options.max_rows IS NOT NULL AND l_row_nr >= p_options.max_rows THEN EXIT; END IF;
    END LOOP;
  END draw_labels_from_cursor;

-- ---------------------------------------------------------------------------
-- Label procedures — simplified grid layout
-- ---------------------------------------------------------------------------
  PROCEDURE query2labels(p_doc IN rad_pdf_types.t_doc_handle, p_query IN VARCHAR2,
                         p_columns IN rad_pdf_types.t_columns,
                         p_label   IN rad_pdf_types.t_label_def     DEFAULT rad_pdf_units.default_label_def(),
                         p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                         p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options()) IS
    l_cursor  INTEGER;
    l_dummy   INTEGER;
    l_frame_x NUMBER;
    l_frame_y NUMBER;
  BEGIN
    l_frame_x := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_left);
    l_frame_y := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_page_height)
                 - rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_top);
    l_cursor := DBMS_SQL.OPEN_CURSOR;
    BEGIN
      DBMS_SQL.PARSE(l_cursor, p_query, DBMS_SQL.NATIVE);
      l_dummy := DBMS_SQL.EXECUTE(l_cursor);
      draw_labels_from_cursor(p_doc, l_cursor, p_columns, p_label, p_colors, p_options,
                              l_frame_x, l_frame_y);
      DBMS_SQL.CLOSE_CURSOR(l_cursor);
    EXCEPTION
      WHEN OTHERS THEN
        BEGIN DBMS_SQL.CLOSE_CURSOR(l_cursor); EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE;
    END;
  END query2labels;

-- ---------------------------------------------------------------------------
  PROCEDURE query2labels(p_doc IN rad_pdf_types.t_doc_handle, p_query IN CLOB,
                         p_columns IN rad_pdf_types.t_columns,
                         p_label   IN rad_pdf_types.t_label_def     DEFAULT rad_pdf_units.default_label_def(),
                         p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                         p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options()) IS
  BEGIN
    -- For CLOB queries: convert to VARCHAR2 if short, else not supported
    IF DBMS_LOB.GETLENGTH(p_query) <= 32767 THEN
      query2labels(p_doc, DBMS_LOB.SUBSTR(p_query, 32767, 1),
                   p_columns, p_label, p_colors, p_options);
    END IF;
  END query2labels;

-- ---------------------------------------------------------------------------
  PROCEDURE refcursor2labels(p_doc IN rad_pdf_types.t_doc_handle,
                             p_rc  IN OUT SYS_REFCURSOR,
                             p_columns IN rad_pdf_types.t_columns,
                             p_label   IN rad_pdf_types.t_label_def     DEFAULT rad_pdf_units.default_label_def(),
                             p_colors  IN rad_pdf_types.t_color_scheme  DEFAULT rad_pdf_styles.default_scheme(),
                             p_options IN rad_pdf_types.t_table_options DEFAULT rad_pdf_units.default_table_options()) IS
    l_cursor  INTEGER;
    l_frame_x NUMBER;
    l_frame_y NUMBER;
  BEGIN
    l_frame_x := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_left);
    l_frame_y := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_page_height)
                 - rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_top);
    l_cursor := DBMS_SQL.TO_CURSOR_NUMBER(p_rc);
    BEGIN
      draw_labels_from_cursor(p_doc, l_cursor, p_columns, p_label, p_colors, p_options,
                              l_frame_x, l_frame_y);
      DBMS_SQL.CLOSE_CURSOR(l_cursor);
    EXCEPTION
      WHEN OTHERS THEN
        BEGIN DBMS_SQL.CLOSE_CURSOR(l_cursor); EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE;
    END;
  END refcursor2labels;

-- ---------------------------------------------------------------------------
-- measure_table: fetch data into cache, return total height.
-- ---------------------------------------------------------------------------
  FUNCTION measure_table(p_doc       IN rad_pdf_types.t_doc_handle,
                         p_table_ref IN PLS_INTEGER,
                         p_width     IN NUMBER) RETURN NUMBER IS
    l_def    rad_pdf_types.t_table_def;
    l_cursor INTEGER;
    l_row_nr PLS_INTEGER := 0;
    l_hdr_h  NUMBER;
    l_row_h  NUMBER;
    l_ws     rad_pdf_types.t_number_list;
  BEGIN
    l_def := rad_pdf_layout.get_table_def(p_doc, p_table_ref);
    ensure_cache(p_doc, p_table_ref);

    -- Streaming tables: skip fetch in measure pass
    IF l_def.streaming THEN
      RETURN 0;
    END IF;

    -- Open and execute the query
    l_cursor := DBMS_SQL.OPEN_CURSOR;
    BEGIN
      IF l_def.query_clob IS NOT NULL THEN
        DBMS_SQL.PARSE(l_cursor, l_def.query_clob, DBMS_SQL.NATIVE);
      ELSE
        DBMS_SQL.PARSE(l_cursor, l_def.query_txt, DBMS_SQL.NATIVE);
      END IF;
      fetch_into_cache(p_doc, p_table_ref, l_cursor, l_def.options.max_rows, p_execute => TRUE);
      DBMS_SQL.CLOSE_CURSOR(l_cursor);
    EXCEPTION
      WHEN OTHERS THEN
        BEGIN DBMS_SQL.CLOSE_CURSOR(l_cursor); EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE;
    END;
    l_row_nr := g_table_cache(p_doc)(p_table_ref).row_count;

    -- Height = header + data rows
    IF l_def.col_defs IS NOT NULL AND l_def.col_defs.COUNT > 0 THEN
      l_hdr_h := row_height(l_def.col_defs(l_def.col_defs.FIRST).header_fmt,
                             l_def.options.h_row_height);
      IF has_wrap_cols(l_def) THEN
        -- Sum actual per-row heights when any column wraps
        l_ws    := col_widths(l_def.col_defs, p_width, NVL(l_def.options.unit, 'pt'));
        l_row_h := 0;
        FOR r IN 1 .. l_row_nr LOOP
          l_row_h := l_row_h +
            wrapped_row_height(p_doc, l_def, l_ws,
                               g_table_cache(p_doc)(p_table_ref).data(r));
        END LOOP;
        RETURN l_hdr_h + l_row_h;
      ELSE
        l_row_h := row_height(l_def.col_defs(l_def.col_defs.FIRST).data_fmt,
                               l_def.options.t_row_height);
      END IF;
    ELSE
      l_hdr_h := 14;
      l_row_h := 12;
    END IF;
    RETURN l_hdr_h + l_row_nr * l_row_h;
  END measure_table;

-- ---------------------------------------------------------------------------
-- draw_table: draw header + data rows using cached data.
-- p_y = upper edge of first row.
-- ---------------------------------------------------------------------------
  PROCEDURE draw_table(p_doc       IN rad_pdf_types.t_doc_handle,
                       p_table_ref IN PLS_INTEGER,
                       p_x         IN NUMBER,
                       p_y         IN NUMBER,
                       p_width     IN NUMBER) IS
    l_def        rad_pdf_types.t_table_def;
    l_ws         rad_pdf_types.t_number_list;
    l_cur_y      NUMBER := p_y;
    l_h          NUMBER;
    l_row        t_row_values;
    l_row_nr     PLS_INTEGER;
    l_frame_y    NUMBER;
    l_margin_bot NUMBER;
    l_do_wrap    BOOLEAN;
  BEGIN
    l_def := rad_pdf_layout.get_table_def(p_doc, p_table_ref);
    IF l_def.col_defs IS NULL OR l_def.col_defs.COUNT = 0 THEN RETURN; END IF;
    IF NOT g_table_cache.EXISTS(p_doc) THEN RETURN; END IF;
    IF NOT g_table_cache(p_doc).EXISTS(p_table_ref) THEN RETURN; END IF;

    l_ws         := col_widths(l_def.col_defs, p_width, NVL(l_def.options.unit, 'pt'));
    l_frame_y    := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_page_height)
                    - rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_top);
    l_margin_bot := rad_pdf_canvas.get_info(p_doc, rad_pdf_types.c_info_margin_bot);
    l_do_wrap    := has_wrap_cols(l_def);

    -- Header row
    l_h     := draw_header_row(p_doc, l_def, l_ws, p_x, l_cur_y);
    l_cur_y := l_cur_y - l_h;

    -- Data rows
    l_row_nr := 1;
    WHILE l_row_nr <= g_table_cache(p_doc)(p_table_ref).row_count LOOP
      l_row := g_table_cache(p_doc)(p_table_ref).data(l_row_nr);
      -- Compute row height (dynamic when any column wraps)
      IF l_do_wrap THEN
        l_h := wrapped_row_height(p_doc, l_def, l_ws, l_row);
      ELSE
        l_h := row_height(l_def.col_defs(l_def.col_defs.FIRST).data_fmt,
                          l_def.options.t_row_height);
      END IF;
      -- Page break if row doesn't fit
      IF l_cur_y - l_h < l_margin_bot THEN
        rad_pdf_canvas.new_page(p_doc);
        l_cur_y := l_frame_y;
        -- Repeat header on new page
        l_h     := draw_header_row(p_doc, l_def, l_ws, p_x, l_cur_y);
        l_cur_y := l_cur_y - l_h;
        -- Recompute row height after header (font state may have changed)
        IF l_do_wrap THEN
          l_h := wrapped_row_height(p_doc, l_def, l_ws, l_row);
        ELSE
          l_h := row_height(l_def.col_defs(l_def.col_defs.FIRST).data_fmt,
                            l_def.options.t_row_height);
        END IF;
      END IF;
      l_h      := draw_data_row(p_doc, l_def, l_ws, l_row, l_row_nr, p_x, l_cur_y, l_h);
      l_cur_y  := l_cur_y - l_h;
      l_row_nr := l_row_nr + 1;
    END LOOP;
  END draw_table;

-- ---------------------------------------------------------------------------
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    IF g_table_cache.EXISTS(p_doc) THEN
      g_table_cache.DELETE(p_doc);
    END IF;
  END close_doc;

END rad_pdf_table;
/
