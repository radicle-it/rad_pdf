CREATE OR REPLACE PACKAGE BODY rad_pdf_styles IS
/*
  rad_pdf_styles body — session-scoped named style dictionary.
*/

  TYPE t_style_map IS TABLE OF rad_pdf_types.t_cell_format INDEX BY VARCHAR2(100);
  g_styles          t_style_map;
  g_defaults_loaded BOOLEAN := FALSE;

-- ---------------------------------------------------------------------------
  PROCEDURE load_defaults IS
    l_f rad_pdf_types.t_cell_format;

    PROCEDURE put(p_name IN VARCHAR2, p_fmt IN rad_pdf_types.t_cell_format) IS
    BEGIN
      g_styles(p_name) := p_fmt;
    END;
  BEGIN
    IF g_defaults_loaded THEN RETURN; END IF;

    -- 'default' / 'body'
    l_f := rad_pdf_units.default_cell_format;
    put('default', l_f);
    put('body',    l_f);

    -- 'h1'..'h6'
    l_f.font_style := 'B';
    l_f.font_size  := 18; put('h1', l_f);
    l_f.font_size  := 16; put('h2', l_f);
    l_f.font_size  := 14; put('h3', l_f);
    l_f.font_size  := 12; put('h4', l_f);
    l_f.font_size  := 11; put('h5', l_f);
    l_f.font_size  := 10; put('h6', l_f);

    -- 'caption'
    l_f            := rad_pdf_units.default_cell_format;
    l_f.font_style := 'I';
    l_f.font_size  := 8;
    l_f.font_color := '666666';
    put('caption', l_f);

    -- 'table_header'
    l_f            := rad_pdf_units.default_cell_format;
    l_f.font_style := 'B';
    l_f.font_size  := 9;
    l_f.font_color := 'ffffff';
    l_f.back_color := '003366';
    l_f.align_h    := 'C';
    l_f.border     := rad_pdf_types.c_border_bottom;
    put('table_header', l_f);

    -- 'table_even'
    l_f            := rad_pdf_units.default_cell_format;
    l_f.font_size  := 9;
    l_f.back_color := 'ffffff';
    put('table_even', l_f);

    -- 'table_odd'
    l_f            := rad_pdf_units.default_cell_format;
    l_f.font_size  := 9;
    l_f.back_color := 'd0d0d0';
    put('table_odd', l_f);

    -- 'label'
    l_f            := rad_pdf_units.default_cell_format;
    l_f.font_size  := 9;
    put('label', l_f);

    g_defaults_loaded := TRUE;
  END load_defaults;

-- ---------------------------------------------------------------------------
  PROCEDURE define(
    p_name       IN VARCHAR2,
    p_font_name  IN VARCHAR2               DEFAULT NULL,
    p_font_style IN rad_pdf_types.t_font_style DEFAULT NULL,
    p_font_size  IN NUMBER                 DEFAULT NULL,
    p_font_color IN rad_pdf_types.t_rgb        DEFAULT NULL,
    p_back_color IN rad_pdf_types.t_rgb        DEFAULT NULL,
    p_line_color IN rad_pdf_types.t_rgb        DEFAULT NULL,
    p_line_size  IN NUMBER                 DEFAULT NULL,
    p_border     IN rad_pdf_types.t_border_msk DEFAULT NULL,
    p_align_h    IN rad_pdf_types.t_align_h    DEFAULT NULL,
    p_align_v    IN rad_pdf_types.t_align_v    DEFAULT NULL,
    p_leading    IN NUMBER                 DEFAULT NULL,
    p_num_format IN VARCHAR2               DEFAULT NULL
  ) IS
    l_f rad_pdf_types.t_cell_format;
  BEGIN
    IF p_name IS NULL THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_styles.define: p_name cannot be NULL', TRUE);
    END IF;

    load_defaults;

    -- Start from the existing style if it already exists, otherwise from 'default'.
    IF g_styles.EXISTS(p_name) THEN
      l_f := g_styles(p_name);
    ELSIF g_styles.EXISTS('default') THEN
      l_f := g_styles('default');
    ELSE
      l_f := rad_pdf_units.default_cell_format;
    END IF;

    -- Apply only the non-NULL overrides.
    IF p_font_name  IS NOT NULL THEN l_f.font_name  := p_font_name;  END IF;
    IF p_font_style IS NOT NULL THEN l_f.font_style := p_font_style; END IF;
    IF p_font_size  IS NOT NULL THEN l_f.font_size  := p_font_size;  END IF;
    IF p_font_color IS NOT NULL THEN l_f.font_color := p_font_color; END IF;
    IF p_back_color IS NOT NULL THEN l_f.back_color := p_back_color; END IF;
    IF p_line_color IS NOT NULL THEN l_f.line_color := p_line_color; END IF;
    IF p_line_size  IS NOT NULL THEN l_f.line_size  := p_line_size;  END IF;
    IF p_border     IS NOT NULL THEN l_f.border     := p_border;     END IF;
    IF p_align_h    IS NOT NULL THEN l_f.align_h    := p_align_h;    END IF;
    IF p_align_v    IS NOT NULL THEN l_f.align_v    := p_align_v;    END IF;
    IF p_leading    IS NOT NULL THEN l_f.spacing    := TO_CHAR(p_leading) || 'pt'; END IF;
    IF p_num_format IS NOT NULL THEN l_f.num_format := p_num_format; END IF;

    g_styles(p_name) := l_f;
  END define;

-- ---------------------------------------------------------------------------
  FUNCTION get(p_name IN VARCHAR2) RETURN rad_pdf_types.t_cell_format IS
  BEGIN
    load_defaults;
    IF p_name IS NOT NULL AND g_styles.EXISTS(p_name) THEN
      RETURN g_styles(p_name);
    END IF;
    RETURN g_styles('default');
  END get;

-- ---------------------------------------------------------------------------
  FUNCTION exists_style(p_name IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    IF p_name IS NULL THEN RETURN FALSE; END IF;
    load_defaults;
    RETURN g_styles.EXISTS(p_name);
  END exists_style;

-- ---------------------------------------------------------------------------
  PROCEDURE drop_style(p_name IN VARCHAR2) IS
  BEGIN
    IF p_name IS NULL THEN RETURN; END IF;
    IF g_styles.EXISTS(p_name) THEN
      g_styles.DELETE(p_name);
    END IF;
  END drop_style;

-- ---------------------------------------------------------------------------
  PROCEDURE clear_all IS
  BEGIN
    g_styles.DELETE;
    g_defaults_loaded := FALSE;
  END clear_all;

-- ---------------------------------------------------------------------------
  FUNCTION default_scheme RETURN rad_pdf_types.t_color_scheme IS
    l_cs     rad_pdf_types.t_color_scheme;
    l_hdr    rad_pdf_types.t_cell_format;
    l_even   rad_pdf_types.t_cell_format;
    l_odd    rad_pdf_types.t_cell_format;
  BEGIN
    load_defaults;
    l_hdr  := get('table_header');
    l_even := get('table_even');
    l_odd  := get('table_odd');

    l_cs.header_ink    := l_hdr.font_color;
    l_cs.header_paper  := l_hdr.back_color;
    l_cs.header_border := l_hdr.line_color;
    l_cs.even_ink      := l_even.font_color;
    l_cs.even_paper    := l_even.back_color;
    l_cs.even_border   := l_even.line_color;
    l_cs.odd_ink       := l_odd.font_color;
    l_cs.odd_paper     := l_odd.back_color;
    l_cs.odd_border    := l_odd.line_color;

    RETURN l_cs;
  END default_scheme;

END rad_pdf_styles;
/
