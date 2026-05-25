CREATE OR REPLACE PACKAGE BODY rad_pdf_template IS
/*
  rad_pdf_template body — lightweight template engine for RAD_PDF.
  Oracle 19c+.  Phase 9.  AUTHID CURRENT_USER (inherited from spec).

  Block tags parsed by do_render (CLOB scanner):
    <p [style="..."]>...</p>
    <h1>...</h1>  ..  <h6>...</h6>
    <spacer [height="20pt"]/>
    <hr [color="cccccc"] [width="0.5"]/>
    <img id="N" [width="Xmm"] [height="Ymm"]/>
    <table columns="NAME" query="SELECT ..." allow_query="true"/>
    <pagebreak/>

  Inline tags inside <p> content (parsed by parse_inline):
    <b>...</b>    bold run  -> derives style variant p_style__b
    <i>...</i>    italic    -> derives style variant p_style__i
    <br/>         emits a 2pt spacer flowable

  Placeholder tokens substituted before parsing (bind path only):
    #KEY#  ->  bind value (case-insensitive on key)
    ##     ->  literal #

  Implementation notes:
  - Tag names must be lowercase.  Uppercase tags (e.g. <P>) are not handled in v1.
  - The bind path converts the template to VARCHAR2; requires length <= 32767 chars.
  - The no-bind path passes the CLOB directly; no size limit.
  - <table> requires both allow_query="true" in the tag AND
    p_options.allow_queries = TRUE in the render call (security double opt-in).
  - Inline bold/italic runs become separate block-level flowables (v1 limitation).
*/

-- ---------------------------------------------------------------------------
-- Private: column set registry (session-scoped, survives close_doc)
-- ---------------------------------------------------------------------------
TYPE t_col_registry IS TABLE OF rad_pdf_types.t_columns INDEX BY VARCHAR2(200);
g_col_registry t_col_registry;

-- ---------------------------------------------------------------------------
-- Private: inline run record
-- ---------------------------------------------------------------------------
TYPE t_run IS RECORD (
  text    VARCHAR2(32767) := NULL,
  bold    BOOLEAN         := FALSE,
  italic  BOOLEAN         := FALSE,
  is_br   BOOLEAN         := FALSE
);
TYPE t_run_list IS TABLE OF t_run INDEX BY PLS_INTEGER;

-- ---------------------------------------------------------------------------
-- Private: error sub-codes (all negative, in the -20810..-20817 range)
-- ---------------------------------------------------------------------------
c_err_unknown_tag CONSTANT PLS_INTEGER := -20811;
-- c_err_inline_ctx  -20812  (not used in body; inline errors are silent in v1)
c_err_table_attr  CONSTANT PLS_INTEGER := -20813;
c_err_table_cols  CONSTANT PLS_INTEGER := -20814;
c_err_table_qry   CONSTANT PLS_INTEGER := -20815;
c_err_img_id      CONSTANT PLS_INTEGER := -20816;
c_err_attr_val    CONSTANT PLS_INTEGER := -20817;

-- ---------------------------------------------------------------------------
-- Private: entity decoding  (&amp; &lt; &gt; -> & < >)
-- Decode &lt; and &gt; before &amp; so that &amp;lt; -> &lt; (not <).
-- ---------------------------------------------------------------------------
FUNCTION decode_entities(p_str IN VARCHAR2) RETURN VARCHAR2 IS
BEGIN
  RETURN REPLACE(
           REPLACE(
             REPLACE(p_str, '&lt;', '<'),
           '&gt;', '>'),
         '&amp;', '&');
END decode_entities;

-- ---------------------------------------------------------------------------
-- Private: extract an XML attribute value from a tag string.
-- Tries double-quoted form first, then single-quoted.
-- Returns NULL if the attribute is not present.
-- ---------------------------------------------------------------------------
FUNCTION extract_attr(
  p_tag  IN VARCHAR2,
  p_attr IN VARCHAR2
) RETURN VARCHAR2 IS
  l_val VARCHAR2(4000);
BEGIN
  -- Double-quoted:  attr="value"
  l_val := REGEXP_SUBSTR(p_tag, p_attr || '\s*=\s*"([^"]*)"', 1, 1, 'i', 1);
  IF l_val IS NOT NULL THEN
    RETURN l_val;
  END IF;
  -- Single-quoted:  attr='value'
  RETURN REGEXP_SUBSTR(
    p_tag,
    p_attr || '\s*=\s*' || CHR(39) || '([^' || CHR(39) || ']*)' || CHR(39),
    1, 1, 'i', 1);
END extract_attr;

-- ---------------------------------------------------------------------------
-- Private: parse a unit-bearing attribute (e.g. height="20mm") and return
-- the value in points.  Returns p_default when the attribute is absent.
-- Raises c_err_attr_val (-20817) on a parse error.
-- ---------------------------------------------------------------------------
FUNCTION parse_unit_attr(
  p_tag     IN VARCHAR2,
  p_attr    IN VARCHAR2,
  p_default IN NUMBER DEFAULT NULL
) RETURN NUMBER IS
  l_str VARCHAR2(100);
BEGIN
  l_str := extract_attr(p_tag, p_attr);
  IF l_str IS NULL THEN
    RETURN p_default;
  END IF;
  RETURN rad_pdf_units.parse_with_unit(l_str);
EXCEPTION
  WHEN OTHERS THEN
    RAISE_APPLICATION_ERROR(c_err_attr_val,
      'Invalid attribute value for ' || p_attr || ': "' || l_str || '"');
END parse_unit_attr;

-- ---------------------------------------------------------------------------
-- Private: apply bind substitutions.
-- The CLOB must be <= 32767 characters; raises c_err_template if larger.
-- Replaces ## with CHR(0) before binding, then restores -> literal #.
-- ---------------------------------------------------------------------------
FUNCTION apply_binds(
  p_clob  IN CLOB,
  p_binds IN rad_pdf_types.t_bind_array
) RETURN VARCHAR2 IS
  l_len PLS_INTEGER;
  l_str VARCHAR2(32767);
  i     BINARY_INTEGER;
BEGIN
  l_len := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
  IF l_len = 0 THEN
    RETURN NULL;
  END IF;
  IF l_len > 32767 THEN
    RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_template,
      'Template with bind values must be <= 32767 characters (current: '
      || l_len || ')');
  END IF;
  l_str := DBMS_LOB.SUBSTR(p_clob, l_len, 1);
  -- Protect escaped ## from bind replacement
  l_str := REPLACE(l_str, '##', CHR(0));
  -- Apply each bind (key matched case-insensitively)
  i := p_binds.FIRST;
  WHILE i IS NOT NULL LOOP
    l_str := REPLACE(l_str,
                '#' || UPPER(p_binds(i).key) || '#',
                p_binds(i).value);
    i := p_binds.NEXT(i);
  END LOOP;
  -- Restore ## -> literal #
  RETURN REPLACE(l_str, CHR(0), '#');
END apply_binds;

-- ---------------------------------------------------------------------------
-- Private: lazily derive a bold/italic style variant of p_base.
-- Creates p_base__b / p_base__i / p_base__bi in the style registry on first use.
-- Returns p_base unchanged when neither bold nor italic is requested.
-- ---------------------------------------------------------------------------
FUNCTION derive_style(
  p_base   IN VARCHAR2,
  p_bold   IN BOOLEAN,
  p_italic IN BOOLEAN
) RETURN VARCHAR2 IS
  l_name VARCHAR2(110);
  l_sty  rad_pdf_types.t_font_style;
  l_fmt  rad_pdf_types.t_cell_format;
BEGIN
  IF NOT p_bold AND NOT p_italic THEN
    RETURN p_base;
  END IF;
  l_sty  := CASE WHEN p_bold AND p_italic THEN 'BI'
                 WHEN p_bold              THEN 'B'
                 ELSE                         'I'
            END;
  l_name := p_base || '__' || LOWER(l_sty);
  IF NOT rad_pdf_styles.exists_style(l_name) THEN
    l_fmt := rad_pdf_styles.get(p_base);
    rad_pdf_styles.define(
      p_name       => l_name,
      p_font_name  => l_fmt.font_name,
      p_font_style => l_sty,
      p_font_size  => l_fmt.font_size,
      p_font_color => l_fmt.font_color,
      p_back_color => l_fmt.back_color
    );
  END IF;
  RETURN l_name;
END derive_style;

-- ---------------------------------------------------------------------------
-- Private: parse inline tags inside a <p> block.
-- Handles <b>, </b>, <i>, </i>, <br/>, <br>.
-- Unknown inline tags are silently ignored.
-- Each text segment becomes a t_run entry; <br/> produces an is_br entry.
-- ---------------------------------------------------------------------------
FUNCTION parse_inline(p_text IN VARCHAR2) RETURN t_run_list IS
  l_runs   t_run_list;
  l_pos    PLS_INTEGER := 1;
  l_len    PLS_INTEGER;
  l_ts     PLS_INTEGER;
  l_te     PLS_INTEGER;
  l_tag    VARCHAR2(200);
  l_seg    VARCHAR2(32767);
  l_bold   BOOLEAN := FALSE;
  l_italic BOOLEAN := FALSE;
  l_idx    PLS_INTEGER := 0;
  l_run    t_run;

  PROCEDURE push_text(p_seg IN VARCHAR2) IS
  BEGIN
    IF p_seg IS NOT NULL THEN
      l_idx := l_idx + 1;
      l_run.text   := decode_entities(p_seg);
      l_run.bold   := l_bold;
      l_run.italic := l_italic;
      l_run.is_br  := FALSE;
      l_runs(l_idx) := l_run;
    END IF;
  END push_text;

BEGIN
  l_len := NVL(LENGTH(p_text), 0);
  WHILE l_pos <= l_len LOOP
    l_ts := INSTR(p_text, '<', l_pos);
    IF l_ts = 0 THEN
      push_text(SUBSTR(p_text, l_pos));
      EXIT;
    END IF;
    -- Text before the tag
    IF l_ts > l_pos THEN
      push_text(SUBSTR(p_text, l_pos, l_ts - l_pos));
    END IF;
    -- Find end of tag
    l_te := INSTR(p_text, '>', l_ts);
    IF l_te = 0 THEN
      -- Malformed: append remaining text verbatim
      push_text(SUBSTR(p_text, l_ts));
      EXIT;
    END IF;
    l_tag := LOWER(TRIM(SUBSTR(p_text, l_ts, l_te - l_ts + 1)));
    CASE
      WHEN l_tag = '<b>'              THEN l_bold   := TRUE;
      WHEN l_tag = '</b>'             THEN l_bold   := FALSE;
      WHEN l_tag = '<i>'              THEN l_italic := TRUE;
      WHEN l_tag = '</i>'             THEN l_italic := FALSE;
      WHEN l_tag IN ('<br/>', '<br>') THEN
        l_idx := l_idx + 1;
        l_run.text   := NULL;
        l_run.bold   := FALSE;
        l_run.italic := FALSE;
        l_run.is_br  := TRUE;
        l_runs(l_idx) := l_run;
      ELSE NULL;  -- unknown inline tag: skip silently
    END CASE;
    l_pos := l_te + 1;
  END LOOP;
  RETURN l_runs;
END parse_inline;

-- ---------------------------------------------------------------------------
-- Private: dispatch the text content of a <p> block.
-- Each inline run (bold/italic/normal/br) becomes a separate flowable.
-- Bold/italic styles are derived lazily via derive_style.
-- ---------------------------------------------------------------------------
PROCEDURE dispatch_paragraph(
  p_doc   IN rad_pdf_types.t_doc_handle,
  p_text  IN VARCHAR2,
  p_style IN VARCHAR2
) IS
  l_runs t_run_list;
  l_sty  VARCHAR2(110);
  i      PLS_INTEGER;
BEGIN
  l_runs := parse_inline(p_text);
  i := l_runs.FIRST;
  WHILE i IS NOT NULL LOOP
    IF l_runs(i).is_br THEN
      rad_pdf_layout.add(p_doc, rad_pdf_layout.spacer(2));
    ELSIF l_runs(i).text IS NOT NULL THEN
      l_sty := derive_style(p_style, l_runs(i).bold, l_runs(i).italic);
      rad_pdf_layout.add(p_doc,
        rad_pdf_layout.paragraph(l_runs(i).text, l_sty));
    END IF;
    i := l_runs.NEXT(i);
  END LOOP;
END dispatch_paragraph;

-- ---------------------------------------------------------------------------
-- Private: dispatch a self-closing block tag.
-- p_tag is the full raw tag string (may include attributes).
-- ---------------------------------------------------------------------------
PROCEDURE dispatch_self_close(
  p_doc     IN rad_pdf_types.t_doc_handle,
  p_name    IN VARCHAR2,
  p_tag     IN VARCHAR2,
  p_options IN rad_pdf_types.t_template_options
) IS
  l_h        NUMBER;
  l_color    rad_pdf_types.t_rgb;
  l_lw       NUMBER;
  l_id_str   VARCHAR2(100);
  l_id       PLS_INTEGER;
  l_img_w    NUMBER;
  l_img_h    NUMBER;
  l_col_name VARCHAR2(200);
  l_qry      VARCHAR2(32767);
  l_allow_q  VARCHAR2(10);
  l_tdef     rad_pdf_types.t_table_def;
  l_ref_id   PLS_INTEGER;
  l_flow     rad_pdf_types.t_flowable;
BEGIN
  CASE p_name

    -- <spacer height="20pt"/> ------------------------------------------------
    WHEN 'spacer' THEN
      l_h := parse_unit_attr(p_tag, 'height', 12);
      rad_pdf_layout.add(p_doc, rad_pdf_layout.spacer(l_h));

    -- <hr [color="cccccc"] [width="0.5"]/>  ----------------------------------
    WHEN 'hr' THEN
      l_color := UPPER(NVL(extract_attr(p_tag, 'color'), '000000'));
      l_lw    := parse_unit_attr(p_tag, 'width', 0.5);
      rad_pdf_layout.add(p_doc, rad_pdf_layout.h_rule(l_color, l_lw));

    -- <pagebreak/> -----------------------------------------------------------
    WHEN 'pagebreak' THEN
      rad_pdf_layout.add(p_doc, rad_pdf_layout.page_break);

    -- <img id="N" [width="Xmm"] [height="Ymm"]/>  ---------------------------
    WHEN 'img' THEN
      l_id_str := extract_attr(p_tag, 'id');
      IF l_id_str IS NULL THEN
        RAISE_APPLICATION_ERROR(c_err_img_id,
          '<img> missing required "id" attribute');
      END IF;
      BEGIN
        l_id := TO_NUMBER(l_id_str);
      EXCEPTION WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(c_err_attr_val,
          '<img> invalid "id" value: "' || l_id_str || '"');
      END;
      l_img_w := parse_unit_attr(p_tag, 'width',  NULL);
      l_img_h := parse_unit_attr(p_tag, 'height', NULL);
      rad_pdf_layout.add(p_doc, rad_pdf_layout.image(l_id, l_img_w, l_img_h));

    -- <table columns="NAME" query="SELECT ..." allow_query="true"/>  ---------
    WHEN 'table' THEN
      l_col_name := extract_attr(p_tag, 'columns');
      IF l_col_name IS NULL THEN
        RAISE_APPLICATION_ERROR(c_err_table_attr,
          '<table> missing required "columns" attribute');
      END IF;
      l_qry := extract_attr(p_tag, 'query');
      IF l_qry IS NULL THEN
        RAISE_APPLICATION_ERROR(c_err_table_attr,
          '<table> missing required "query" attribute');
      END IF;
      IF NOT g_col_registry.EXISTS(UPPER(l_col_name)) THEN
        RAISE_APPLICATION_ERROR(c_err_table_cols,
          '<table> column set not registered: "' || l_col_name || '"');
      END IF;
      -- Security double opt-in: tag AND options must both enable queries.
      l_allow_q := LOWER(NVL(extract_attr(p_tag, 'allow_query'), 'false'));
      IF l_allow_q != 'true' OR NOT NVL(p_options.allow_queries, FALSE) THEN
        RAISE_APPLICATION_ERROR(c_err_table_qry,
          '<table> query execution not enabled; '
          || 'set allow_query="true" in the tag '
          || 'and allow_queries => TRUE in t_template_options');
      END IF;
      l_tdef.query_txt    := l_qry;
      l_tdef.col_defs     := g_col_registry(UPPER(l_col_name));
      l_tdef.color_scheme := rad_pdf_styles.default_scheme;
      l_tdef.options      := rad_pdf_units.default_table_options;
      l_ref_id            := rad_pdf_layout.register_table(p_doc, l_tdef);
      l_flow.flow_type    := rad_pdf_types.c_flow_table;
      l_flow.table_ref_id := l_ref_id;
      rad_pdf_layout.add(p_doc, l_flow);

    ELSE
      IF NVL(p_options.strict_tags, TRUE) THEN
        RAISE_APPLICATION_ERROR(c_err_unknown_tag,
          'Unknown block tag: <' || p_name || '>');
      END IF;
  END CASE;
END dispatch_self_close;

-- ---------------------------------------------------------------------------
-- Private: dispatch an open/close block tag pair.
-- p_tag     = opening tag raw string (may contain attributes).
-- p_content = text content between the opening and closing tags.
-- ---------------------------------------------------------------------------
PROCEDURE dispatch_open_close(
  p_doc     IN rad_pdf_types.t_doc_handle,
  p_name    IN VARCHAR2,
  p_tag     IN VARCHAR2,
  p_content IN VARCHAR2,
  p_options IN rad_pdf_types.t_template_options
) IS
  l_style VARCHAR2(100);
  l_level PLS_INTEGER;
BEGIN
  IF p_name = 'p' THEN
    -- Optional style attribute on the <p> tag; fall back to default_style.
    l_style := NVL(extract_attr(p_tag, 'style'),
               NVL(p_options.default_style, 'body'));
    dispatch_paragraph(p_doc, p_content, l_style);

  ELSIF REGEXP_LIKE(p_name, '^h[1-6]$') THEN
    l_level := TO_NUMBER(SUBSTR(p_name, 2));
    rad_pdf_layout.add(p_doc,
      rad_pdf_layout.heading(decode_entities(p_content), l_level));

  ELSE
    IF NVL(p_options.strict_tags, TRUE) THEN
      RAISE_APPLICATION_ERROR(c_err_unknown_tag,
        'Unknown block tag: <' || p_name || '>');
    END IF;
  END IF;
END dispatch_open_close;

-- ---------------------------------------------------------------------------
-- Private: main CLOB render loop.
-- Scans the CLOB for block-level tags using DBMS_LOB.INSTR / DBMS_LOB.SUBSTR.
-- Text between block tags is silently skipped (whitespace / newlines).
-- Options are normalised before entering the loop.
-- ---------------------------------------------------------------------------
PROCEDURE do_render(
  p_doc     IN rad_pdf_types.t_doc_handle,
  p_clob    IN CLOB,
  p_options IN rad_pdf_types.t_template_options
) IS
  l_len       PLS_INTEGER;
  l_pos       PLS_INTEGER := 1;
  l_tag_start PLS_INTEGER;
  l_tag_end   PLS_INTEGER;
  l_tag_raw   VARCHAR2(32767);
  l_tag_name  VARCHAR2(100);
  l_close_tag VARCHAR2(110);
  l_close_pos PLS_INTEGER;
  l_cnt_len   PLS_INTEGER;
  l_content   VARCHAR2(32767);
  l_is_self   BOOLEAN;
  l_opts      rad_pdf_types.t_template_options;
BEGIN
  -- Normalise options (apply defaults for NULL fields)
  l_opts.default_font_name  := p_options.default_font_name;
  l_opts.default_font_style := p_options.default_font_style;
  l_opts.default_font_size  := p_options.default_font_size;
  l_opts.default_style      := NVL(p_options.default_style, 'body');
  l_opts.strict_tags        := NVL(p_options.strict_tags,   TRUE);
  l_opts.allow_queries      := NVL(p_options.allow_queries, FALSE);

  l_len := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
  IF l_len = 0 THEN RETURN; END IF;

  WHILE l_pos <= l_len LOOP

    -- Locate next '<'
    l_tag_start := DBMS_LOB.INSTR(p_clob, '<', l_pos);
    IF l_tag_start = 0 OR l_tag_start > l_len THEN EXIT; END IF;

    -- Locate matching '>'
    l_tag_end := DBMS_LOB.INSTR(p_clob, '>', l_tag_start);
    IF l_tag_end = 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_template,
        'Unclosed tag starting at character position ' || l_tag_start);
    END IF;

    -- Extract up to 32767 chars of the raw tag
    l_tag_raw := DBMS_LOB.SUBSTR(p_clob,
                   LEAST(l_tag_end - l_tag_start + 1, 32767),
                   l_tag_start);

    -- Skip closing tags, XML declarations, and comments
    IF SUBSTR(l_tag_raw, 2, 1) IN ('/', '!', '?') THEN
      l_pos := l_tag_end + 1;

    ELSE
      -- Extract tag name (first \w+ after '<')
      l_tag_name := LOWER(REGEXP_SUBSTR(l_tag_raw, '<(\w+)', 1, 1, NULL, 1));

      IF l_tag_name IS NULL THEN
        -- Malformed tag with no name (e.g. '<>') — skip silently
        l_pos := l_tag_end + 1;

      ELSE
        -- Determine if self-closing: tag ends with '/>' or is a known void element
        l_is_self := RTRIM(l_tag_raw) LIKE '%/>'
                     OR l_tag_name IN ('spacer', 'hr', 'pagebreak', 'img', 'table');

        IF l_is_self THEN
          dispatch_self_close(p_doc, l_tag_name, l_tag_raw, l_opts);
          l_pos := l_tag_end + 1;

        ELSE
          -- Find the matching closing tag after the opening tag
          l_close_tag := '</' || l_tag_name || '>';
          l_close_pos := DBMS_LOB.INSTR(p_clob, l_close_tag, l_tag_end + 1);
          IF l_close_pos = 0 THEN
            RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_template,
              'Unclosed <' || l_tag_name || '> tag (no matching '
              || l_close_tag || ' found)');
          END IF;

          -- Guard: block content must fit in VARCHAR2
          l_cnt_len := l_close_pos - l_tag_end - 1;
          IF l_cnt_len > 32767 THEN
            RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_template,
              'Content of <' || l_tag_name
              || '> block exceeds 32767 characters (' || l_cnt_len || ')');
          END IF;

          -- Extract content (NULL when tags are adjacent, e.g. <p></p>)
          IF l_cnt_len > 0 THEN
            l_content := DBMS_LOB.SUBSTR(p_clob, l_cnt_len, l_tag_end + 1);
          ELSE
            l_content := NULL;
          END IF;

          dispatch_open_close(p_doc, l_tag_name, l_tag_raw, l_content, l_opts);
          l_pos := l_close_pos + LENGTH(l_close_tag);
        END IF;
      END IF;
    END IF;

  END LOOP;
END do_render;

-- ===========================================================================
-- Public: column set registry
-- ===========================================================================

PROCEDURE register_columns(
  p_name    IN VARCHAR2,
  p_columns IN rad_pdf_types.t_columns
) IS
BEGIN
  g_col_registry(UPPER(TRIM(p_name))) := p_columns;
END register_columns;

PROCEDURE drop_columns(p_name IN VARCHAR2) IS
  l_key VARCHAR2(200);
BEGIN
  l_key := UPPER(TRIM(p_name));
  IF g_col_registry.EXISTS(l_key) THEN
    g_col_registry.DELETE(l_key);
  END IF;
END drop_columns;

PROCEDURE clear_columns IS
BEGIN
  g_col_registry.DELETE;
END clear_columns;

-- ===========================================================================
-- Public: escape_value
-- ===========================================================================

FUNCTION escape_value(p_value IN VARCHAR2) RETURN VARCHAR2 IS
BEGIN
  RETURN REPLACE(
           REPLACE(
             REPLACE(p_value, '&', '&amp;'),
           '<', '&lt;'),
         '>', '&gt;');
END escape_value;

-- ===========================================================================
-- Public: render overloads
-- ===========================================================================

-- CLOB + binds
-- Template is converted to VARCHAR2 (requires <= 32767 chars), binds are applied,
-- then the result is passed to do_render via a temporary CLOB.
PROCEDURE render(
  p_doc     IN rad_pdf_types.t_doc_handle,
  p_clob    IN CLOB,
  p_binds   IN rad_pdf_types.t_bind_array,
  p_options IN rad_pdf_types.t_template_options DEFAULT NULL
) IS
  l_str  VARCHAR2(32767);
  l_clob CLOB;
BEGIN
  rad_pdf_ctx.assert_valid(p_doc);
  l_str := apply_binds(p_clob, p_binds);
  DBMS_LOB.CREATETEMPORARY(l_clob, TRUE);
  IF l_str IS NOT NULL THEN
    DBMS_LOB.WRITEAPPEND(l_clob, LENGTH(l_str), l_str);
  END IF;
  do_render(p_doc, l_clob, p_options);
  DBMS_LOB.FREETEMPORARY(l_clob);
EXCEPTION
  WHEN OTHERS THEN
    IF DBMS_LOB.ISTEMPORARY(l_clob) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_clob);
    END IF;
    RAISE;
END render;

-- VARCHAR2 + binds  (delegates to the CLOB + binds overload)
PROCEDURE render(
  p_doc      IN rad_pdf_types.t_doc_handle,
  p_template IN VARCHAR2,
  p_binds    IN rad_pdf_types.t_bind_array,
  p_options  IN rad_pdf_types.t_template_options DEFAULT NULL
) IS
BEGIN
  render(p_doc, TO_CLOB(p_template), p_binds, p_options);
END render;

-- CLOB, no binds  (no size limit; CLOB passed directly to do_render)
PROCEDURE render(
  p_doc     IN rad_pdf_types.t_doc_handle,
  p_clob    IN CLOB,
  p_options IN rad_pdf_types.t_template_options DEFAULT NULL
) IS
BEGIN
  rad_pdf_ctx.assert_valid(p_doc);
  do_render(p_doc, p_clob, p_options);
END render;

-- VARCHAR2, no binds  (delegates to the CLOB no-bind overload)
PROCEDURE render(
  p_doc      IN rad_pdf_types.t_doc_handle,
  p_template IN VARCHAR2,
  p_options  IN rad_pdf_types.t_template_options DEFAULT NULL
) IS
BEGIN
  render(p_doc, TO_CLOB(p_template), p_options);
END render;

END rad_pdf_template;
/
