CREATE OR REPLACE PACKAGE BODY rad_pdf_canvas IS
/*
  rad_pdf_canvas body — Phase 6 of the RAD_PDF modular refactoring.

  Coordinate system: PDF origin = lower-left.  y increases upward.
  All internal positions are in points (1 pt = 1/72 inch).

  Page proc tokens:
    #PAGE_NR#     replaced with 1-based page number
    #PAGE_COUNT#  replaced with total page count
    #DOC_HANDLE#  replaced with the numeric doc handle value
*/

-- ---------------------------------------------------------------------------
-- Private state types
-- ---------------------------------------------------------------------------
  TYPE t_page_prcs_tab IS TABLE OF CLOB INDEX BY PLS_INTEGER;

  TYPE t_canvas_state IS RECORD (
    x          NUMBER               := 0,
    y          NUMBER               := 0,
    font_idx   PLS_INTEGER          := 1,
    font_size  NUMBER               := 10,
    fcolor     rad_pdf_types.t_rgb      := '000000',
    bcolor     rad_pdf_types.t_rgb      := 'ffffff',
    fmt        rad_pdf_types.t_page_format,   -- defaults: A4 595.276 × 841.890
    margins    rad_pdf_types.t_margins,       -- defaults: top=85, left=28, bot=113, right=28
    page_prcs  t_page_prcs_tab
  );

  TYPE t_canvas_map IS TABLE OF t_canvas_state INDEX BY PLS_INTEGER;
  g_canvas t_canvas_map;

-- ---------------------------------------------------------------------------
-- PRIVATE: ensure canvas state exists for this handle
-- ---------------------------------------------------------------------------
  PROCEDURE ensure_state(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_s t_canvas_state;
  BEGIN
    IF NOT g_canvas.EXISTS(p_doc) THEN
      -- All fields get type-level defaults; override non-defaulted ones:
      l_s.font_idx  := 1;        -- Helvetica N
      l_s.font_size := 10;
      l_s.fcolor    := '000000';
      l_s.bcolor    := 'ffffff';
      -- fmt.width/height get A4 defaults from rad_pdf_types.t_page_format
      -- margins get cm-based defaults from rad_pdf_types.t_margins
      g_canvas(p_doc) := l_s;
    END IF;
  END ensure_state;

-- ---------------------------------------------------------------------------
-- PRIVATE: unit-to-pt conversion with NULL passthrough
-- ---------------------------------------------------------------------------
  FUNCTION u2pt(p_val IN NUMBER, p_unit IN rad_pdf_types.t_unit) RETURN NUMBER IS
  BEGIN
    IF p_val IS NULL THEN RETURN NULL; END IF;
    RETURN rad_pdf_units.to_pt(p_val, p_unit);
  END u2pt;

-- ---------------------------------------------------------------------------
-- PRIVATE: emit a path-operator block: q ... op Q
--   p_ops:   the interior ops (color, width, path commands)
--   p_op:    final path paint operator: 'f','S','B','n'
-- ---------------------------------------------------------------------------
  PROCEDURE emit_path(p_doc IN rad_pdf_types.t_doc_handle,
                      p_ops IN VARCHAR2,
                      p_op  IN VARCHAR2) IS
    c_nl CONSTANT VARCHAR2(1) := CHR(10);
  BEGIN
    rad_pdf_serial.page_write(p_doc, 'q' || c_nl);
    rad_pdf_serial.page_write(p_doc, p_ops);
    rad_pdf_serial.page_write(p_doc, c_nl);
    rad_pdf_serial.page_write(p_doc, p_op || c_nl);
    rad_pdf_serial.page_write(p_doc, 'Q' || c_nl);
  END emit_path;

-- ---------------------------------------------------------------------------
-- PRIVATE: build color+linewidth preamble for graphics operators
-- ---------------------------------------------------------------------------
  FUNCTION gfx_setup(p_line_color IN rad_pdf_types.t_rgb,
                     p_fill_color IN rad_pdf_types.t_rgb,
                     p_line_width IN NUMBER) RETURN VARCHAR2 IS
    l_s VARCHAR2(200) := '';
  BEGIN
    IF p_line_color IS NOT NULL THEN
      l_s := rad_pdf_codec.fmt(p_line_width, 3) || ' w' || CHR(10) ||
             rad_pdf_codec.rgb_to_pdf(p_line_color) || ' RG' || CHR(10);
    END IF;
    IF p_fill_color IS NOT NULL THEN
      l_s := l_s || rad_pdf_codec.rgb_to_pdf(p_fill_color) || ' rg' || CHR(10);
    END IF;
    RETURN l_s;
  END gfx_setup;

-- ---------------------------------------------------------------------------
-- PRIVATE: choose PDF paint operator based on which colors are set
-- ---------------------------------------------------------------------------
  FUNCTION paint_op(p_line_color IN rad_pdf_types.t_rgb,
                    p_fill_color IN rad_pdf_types.t_rgb) RETURN VARCHAR2 IS
  BEGIN
    IF p_line_color IS NOT NULL AND p_fill_color IS NOT NULL THEN RETURN 'B';
    ELSIF p_fill_color IS NOT NULL THEN RETURN 'f';
    ELSIF p_line_color IS NOT NULL THEN RETURN 'S';
    ELSE RETURN 'n';
    END IF;
  END paint_op;

-- ---------------------------------------------------------------------------
-- Page lifecycle
-- ---------------------------------------------------------------------------
  PROCEDURE new_page(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    rad_pdf_serial.new_page(p_doc);
    -- Reset cursor to top-left content area
    g_canvas(p_doc).x := g_canvas(p_doc).margins.left;
    g_canvas(p_doc).y := g_canvas(p_doc).fmt.height - g_canvas(p_doc).margins.top;
  END new_page;

-- ---------------------------------------------------------------------------
  PROCEDURE goto_page(p_doc IN rad_pdf_types.t_doc_handle, p_page_nr IN PLS_INTEGER) IS
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    rad_pdf_serial.goto_page(p_doc, p_page_nr);
  END goto_page;

-- ---------------------------------------------------------------------------
-- Page geometry
-- ---------------------------------------------------------------------------
  PROCEDURE set_page_format(p_doc IN rad_pdf_types.t_doc_handle,
                            p_fmt IN rad_pdf_types.t_page_format) IS
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    g_canvas(p_doc).fmt := p_fmt;
  END set_page_format;

-- ---------------------------------------------------------------------------
  PROCEDURE set_margins(p_doc     IN rad_pdf_types.t_doc_handle,
                        p_margins IN rad_pdf_types.t_margins) IS
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    g_canvas(p_doc).margins := p_margins;
  END set_margins;

-- ---------------------------------------------------------------------------
-- Font and colour
-- ---------------------------------------------------------------------------
  PROCEDURE set_font(p_doc    IN rad_pdf_types.t_doc_handle,
                     p_family IN VARCHAR2,
                     p_style  IN rad_pdf_types.t_font_style DEFAULT 'N',
                     p_size   IN NUMBER DEFAULT NULL) IS
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    g_canvas(p_doc).font_idx := rad_pdf_fonts.find_font(p_doc, p_family, p_style);
    IF p_size IS NOT NULL THEN
      g_canvas(p_doc).font_size := p_size;
    END IF;
  END set_font;

-- ---------------------------------------------------------------------------
  PROCEDURE set_font(p_doc      IN rad_pdf_types.t_doc_handle,
                     p_font_idx IN PLS_INTEGER,
                     p_size     IN NUMBER DEFAULT NULL) IS
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    IF NOT rad_pdf_fonts.font_exists(p_font_idx) THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_font,
        'rad_pdf_canvas.set_font: font index ' || p_font_idx || ' does not exist', TRUE);
    END IF;
    g_canvas(p_doc).font_idx := p_font_idx;
    IF p_size IS NOT NULL THEN
      g_canvas(p_doc).font_size := p_size;
    END IF;
  END set_font;

-- ---------------------------------------------------------------------------
  PROCEDURE set_color(p_doc IN rad_pdf_types.t_doc_handle,
                      p_rgb IN rad_pdf_types.t_rgb DEFAULT '000000') IS
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    rad_pdf_units.assert_rgb(p_rgb);
    g_canvas(p_doc).fcolor := p_rgb;
  END set_color;

-- ---------------------------------------------------------------------------
  PROCEDURE set_bk_color(p_doc IN rad_pdf_types.t_doc_handle,
                         p_rgb IN rad_pdf_types.t_rgb DEFAULT 'ffffff') IS
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    rad_pdf_units.assert_rgb(p_rgb);
    g_canvas(p_doc).bcolor := p_rgb;
  END set_bk_color;

-- ---------------------------------------------------------------------------
-- PRIVATE: build PDF text block for a single string at absolute position
-- ---------------------------------------------------------------------------
  FUNCTION text_block(p_text     IN VARCHAR2,
                      p_x        IN NUMBER,
                      p_y        IN NUMBER,
                      p_font_idx IN PLS_INTEGER,
                      p_font_size IN NUMBER,
                      p_fcolor   IN rad_pdf_types.t_rgb,
                      p_rotation IN NUMBER DEFAULT NULL) RETURN VARCHAR2 IS
    l_co   NUMBER := 1;
    l_si   NUMBER := 0;
    c_pi   CONSTANT NUMBER := 3.14159265358979;
  BEGIN
    IF p_rotation IS NOT NULL AND p_rotation != 0 THEN
      l_co := COS(p_rotation * c_pi / 180);
      l_si := SIN(p_rotation * c_pi / 180);
    END IF;
    RETURN
      'BT'                                                              || CHR(10) ||
      '/F' || TO_CHAR(p_font_idx) || ' '
           || rad_pdf_codec.fmt(p_font_size, 2) || ' Tf'                  || CHR(10) ||
      rad_pdf_codec.rgb_to_pdf(p_fcolor) || ' rg'                          || CHR(10) ||
      rad_pdf_codec.fmt(l_co, 6) || ' ' || rad_pdf_codec.fmt(l_si, 6) || ' '
      || rad_pdf_codec.fmt(-l_si, 6) || ' ' || rad_pdf_codec.fmt(l_co, 6) || ' '
      || rad_pdf_codec.fmt(p_x, 2) || ' ' || rad_pdf_codec.fmt(p_y, 2) || ' Tm' || CHR(10) ||
      rad_pdf_fonts.text_to_pdf_string(p_text, p_font_idx) || ' Tj'        || CHR(10) ||
      'ET';
  END text_block;

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------
  PROCEDURE write_text(p_doc      IN rad_pdf_types.t_doc_handle,
                       p_text     IN VARCHAR2,
                       p_x        IN NUMBER,
                       p_y        IN NUMBER,
                       p_unit     IN rad_pdf_types.t_unit DEFAULT 'pt',
                       p_rotation IN NUMBER           DEFAULT NULL) IS
    l_x  NUMBER := u2pt(p_x, p_unit);
    l_y  NUMBER := u2pt(p_y, p_unit);
    l_fi PLS_INTEGER;
    l_fs NUMBER;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    IF p_text IS NULL OR LENGTH(p_text) = 0 THEN RETURN; END IF;
    l_fi := g_canvas(p_doc).font_idx;
    l_fs := g_canvas(p_doc).font_size;
    rad_pdf_serial.page_write(p_doc,
      text_block(p_text, l_x, l_y, l_fi, l_fs, g_canvas(p_doc).fcolor, p_rotation));
    rad_pdf_fonts.mark_font_used(p_doc, l_fi);
    g_canvas(p_doc).x := l_x + rad_pdf_fonts.text_width(p_text, l_fi, l_fs);
    g_canvas(p_doc).y := l_y;
  END write_text;

-- ---------------------------------------------------------------------------
  FUNCTION text_width(p_doc  IN rad_pdf_types.t_doc_handle,
                      p_text IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    ensure_state(p_doc);
    RETURN rad_pdf_fonts.text_width(p_text,
                                g_canvas(p_doc).font_idx,
                                g_canvas(p_doc).font_size);
  END text_width;

-- ---------------------------------------------------------------------------
  FUNCTION measure_wrapped(p_doc     IN rad_pdf_types.t_doc_handle,
                           p_text    IN VARCHAR2,
                           p_width   IN NUMBER,
                           p_unit    IN rad_pdf_types.t_unit DEFAULT 'pt',
                           p_leading IN NUMBER          DEFAULT NULL)
    RETURN NUMBER IS
    l_w       NUMBER;
    l_lead    NUMBER;
    l_fi      PLS_INTEGER;
    l_fs      NUMBER;
    l_pos     PLS_INTEGER := 1;
    l_len     PLS_INTEGER;
    l_ws      PLS_INTEGER;
    l_word    VARCHAR2(32767);
    l_line    VARCHAR2(32767) := '';
    l_tw      NUMBER;
    l_lines   PLS_INTEGER    := 0;
  BEGIN
    ensure_state(p_doc);
    IF p_text IS NULL OR LENGTH(p_text) = 0 THEN RETURN 0; END IF;
    l_fi   := g_canvas(p_doc).font_idx;
    l_fs   := g_canvas(p_doc).font_size;
    l_w    := CASE WHEN p_width IS NULL
                   THEN g_canvas(p_doc).fmt.width
                        - g_canvas(p_doc).margins.right - g_canvas(p_doc).margins.left
                   ELSE u2pt(p_width, p_unit) END;
    l_lead := NVL(p_leading, l_fs * 1.2);
    l_len  := LENGTH(p_text);
    WHILE l_pos <= l_len LOOP
      WHILE l_pos <= l_len AND SUBSTR(p_text, l_pos, 1) = ' ' LOOP
        l_pos := l_pos + 1;
      END LOOP;
      EXIT WHEN l_pos > l_len;
      l_ws := l_pos;
      WHILE l_pos <= l_len AND SUBSTR(p_text, l_pos, 1) != ' ' LOOP
        l_pos := l_pos + 1;
      END LOOP;
      l_word := SUBSTR(p_text, l_ws, l_pos - l_ws);
      IF l_line IS NULL OR LENGTH(l_line) = 0 THEN
        l_line := l_word;
      ELSE
        l_tw := rad_pdf_fonts.text_width(l_line || ' ' || l_word, l_fi, l_fs);
        IF l_tw > l_w THEN
          l_lines := l_lines + 1;
          l_line  := l_word;
        ELSE
          l_line  := l_line || ' ' || l_word;
        END IF;
      END IF;
    END LOOP;
    IF l_line IS NOT NULL AND LENGTH(l_line) > 0 THEN
      l_lines := l_lines + 1;
    END IF;
    RETURN l_lines * l_lead;
  END measure_wrapped;

-- ---------------------------------------------------------------------------
  PROCEDURE write_wrapped(p_doc     IN rad_pdf_types.t_doc_handle,
                          p_text    IN VARCHAR2,
                          p_x       IN NUMBER              DEFAULT NULL,
                          p_y       IN NUMBER              DEFAULT NULL,
                          p_width   IN NUMBER              DEFAULT NULL,
                          p_align   IN rad_pdf_types.t_align_h DEFAULT 'L',
                          p_unit    IN rad_pdf_types.t_unit    DEFAULT 'pt',
                          p_leading IN NUMBER              DEFAULT NULL) IS
    l_x       NUMBER;
    l_y       NUMBER;
    l_w       NUMBER;
    l_lead    NUMBER;
    l_fi      PLS_INTEGER;
    l_fs      NUMBER;
    -- Word-wrap locals
    l_pos     PLS_INTEGER := 1;
    l_len     PLS_INTEGER;
    l_ws      PLS_INTEGER;   -- word start
    l_we      PLS_INTEGER;   -- word end
    l_word    VARCHAR2(32767);
    l_line    VARCHAR2(32767) := '';
    l_tw      NUMBER;        -- text width of current line candidate
    l_lw      NUMBER;        -- finalized line width
    l_off_x   NUMBER;        -- horizontal offset for alignment
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    IF p_text IS NULL OR LENGTH(p_text) = 0 THEN RETURN; END IF;

    l_fi := g_canvas(p_doc).font_idx;
    l_fs := g_canvas(p_doc).font_size;

    l_x := CASE WHEN p_x IS NULL THEN g_canvas(p_doc).x
                ELSE u2pt(p_x, p_unit) END;
    l_y := CASE WHEN p_y IS NULL THEN g_canvas(p_doc).y
                ELSE u2pt(p_y, p_unit) END;
    l_w := CASE WHEN p_width IS NULL
                THEN g_canvas(p_doc).fmt.width
                     - g_canvas(p_doc).margins.right - l_x
                ELSE u2pt(p_width, p_unit) END;
    l_lead := NVL(p_leading, l_fs * 1.2);

    l_len := LENGTH(p_text);

    -- Iterate words, building lines that fit within l_w
    WHILE l_pos <= l_len LOOP
      -- Skip spaces
      WHILE l_pos <= l_len AND SUBSTR(p_text, l_pos, 1) = ' ' LOOP
        l_pos := l_pos + 1;
      END LOOP;
      EXIT WHEN l_pos > l_len;

      -- Extract next word
      l_ws := l_pos;
      WHILE l_pos <= l_len AND SUBSTR(p_text, l_pos, 1) != ' ' LOOP
        l_pos := l_pos + 1;
      END LOOP;
      l_word := SUBSTR(p_text, l_ws, l_pos - l_ws);

      -- Would adding this word exceed the line width?
      IF l_line IS NULL OR LENGTH(l_line) = 0 THEN
        l_tw := rad_pdf_fonts.text_width(l_word, l_fi, l_fs);
        IF l_tw > l_w THEN
          -- Single word wider than line: emit it alone (no split)
          l_line := l_word;
        ELSE
          l_line := l_word;
        END IF;
      ELSE
        l_tw := rad_pdf_fonts.text_width(l_line || ' ' || l_word, l_fi, l_fs);
        IF l_tw > l_w THEN
          -- Emit current line, start new with this word
          l_lw  := rad_pdf_fonts.text_width(l_line, l_fi, l_fs);
          l_off_x := CASE p_align
                       WHEN 'R' THEN l_x + (l_w - l_lw)
                       WHEN 'C' THEN l_x + (l_w - l_lw) / 2
                       ELSE l_x
                     END;
          rad_pdf_serial.page_write(p_doc,
            text_block(l_line, l_off_x, l_y, l_fi, l_fs, g_canvas(p_doc).fcolor));
          rad_pdf_fonts.mark_font_used(p_doc, l_fi);
          l_y    := l_y - l_lead;
          l_line := l_word;
        ELSE
          l_line := l_line || ' ' || l_word;
        END IF;
      END IF;
    END LOOP;

    -- Emit last (or only) line
    IF l_line IS NOT NULL AND LENGTH(l_line) > 0 THEN
      l_lw  := rad_pdf_fonts.text_width(l_line, l_fi, l_fs);
      l_off_x := CASE p_align
                   WHEN 'R' THEN l_x + (l_w - l_lw)
                   WHEN 'C' THEN l_x + (l_w - l_lw) / 2
                   ELSE l_x
                 END;
      rad_pdf_serial.page_write(p_doc,
        text_block(l_line, l_off_x, l_y, l_fi, l_fs, g_canvas(p_doc).fcolor));
      rad_pdf_fonts.mark_font_used(p_doc, l_fi);
      l_y := l_y - l_lead;
    END IF;

    g_canvas(p_doc).x := l_x;
    g_canvas(p_doc).y := l_y;
  END write_wrapped;

-- ---------------------------------------------------------------------------
-- Graphics
-- ---------------------------------------------------------------------------
  PROCEDURE line(p_doc   IN rad_pdf_types.t_doc_handle,
                 p_x1    IN NUMBER,
                 p_y1    IN NUMBER,
                 p_x2    IN NUMBER,
                 p_y2    IN NUMBER,
                 p_color IN rad_pdf_types.t_rgb  DEFAULT '000000',
                 p_width IN NUMBER           DEFAULT 0.5,
                 p_unit  IN rad_pdf_types.t_unit DEFAULT 'pt') IS
    l_x1 NUMBER := u2pt(p_x1, p_unit);
    l_y1 NUMBER := u2pt(p_y1, p_unit);
    l_x2 NUMBER := u2pt(p_x2, p_unit);
    l_y2 NUMBER := u2pt(p_y2, p_unit);
    l_pw NUMBER := u2pt(p_width, p_unit);
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    emit_path(p_doc,
      rad_pdf_codec.fmt(l_pw, 3) || ' w'                           || CHR(10) ||
      rad_pdf_codec.rgb_to_pdf(p_color) || ' RG'                   || CHR(10) ||
      rad_pdf_codec.fmt(l_x1, 2) || ' ' || rad_pdf_codec.fmt(l_y1, 2) || ' m' || CHR(10) ||
      rad_pdf_codec.fmt(l_x2, 2) || ' ' || rad_pdf_codec.fmt(l_y2, 2) || ' l',
      'S');
  END line;

-- ---------------------------------------------------------------------------
  PROCEDURE h_line(p_doc        IN rad_pdf_types.t_doc_handle,
                   p_x          IN NUMBER,
                   p_y          IN NUMBER,
                   p_width      IN NUMBER,
                   p_line_width IN NUMBER           DEFAULT 0.5,
                   p_color      IN rad_pdf_types.t_rgb  DEFAULT '000000',
                   p_unit       IN rad_pdf_types.t_unit DEFAULT 'pt') IS
    l_x  NUMBER := u2pt(p_x, p_unit);
    l_y  NUMBER := u2pt(p_y, p_unit);
    l_w  NUMBER := u2pt(p_width, p_unit);
    l_lw NUMBER := u2pt(p_line_width, p_unit);
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    emit_path(p_doc,
      rad_pdf_codec.fmt(l_lw, 3) || ' w'                         || CHR(10) ||
      rad_pdf_codec.rgb_to_pdf(p_color) || ' RG'                 || CHR(10) ||
      rad_pdf_codec.fmt(l_x, 2) || ' '   || rad_pdf_codec.fmt(l_y, 2) || ' m' || CHR(10) ||
      rad_pdf_codec.fmt(l_x + l_w, 2) || ' ' || rad_pdf_codec.fmt(l_y, 2) || ' l',
      'S');
  END h_line;

-- ---------------------------------------------------------------------------
  PROCEDURE v_line(p_doc        IN rad_pdf_types.t_doc_handle,
                   p_x          IN NUMBER,
                   p_y          IN NUMBER,
                   p_height     IN NUMBER,
                   p_line_width IN NUMBER           DEFAULT 0.5,
                   p_color      IN rad_pdf_types.t_rgb  DEFAULT '000000',
                   p_unit       IN rad_pdf_types.t_unit DEFAULT 'pt') IS
    l_x  NUMBER := u2pt(p_x, p_unit);
    l_y  NUMBER := u2pt(p_y, p_unit);
    l_h  NUMBER := u2pt(p_height, p_unit);
    l_lw NUMBER := u2pt(p_line_width, p_unit);
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    emit_path(p_doc,
      rad_pdf_codec.fmt(l_lw, 3) || ' w'                         || CHR(10) ||
      rad_pdf_codec.rgb_to_pdf(p_color) || ' RG'                 || CHR(10) ||
      rad_pdf_codec.fmt(l_x, 2) || ' '   || rad_pdf_codec.fmt(l_y, 2) || ' m' || CHR(10) ||
      rad_pdf_codec.fmt(l_x, 2) || ' '   || rad_pdf_codec.fmt(l_y - l_h, 2) || ' l',
      'S');
  END v_line;

-- ---------------------------------------------------------------------------
  PROCEDURE rect(p_doc        IN rad_pdf_types.t_doc_handle,
                 p_x          IN NUMBER,
                 p_y          IN NUMBER,
                 p_width      IN NUMBER,
                 p_height     IN NUMBER,
                 p_line_color IN rad_pdf_types.t_rgb  DEFAULT NULL,
                 p_fill_color IN rad_pdf_types.t_rgb  DEFAULT NULL,
                 p_line_width IN NUMBER           DEFAULT 0.5,
                 p_unit       IN rad_pdf_types.t_unit DEFAULT 'pt') IS
    l_x  NUMBER := u2pt(p_x,          p_unit);
    l_y  NUMBER := u2pt(p_y,          p_unit);
    l_w  NUMBER := u2pt(p_width,      p_unit);
    l_h  NUMBER := u2pt(p_height,     p_unit);
    l_lw NUMBER := u2pt(p_line_width, p_unit);
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    IF p_line_color IS NULL AND p_fill_color IS NULL THEN RETURN; END IF;
    emit_path(p_doc,
      gfx_setup(p_line_color, p_fill_color, l_lw) ||
      rad_pdf_codec.fmt(l_x, 2) || ' ' || rad_pdf_codec.fmt(l_y, 2) || ' ' ||
      rad_pdf_codec.fmt(l_w, 2) || ' ' || rad_pdf_codec.fmt(l_h, 2) || ' re',
      paint_op(p_line_color, p_fill_color));
  END rect;

-- ---------------------------------------------------------------------------
  PROCEDURE polygon(p_doc        IN rad_pdf_types.t_doc_handle,
                    p_xs         IN rad_pdf_types.t_number_list,
                    p_ys         IN rad_pdf_types.t_number_list,
                    p_line_color IN rad_pdf_types.t_rgb DEFAULT '000000',
                    p_fill_color IN rad_pdf_types.t_rgb DEFAULT NULL,
                    p_line_width IN NUMBER          DEFAULT 0.5) IS
    l_n   PLS_INTEGER := p_xs.COUNT;
    l_ops VARCHAR2(32767);
    l_i   PLS_INTEGER;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    IF l_n < 2 THEN RETURN; END IF;
    l_ops := gfx_setup(p_line_color, p_fill_color, p_line_width);
    l_i   := p_xs.FIRST;
    l_ops := l_ops ||
             rad_pdf_codec.fmt(p_xs(l_i), 2) || ' ' || rad_pdf_codec.fmt(p_ys(l_i), 2) || ' m' || CHR(10);
    l_i   := p_xs.NEXT(l_i);
    WHILE l_i IS NOT NULL LOOP
      l_ops := l_ops ||
               rad_pdf_codec.fmt(p_xs(l_i), 2) || ' ' || rad_pdf_codec.fmt(p_ys(l_i), 2) || ' l' || CHR(10);
      l_i := p_xs.NEXT(l_i);
    END LOOP;
    l_ops := l_ops || 'h';
    emit_path(p_doc, l_ops, paint_op(p_line_color, p_fill_color));
  END polygon;

-- ---------------------------------------------------------------------------
  PROCEDURE path(p_doc        IN rad_pdf_types.t_doc_handle,
                 p_path       IN rad_pdf_types.t_path,
                 p_line_color IN rad_pdf_types.t_rgb DEFAULT '000000',
                 p_fill_color IN rad_pdf_types.t_rgb DEFAULT NULL,
                 p_line_width IN NUMBER          DEFAULT 0.5) IS
    l_ops VARCHAR2(32767);
    l_i   PLS_INTEGER;
    l_e   rad_pdf_types.t_path_element;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    IF p_path.COUNT = 0 THEN RETURN; END IF;
    l_ops := gfx_setup(p_line_color, p_fill_color, p_line_width);
    l_i   := p_path.FIRST;
    WHILE l_i IS NOT NULL LOOP
      l_e := p_path(l_i);
      CASE l_e.element_type
        WHEN rad_pdf_types.c_move_to THEN
          l_ops := l_ops ||
                   rad_pdf_codec.fmt(l_e.x1, 2) || ' ' || rad_pdf_codec.fmt(l_e.y1, 2) || ' m' || CHR(10);
        WHEN rad_pdf_types.c_line_to THEN
          l_ops := l_ops ||
                   rad_pdf_codec.fmt(l_e.x1, 2) || ' ' || rad_pdf_codec.fmt(l_e.y1, 2) || ' l' || CHR(10);
        WHEN rad_pdf_types.c_curve_to THEN
          l_ops := l_ops ||
                   rad_pdf_codec.fmt(l_e.x1, 2) || ' ' || rad_pdf_codec.fmt(l_e.y1, 2) || ' ' ||
                   rad_pdf_codec.fmt(l_e.x2, 2) || ' ' || rad_pdf_codec.fmt(l_e.y2, 2) || ' ' ||
                   rad_pdf_codec.fmt(l_e.x3, 2) || ' ' || rad_pdf_codec.fmt(l_e.y3, 2) || ' c' || CHR(10);
        WHEN rad_pdf_types.c_close THEN
          l_ops := l_ops || 'h' || CHR(10);
        ELSE NULL;
      END CASE;
      l_i := p_path.NEXT(l_i);
    END LOOP;
    emit_path(p_doc, RTRIM(l_ops, CHR(10)), paint_op(p_line_color, p_fill_color));
  END path;

-- ---------------------------------------------------------------------------
-- Images
-- ---------------------------------------------------------------------------
  PROCEDURE put_image(p_doc      IN rad_pdf_types.t_doc_handle,
                      p_image_id IN PLS_INTEGER,
                      p_x        IN NUMBER,
                      p_y        IN NUMBER,
                      p_width    IN NUMBER              DEFAULT NULL,
                      p_height   IN NUMBER              DEFAULT NULL,
                      p_align    IN rad_pdf_types.t_align_h DEFAULT 'L',
                      p_valign   IN rad_pdf_types.t_align_v DEFAULT 'T',
                      p_unit     IN rad_pdf_types.t_unit    DEFAULT 'pt') IS
    l_x      NUMBER := u2pt(p_x, p_unit);
    l_y      NUMBER := u2pt(p_y, p_unit);
    l_w      NUMBER;
    l_h      NUMBER;
    l_img_w  NUMBER;
    l_img_h  NUMBER;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);

    rad_pdf_images.get_image_dimensions(p_doc, p_image_id, l_img_w, l_img_h);

    IF p_width IS NULL AND p_height IS NULL THEN
      l_w := l_img_w;
      l_h := l_img_h;
    ELSIF p_height IS NULL THEN
      l_w := u2pt(p_width, p_unit);
      l_h := CASE WHEN l_img_w > 0 THEN l_w * l_img_h / l_img_w ELSE l_w END;
    ELSIF p_width IS NULL THEN
      l_h := u2pt(p_height, p_unit);
      l_w := CASE WHEN l_img_h > 0 THEN l_h * l_img_w / l_img_h ELSE l_h END;
    ELSE
      l_w := u2pt(p_width,  p_unit);
      l_h := u2pt(p_height, p_unit);
    END IF;

    -- Horizontal alignment origin adjustment
    CASE NVL(p_align, 'L')
      WHEN 'C' THEN l_x := l_x - l_w / 2;
      WHEN 'R' THEN l_x := l_x - l_w;
      ELSE NULL;
    END CASE;

    -- Vertical alignment: PDF y is bottom-left of image
    CASE NVL(p_valign, 'T')
      WHEN 'M' THEN l_y := l_y - l_h / 2;
      WHEN 'B' THEN l_y := l_y - l_h;
      ELSE l_y := l_y - l_h;  -- 'T': caller gives top-left, PDF needs bottom-left
    END CASE;

    rad_pdf_serial.page_write(p_doc, 'q');
    rad_pdf_serial.page_write(p_doc,
      rad_pdf_codec.fmt(l_w, 2) || ' 0 0 ' || rad_pdf_codec.fmt(l_h, 2) || ' ' ||
      rad_pdf_codec.fmt(l_x, 2) || ' ' || rad_pdf_codec.fmt(l_y, 2) || ' cm');
    rad_pdf_serial.page_write(p_doc, '/Im' || TO_CHAR(p_image_id) || ' Do');
    rad_pdf_serial.page_write(p_doc, 'Q');
  END put_image;

-- ---------------------------------------------------------------------------
-- Page-procedure callbacks
-- ---------------------------------------------------------------------------
  PROCEDURE add_page_proc(p_doc IN rad_pdf_types.t_doc_handle, p_src IN VARCHAR2) IS
    l_c CLOB;
    l_n PLS_INTEGER := NVL(LENGTH(p_src), 0);
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    IF l_n = 0 THEN RETURN; END IF;
    DBMS_LOB.CREATETEMPORARY(l_c, TRUE, DBMS_LOB.SESSION);
    DBMS_LOB.WRITEAPPEND(l_c, l_n, p_src);
    g_canvas(p_doc).page_prcs(g_canvas(p_doc).page_prcs.COUNT) := l_c;
  END add_page_proc;

-- ---------------------------------------------------------------------------
  PROCEDURE add_page_proc(p_doc IN rad_pdf_types.t_doc_handle, p_src IN CLOB) IS
    l_c CLOB;
    l_n INTEGER := NVL(DBMS_LOB.GETLENGTH(p_src), 0);
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    IF l_n = 0 THEN RETURN; END IF;
    DBMS_LOB.CREATETEMPORARY(l_c, TRUE, DBMS_LOB.SESSION);
    DBMS_LOB.COPY(l_c, p_src, l_n);
    g_canvas(p_doc).page_prcs(g_canvas(p_doc).page_prcs.COUNT) := l_c;
  END add_page_proc;

-- ---------------------------------------------------------------------------
-- State queries
-- ---------------------------------------------------------------------------
  FUNCTION get_x(p_doc IN rad_pdf_types.t_doc_handle) RETURN NUMBER IS
  BEGIN
    ensure_state(p_doc);
    RETURN g_canvas(p_doc).x;
  END get_x;

-- ---------------------------------------------------------------------------
  FUNCTION get_y(p_doc IN rad_pdf_types.t_doc_handle) RETURN NUMBER IS
  BEGIN
    ensure_state(p_doc);
    RETURN g_canvas(p_doc).y;
  END get_y;

-- ---------------------------------------------------------------------------
  FUNCTION get_info(p_doc  IN rad_pdf_types.t_doc_handle,
                    p_what IN PLS_INTEGER) RETURN NUMBER IS
  BEGIN
    ensure_state(p_doc);
    CASE p_what
      WHEN rad_pdf_types.c_info_page_width  THEN RETURN g_canvas(p_doc).fmt.width;
      WHEN rad_pdf_types.c_info_page_height THEN RETURN g_canvas(p_doc).fmt.height;
      WHEN rad_pdf_types.c_info_margin_top  THEN RETURN g_canvas(p_doc).margins.top;
      WHEN rad_pdf_types.c_info_margin_right THEN RETURN g_canvas(p_doc).margins.right;
      WHEN rad_pdf_types.c_info_margin_bot  THEN RETURN g_canvas(p_doc).margins.bottom;
      WHEN rad_pdf_types.c_info_margin_left THEN RETURN g_canvas(p_doc).margins.left;
      WHEN rad_pdf_types.c_info_cursor_x    THEN RETURN g_canvas(p_doc).x;
      WHEN rad_pdf_types.c_info_cursor_y    THEN RETURN g_canvas(p_doc).y;
      WHEN rad_pdf_types.c_info_font_size   THEN RETURN g_canvas(p_doc).font_size;
      WHEN rad_pdf_types.c_info_font_idx    THEN RETURN g_canvas(p_doc).font_idx;
      WHEN rad_pdf_types.c_info_page_count  THEN RETURN rad_pdf_serial.page_count(p_doc);
      WHEN rad_pdf_types.c_info_page_nr     THEN RETURN rad_pdf_serial.current_page(p_doc) + 1;
      ELSE RETURN NULL;
    END CASE;
  END get_info;

-- ---------------------------------------------------------------------------
-- run_page_procs — execute callbacks for each page (called after render pass)
-- ---------------------------------------------------------------------------
  PROCEDURE run_page_procs(p_doc   IN rad_pdf_types.t_doc_handle,
                           p_total IN PLS_INTEGER) IS
    l_src  CLOB;
    l_tmp  CLOB;
    l_n    PLS_INTEGER;
    l_pi   PLS_INTEGER;
  BEGIN
    IF NOT g_canvas.EXISTS(p_doc) THEN RETURN; END IF;
    l_n := g_canvas(p_doc).page_prcs.COUNT;
    IF l_n = 0 OR NVL(p_total, 0) = 0 THEN
      rad_pdf_serial.page_flush(p_doc);
      RETURN;
    END IF;

    FOR pg IN 0 .. p_total - 1 LOOP
      rad_pdf_serial.goto_page(p_doc, pg);
      l_pi := g_canvas(p_doc).page_prcs.FIRST;
      WHILE l_pi IS NOT NULL LOOP
        -- Substitute tokens into a temporary CLOB
        l_src := g_canvas(p_doc).page_prcs(l_pi);
        DBMS_LOB.CREATETEMPORARY(l_tmp, TRUE, DBMS_LOB.SESSION);
        DBMS_LOB.COPY(l_tmp, l_src, DBMS_LOB.GETLENGTH(l_src));
        l_tmp := REPLACE(l_tmp, '#PAGE_NR#',    TO_CHAR(pg + 1));
        l_tmp := REPLACE(l_tmp, '#PAGE_COUNT#', TO_CHAR(p_total));
        l_tmp := REPLACE(l_tmp, '#DOC_HANDLE#', TO_CHAR(p_doc));
        EXECUTE IMMEDIATE l_tmp;
        DBMS_LOB.FREETEMPORARY(l_tmp);
        l_pi := g_canvas(p_doc).page_prcs.NEXT(l_pi);
      END LOOP;
    END LOOP;

    -- Flush last page proc content
    rad_pdf_serial.page_flush(p_doc);
  END run_page_procs;

-- ---------------------------------------------------------------------------
-- write_page_objects — write page tree to PDF (called at finalization)
-- ---------------------------------------------------------------------------
  FUNCTION write_page_objects(p_doc      IN rad_pdf_types.t_doc_handle,
                               p_font_res IN VARCHAR2,
                               p_img_res  IN VARCHAR2) RETURN NUMBER IS
    l_n        PLS_INTEGER;
    l_mb_w     NUMBER;
    l_mb_h     NUMBER;
    l_res      VARCHAR2(32767);
    l_kids     VARCHAR2(32767);
    l_blob     BLOB;
    l_base_nr  NUMBER;
    l_c_nr     NUMBER;
    l_dummy    NUMBER;
    l_pages_nr NUMBER;
    TYPE t_num_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    l_c_nrs  t_num_tab;  -- content stream obj numbers (0-indexed)
    l_p_nrs  t_num_tab;  -- page dict obj numbers (0-indexed)
  BEGIN
    -- Flush current page buffer
    rad_pdf_serial.page_flush(p_doc);

    l_n := rad_pdf_serial.page_count(p_doc);
    IF l_n = 0 THEN RETURN 0; END IF;

    l_mb_w := g_canvas(p_doc).fmt.width;
    l_mb_h := g_canvas(p_doc).fmt.height;

    -- Build resources dict
    l_res := '<</ProcSet [/PDF /Text /ImageB /ImageC /ImageI]';
    IF p_font_res IS NOT NULL THEN
      l_res := l_res || ' /Font <<' || p_font_res || '>>';
    END IF;
    IF p_img_res IS NOT NULL THEN
      l_res := l_res || ' /XObject <<' || p_img_res || '>>';
    END IF;
    l_res := l_res || '>>';

    -- Pass 1: write N content stream objects (pages are 0-indexed)
    FOR i IN 0 .. l_n - 1 LOOP
      l_blob := rad_pdf_serial.get_page_blob(p_doc, i);
      l_c_nr := rad_pdf_serial.write_stream_obj(p_doc, l_blob, NULL, FALSE);
      l_c_nrs(i) := l_c_nr;
      IF i = 0 THEN l_base_nr := l_c_nr; END IF;
    END LOOP;

    -- The Pages root will be at base_nr + 2*N
    l_pages_nr := l_base_nr + 2 * l_n;

    -- Pass 2: write N page dictionary objects
    FOR i IN 0 .. l_n - 1 LOOP
      l_dummy := rad_pdf_serial.begin_obj(p_doc,
        '/Type /Page' ||
        ' /Parent '   || TO_CHAR(l_pages_nr) || ' 0 R' ||
        ' /Resources ' || l_res ||
        ' /MediaBox [0 0 ' || rad_pdf_codec.fmt(l_mb_w, 2) ||
                       ' ' || rad_pdf_codec.fmt(l_mb_h, 2) || ']' ||
        ' /Contents ' || TO_CHAR(l_c_nrs(i)) || ' 0 R');
      l_p_nrs(i) := l_dummy;
    END LOOP;

    -- Pass 3: write Pages root
    l_kids := '[';
    FOR i IN 0 .. l_n - 1 LOOP
      l_kids := l_kids || TO_CHAR(l_p_nrs(i)) || ' 0 R ';
    END LOOP;
    l_kids := RTRIM(l_kids) || ']';

    l_dummy := rad_pdf_serial.begin_obj(p_doc,
      '/Type /Pages /Kids ' || l_kids || ' /Count ' || TO_CHAR(l_n));

    RETURN l_dummy;  -- = l_pages_nr
  END write_page_objects;

-- ---------------------------------------------------------------------------
-- close_doc — free all per-document canvas state
-- ---------------------------------------------------------------------------
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_i PLS_INTEGER;
  BEGIN
    IF NOT g_canvas.EXISTS(p_doc) THEN RETURN; END IF;
    l_i := g_canvas(p_doc).page_prcs.FIRST;
    WHILE l_i IS NOT NULL LOOP
      IF g_canvas(p_doc).page_prcs(l_i) IS NOT NULL AND
         DBMS_LOB.ISTEMPORARY(g_canvas(p_doc).page_prcs(l_i)) = 1 THEN
        DBMS_LOB.FREETEMPORARY(g_canvas(p_doc).page_prcs(l_i));
      END IF;
      l_i := g_canvas(p_doc).page_prcs.NEXT(l_i);
    END LOOP;
    g_canvas.DELETE(p_doc);
  END close_doc;

END rad_pdf_canvas;
/
