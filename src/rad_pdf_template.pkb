CREATE OR REPLACE PACKAGE BODY rad_pdf_template IS
/*
  rad_pdf_template body — lightweight template engine for RAD_PDF.
  Oracle 19c+.  Phase 9.  AUTHID CURRENT_USER (inherited from spec).

  Block tags parsed by do_render (CLOB scanner):
    <p [style="..."]>...</p>
    <h1>...</h1>  ..  <h6>...</h6>
    <ul [style="..."]><li>...</li></ul>          unordered list (bullet)
    <ol [style="..."]><li>...</li></ol>          ordered list (numbered)
    <spacer [height="20pt"]/>
    <hr [color="cccccc"] [width="0.5"]/>
    <img id="N" [width="Xmm"] [height="Ymm"]/>
    <table columns="NAME" query="SELECT ..."
           [row_height="Xpt"] [max_rows="N"]
           [header_bg="RRGGBB"] [alt_bg="RRGGBB"] [border_color="RRGGBB"]
           allow_query="true"/>
    <pagebreak/>

  Inline tags inside <p> / <li> content (parsed by parse_inline):
    <b>...</b>          bold run  -> derives style variant p_style__b
    <i>...</i>          italic    -> derives style variant p_style__i
    <br/>               forced line-break within the paragraph
    <color rgb="RRGGBB">...</color>
                        custom ink colour (6-char hex, case-insensitive).
                        Unlimited nesting depth: each opening tag pushes the
                        current colour; each </color> pops and restores it.
    <font size="Xpt">...</font>
                        custom font size (any unit accepted by rad_pdf_units).
                        Unlimited nesting depth (LIFO stack).

  Placeholder tokens substituted before parsing:
    #KEY#  ->  bind value (auto-escaped unless raw=TRUE in t_bind_entry)
    ##     ->  literal #

  Conditional blocks (evaluated before bind substitution):
    <if bind="KEY">...</if>
      Rendered only when the bind value for KEY is non-NULL and non-empty.
      Nested <if> blocks are not supported in v1.

  Implementation notes:
  - Block and inline tag names are case-insensitive (<P>, <H1>, <B>, <Color>…
    all work; the parser applies LOWER() before matching).
  - Attribute names are case-insensitive (REGEXP_SUBSTR with 'i' flag).
  - Exception: <if>…</if> conditional tags must be lowercase because the
    CLOB-level DBMS_LOB.INSTR scanner is case-sensitive.
  - Both the bind path and the no-bind path accept CLOBs of any size (no 32767
    limit).  Bind substitution is done by CLOB-level scanning, not via VARCHAR2.
  - <table> requires both allow_query="true" in the tag AND
    p_options.allow_queries = TRUE in the render call (security double opt-in).
  - Inline bold/italic runs within a <p> / <li> are rendered inline on the same
    line via the PARA_RUNS flowable (paragraph_runs constructor in rad_pdf_layout).
  - Bind values are auto-escaped (& < > converted to entities) by default.
    Set raw=TRUE on a t_bind_entry to bypass escaping for already-safe values.
*/

-- ---------------------------------------------------------------------------
-- Private: column set registry (session-scoped, survives close_doc)
-- ---------------------------------------------------------------------------
TYPE t_col_registry IS TABLE OF rad_pdf_types.t_columns INDEX BY VARCHAR2(200);
g_col_registry t_col_registry;

-- ---------------------------------------------------------------------------
-- Private: query bind map — populated by shield_query_attrs before Phase 2,
-- consumed by handle_table_tag to bind values via DBMS_SQL.BIND_VARIABLE.
-- Key   = UPPER(token name), e.g. 'DEPTNO'
-- Value = raw bind value (not XML-escaped; SQL binding handles quoting)
-- Sentinel chars: CHR(1) opens, CHR(2) closes the placeholder in the query.
-- ---------------------------------------------------------------------------
TYPE t_qbind_map IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(200);
g_qbind_map    t_qbind_map;
g_qbind_active BOOLEAN := FALSE;   -- TRUE during a render(CLOB,binds) call

-- ---------------------------------------------------------------------------
-- Private: inline run record
-- ---------------------------------------------------------------------------
TYPE t_run IS RECORD (
  text      VARCHAR2(32767) := NULL,
  bold      BOOLEAN         := FALSE,
  italic    BOOLEAN         := FALSE,
  is_br     BOOLEAN         := FALSE,
  color     VARCHAR2(6)     := NULL,  -- NULL = inherit from style
  font_size NUMBER          := NULL   -- NULL = inherit from style; in pt
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
-- Private: validate a 6-character uppercase hex RGB string.
-- Returns TRUE only when p_rgb is exactly 6 characters matching [0-9A-F]{6}.
-- Consistent with the inline <color rgb="..."> validation in parse_inline.
-- ---------------------------------------------------------------------------
FUNCTION is_valid_rgb(p_rgb IN VARCHAR2) RETURN BOOLEAN IS
BEGIN
  RETURN p_rgb IS NOT NULL
         AND LENGTH(p_rgb) = 6
         AND REGEXP_LIKE(p_rgb, '^[0-9A-F]{6}$');
END is_valid_rgb;

-- ---------------------------------------------------------------------------
-- Private: Phase 0 normalisation — lowercase block-tag names that CLOB
-- scanners match case-sensitively (<LI>/<IF> → <li>/<if>).
--
-- Returns a *new* temporary CLOB when replacements were made, or p_src
-- itself (same LOB locator, IS_TEMPORARY = 0) when none were needed.
-- Callers must guard FREETEMPORARY with DBMS_LOB.ISTEMPORARY checks.
--
-- p_normalise_if = TRUE: also normalise <IF …> / </IF> (used when the
--   source may contain <if bind="..."> conditional blocks).
-- ---------------------------------------------------------------------------
FUNCTION normalize_clob(
  p_src          IN CLOB,
  p_normalise_if IN BOOLEAN DEFAULT FALSE
) RETURN CLOB IS
  l_needs_norm BOOLEAN;
  l_tmp        CLOB;
  l_dst        CLOB;
BEGIN
  l_needs_norm :=
    DBMS_LOB.INSTR(p_src, '<LI>',  1) > 0 OR
    DBMS_LOB.INSTR(p_src, '</LI>', 1) > 0;
  IF NVL(p_normalise_if, FALSE) THEN
    l_needs_norm := l_needs_norm
      OR DBMS_LOB.INSTR(p_src, '<IF ',  1) > 0
      OR DBMS_LOB.INSTR(p_src, '</IF>', 1) > 0;
  END IF;

  IF NOT l_needs_norm THEN
    RETURN p_src;   -- no copy; caller treats as alias
  END IF;

  -- SELECT REPLACE via SQL engine avoids ORA-06502 on large CLOBs (the
  -- PL/SQL built-in REPLACE implicitly converts CLOB to VARCHAR2).
  -- Materialise into an explicit temp CLOB: implicit LOBs returned by
  -- SELECT INTO can misbehave when passed to nested DBMS_LOB operations.
  IF NVL(p_normalise_if, FALSE) THEN
    SELECT REPLACE(
             REPLACE(
               REPLACE(
                 REPLACE(p_src, '<IF ', '<if '),
               '</IF>', '</if>'),
             '<LI>', '<li>'),
           '</LI>', '</li>')
      INTO l_tmp FROM DUAL;
  ELSE
    SELECT REPLACE(REPLACE(p_src, '<LI>', '<li>'), '</LI>', '</li>')
      INTO l_tmp FROM DUAL;
  END IF;
  DBMS_LOB.CREATETEMPORARY(l_dst, TRUE);
  IF NVL(DBMS_LOB.GETLENGTH(l_tmp), 0) > 0 THEN
    DBMS_LOB.COPY(l_dst, l_tmp, DBMS_LOB.GETLENGTH(l_tmp), 1, 1);
  END IF;
  RETURN l_dst;
END normalize_clob;

-- ---------------------------------------------------------------------------
-- Private: extract an XML attribute value from a tag string.
-- Tries double-quoted form first, then single-quoted.
-- Returns NULL if the attribute is not present.
-- ---------------------------------------------------------------------------
FUNCTION extract_attr(
  p_tag  IN VARCHAR2,
  p_attr IN VARCHAR2
) RETURN VARCHAR2 IS
  l_val VARCHAR2(32767);
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
-- Private: lazily derive a style variant of p_base combining bold/italic,
-- optional ink colour, and optional font size.
--
-- Name scheme (suffixes appended in order):
--   Bold/italic : __b | __i | __bi
--   Colour      : __c<rrggbb>     e.g. __cff0000
--   Font size   : __s<N>          e.g. __s14  (rounded to integer pt)
--
-- The resulting style is created once in the rad_pdf_styles registry;
-- subsequent calls with the same parameters return the cached name instantly.
-- Returns p_base unchanged when all optional parameters are at their defaults.
-- ---------------------------------------------------------------------------
FUNCTION derive_style(
  p_base      IN VARCHAR2,
  p_bold      IN BOOLEAN,
  p_italic    IN BOOLEAN,
  p_color     IN VARCHAR2 DEFAULT NULL,
  p_font_size IN NUMBER   DEFAULT NULL
) RETURN VARCHAR2 IS
  l_name VARCHAR2(150);
  l_sty  rad_pdf_types.t_font_style;
  l_fmt  rad_pdf_types.t_cell_format;
BEGIN
  -- Fast path: no overrides at all
  IF NOT (NVL(p_bold, FALSE) OR NVL(p_italic, FALSE)
          OR p_color IS NOT NULL OR p_font_size IS NOT NULL)
  THEN
    RETURN p_base;
  END IF;

  -- Build name suffix for bold / italic
  IF NVL(p_bold, FALSE) AND NVL(p_italic, FALSE) THEN
    l_sty  := 'BI'; l_name := p_base || '__bi';
  ELSIF NVL(p_bold, FALSE) THEN
    l_sty  := 'B';  l_name := p_base || '__b';
  ELSIF NVL(p_italic, FALSE) THEN
    l_sty  := 'I';  l_name := p_base || '__i';
  ELSE
    l_sty  := NULL; l_name := p_base;
  END IF;

  -- Append colour and/or font-size suffixes
  IF p_color IS NOT NULL THEN
    l_name := l_name || '__c' || LOWER(p_color);
  END IF;
  IF p_font_size IS NOT NULL THEN
    l_name := l_name || '__s' || TO_CHAR(ROUND(p_font_size));
  END IF;

  -- Register the style variant lazily
  IF NOT rad_pdf_styles.exists_style(l_name) THEN
    l_fmt := rad_pdf_styles.get(p_base);
    -- Apply bold/italic if requested
    IF l_sty IS NOT NULL THEN
      l_fmt.font_style := l_sty;
    END IF;
    -- Apply overrides
    IF p_color IS NOT NULL THEN
      l_fmt.font_color := p_color;
    END IF;
    IF p_font_size IS NOT NULL THEN
      l_fmt.font_size := p_font_size;
    END IF;
    rad_pdf_styles.define(
      p_name       => l_name,
      p_font_name  => l_fmt.font_name,
      p_font_style => l_fmt.font_style,
      p_font_size  => l_fmt.font_size,
      p_font_color => l_fmt.font_color,
      p_back_color => l_fmt.back_color
    );
  END IF;
  RETURN l_name;
END derive_style;

-- ---------------------------------------------------------------------------
-- Private: parse inline tags inside a <p> block.
-- Handles <b>, </b>, <i>, </i>, <br/>, <br>,
--         <color rgb="RRGGBB">, </color>,
--         <font size="Xpt">, </font>.
-- Unknown inline tags are silently ignored.
-- Each text segment becomes a t_run entry; <br/> produces an is_br entry.
-- Unlimited nesting depth is supported for <color> and <font> via LIFO
-- stacks: each opening tag pushes the current value; the matching closing
-- tag pops and restores the previous value.
-- ---------------------------------------------------------------------------
FUNCTION parse_inline(p_text IN VARCHAR2) RETURN t_run_list IS
  l_runs          t_run_list;
  l_pos           PLS_INTEGER := 1;
  l_len           PLS_INTEGER;
  l_ts            PLS_INTEGER;
  l_te            PLS_INTEGER;
  l_tag           VARCHAR2(200);
  l_bold          BOOLEAN    := FALSE;
  l_italic        BOOLEAN    := FALSE;
  l_color         VARCHAR2(6):= NULL;   -- current ink colour  (NULL = inherit)
  l_font_size     NUMBER     := NULL;   -- current font size in pt (NULL = inherit)
  -- Unlimited-depth LIFO stacks for <color> and <font>
  TYPE t_vc6_stack IS TABLE OF VARCHAR2(6) INDEX BY PLS_INTEGER;
  TYPE t_num_stack IS TABLE OF NUMBER       INDEX BY PLS_INTEGER;
  l_color_stk   t_vc6_stack;
  l_font_sz_stk t_num_stack;
  l_clr_depth   PLS_INTEGER := 0;
  l_fnt_depth   PLS_INTEGER := 0;
  l_rgb           VARCHAR2(6);
  l_sz_str        VARCHAR2(30);
  l_idx           PLS_INTEGER := 0;
  l_run           t_run;

  PROCEDURE push_text(p_seg IN VARCHAR2) IS
  BEGIN
    IF p_seg IS NOT NULL THEN
      l_idx           := l_idx + 1;
      l_run.text      := decode_entities(p_seg);
      l_run.bold      := l_bold;
      l_run.italic    := l_italic;
      l_run.is_br     := FALSE;
      l_run.color     := l_color;
      l_run.font_size := l_font_size;
      l_runs(l_idx)   := l_run;
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
    l_tag := LOWER(TRIM(SUBSTR(p_text, l_ts, LEAST(l_te - l_ts + 1, 200))));

    IF    l_tag = '<b>'   THEN l_bold   := TRUE;
    ELSIF l_tag = '</b>'  THEN l_bold   := FALSE;
    ELSIF l_tag = '<i>'   THEN l_italic := TRUE;
    ELSIF l_tag = '</i>'  THEN l_italic := FALSE;
    ELSIF l_tag IN ('<br/>', '<br>') THEN
      l_idx         := l_idx + 1;
      l_run.text    := NULL;
      l_run.bold    := FALSE;
      l_run.italic  := FALSE;
      l_run.is_br   := TRUE;
      l_run.color   := NULL;
      l_run.font_size := NULL;
      l_runs(l_idx) := l_run;

    -- <color rgb="RRGGBB"> : override ink colour (LIFO stack, unlimited depth)
    ELSIF SUBSTR(l_tag, 1, 7) = '<color ' THEN
      l_rgb := UPPER(TRIM(extract_attr(l_tag, 'rgb')));
      IF l_rgb IS NOT NULL AND LENGTH(l_rgb) = 6
         AND REGEXP_LIKE(l_rgb, '^[0-9A-F]{6}$')
      THEN
        l_clr_depth              := l_clr_depth + 1;
        l_color_stk(l_clr_depth) := l_color;   -- push current colour
        l_color                  := l_rgb;
      END IF;
      -- Invalid rgb attribute: ignore tag, colour and stack unchanged

    ELSIF l_tag = '</color>' THEN
      IF l_clr_depth > 0 THEN
        l_color     := l_color_stk(l_clr_depth);   -- pop
        l_clr_depth := l_clr_depth - 1;
      ELSE
        l_color := NULL;   -- underflow: reset to inherit
      END IF;

    -- <font size="Xpt"> : override font size (LIFO stack, unlimited depth)
    ELSIF SUBSTR(l_tag, 1, 6) = '<font ' THEN
      l_sz_str := TRIM(extract_attr(l_tag, 'size'));
      IF l_sz_str IS NOT NULL THEN
        BEGIN
          l_fnt_depth                := l_fnt_depth + 1;
          l_font_sz_stk(l_fnt_depth) := l_font_size;   -- push current size
          l_font_size                := rad_pdf_units.parse_with_unit(l_sz_str);
        EXCEPTION WHEN OTHERS THEN
          -- Invalid size: undo the push and leave font_size unchanged
          l_font_size := l_font_sz_stk(l_fnt_depth);
          l_fnt_depth := l_fnt_depth - 1;
        END;
      END IF;

    ELSIF l_tag = '</font>' THEN
      IF l_fnt_depth > 0 THEN
        l_font_size := l_font_sz_stk(l_fnt_depth);   -- pop
        l_fnt_depth := l_fnt_depth - 1;
      ELSE
        l_font_size := NULL;   -- underflow: reset to inherit
      END IF;

    ELSE
      NULL;  -- unknown inline tag: skip silently
    END IF;

    l_pos := l_te + 1;
  END LOOP;
  RETURN l_runs;
END parse_inline;

-- ---------------------------------------------------------------------------
-- Private: dispatch the text content of a <p> block.
--
-- When the paragraph contains no inline style changes and no <br/> tags
-- the text is emitted as a plain PARAGRAPH flowable (single style,
-- word-wrapped).
--
-- When the paragraph contains at least one styled run (<b>, <i>,
-- <color>, <font>) OR a forced line break (<br/>), the text is emitted as
-- a PARA_RUNS flowable, rendering all runs on the same word-wrapped lines.
-- Treating <br/> as a PARA_RUNS trigger ensures it always behaves as a
-- true within-paragraph line break regardless of other inline markup.
--
-- Style variants are derived lazily via derive_style.
-- ---------------------------------------------------------------------------
PROCEDURE dispatch_paragraph(
  p_doc   IN rad_pdf_types.t_doc_handle,
  p_text  IN VARCHAR2,
  p_style IN VARCHAR2
) IS
  l_runs    t_run_list;
  l_inline  rad_pdf_types.t_inline_run_list;
  l_run     rad_pdf_types.t_inline_run;
  l_has_mix BOOLEAN := FALSE;
  l_j       PLS_INTEGER := 0;
  i         PLS_INTEGER;
BEGIN
  l_runs := parse_inline(p_text);

  -- Quick scan: does this paragraph contain any styled run or a <br/>?
  -- <br/> is included so it always routes through PARA_RUNS (true line break)
  -- rather than the legacy plain-paragraph spacer path.
  i := l_runs.FIRST;
  WHILE i IS NOT NULL LOOP
    IF l_runs(i).is_br
       OR l_runs(i).bold OR l_runs(i).italic
       OR l_runs(i).color IS NOT NULL
       OR l_runs(i).font_size IS NOT NULL
    THEN
      l_has_mix := TRUE;
      EXIT;
    END IF;
    i := l_runs.NEXT(i);
  END LOOP;

  IF l_has_mix THEN
    -- -----------------------------------------------------------------------
    -- Mixed-style paragraph: pre-compute a named style for every run,
    -- then register as a PARA_RUNS flowable.
    -- -----------------------------------------------------------------------
    i := l_runs.FIRST;
    WHILE i IS NOT NULL LOOP
      l_j := l_j + 1;
      l_run.is_br := l_runs(i).is_br;
      IF l_runs(i).is_br THEN
        l_run.text       := NULL;
        l_run.style_name := p_style;
      ELSE
        l_run.text       := l_runs(i).text;
        l_run.style_name := derive_style(p_style,
                                         l_runs(i).bold,
                                         l_runs(i).italic,
                                         l_runs(i).color,
                                         l_runs(i).font_size);
      END IF;
      l_inline(l_j) := l_run;
      i := l_runs.NEXT(i);
    END LOOP;
    rad_pdf_layout.add(p_doc,
      rad_pdf_layout.paragraph_runs(p_doc, l_inline, p_style));
  ELSE
    -- -----------------------------------------------------------------------
    -- Plain paragraph (no inline style changes): emit each run as a simple
    -- PARAGRAPH flowable.  <br/> produces a small spacer (legacy behaviour).
    -- -----------------------------------------------------------------------
    i := l_runs.FIRST;
    WHILE i IS NOT NULL LOOP
      IF l_runs(i).is_br THEN
        rad_pdf_layout.add(p_doc, rad_pdf_layout.spacer(2));
      ELSIF l_runs(i).text IS NOT NULL THEN
        rad_pdf_layout.add(p_doc,
          rad_pdf_layout.paragraph(l_runs(i).text, p_style));
      END IF;
      i := l_runs.NEXT(i);
    END LOOP;
  END IF;
END dispatch_paragraph;

-- ---------------------------------------------------------------------------
-- Private: handle the <table> self-closing tag.
-- Extracted from dispatch_self_close so every branch of that CASE sits at
-- the same abstraction level.  All <table>-specific attribute parsing,
-- validation, colour overrides, and layout registration live here.
-- ---------------------------------------------------------------------------
PROCEDURE handle_table_tag(
  p_doc     IN rad_pdf_types.t_doc_handle,
  p_tag     IN VARCHAR2,
  p_options IN rad_pdf_types.t_template_options
) IS
  l_col_name VARCHAR2(200);
  l_qry      VARCHAR2(32767);
  l_allow_q  VARCHAR2(10);
  l_tdef     rad_pdf_types.t_table_def;
  l_ref_id   PLS_INTEGER;
  l_flow     rad_pdf_types.t_flowable;
  l_hdr_bg   VARCHAR2(10);
  l_alt_bg   VARCHAR2(10);
  l_brd_clr  VARCHAR2(10);
  l_row_h    NUMBER;
  l_max_rows VARCHAR2(20);
BEGIN
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

  -- If shield_query_attrs placed CHR(1)..CHR(2) sentinels in the query,
  -- resolve them now by substituting safely-quoted literal values.
  -- The bind value is wrapped in single quotes with embedded quotes doubled,
  -- so it is injected as a SQL string literal, not as arbitrary SQL text.
  IF g_qbind_active AND INSTR(l_qry, CHR(1)) > 0 THEN
    DECLARE
      l_qpos   PLS_INTEGER := 1;
      l_s1_pos PLS_INTEGER;
      l_s2_pos PLS_INTEGER;
      l_tok    VARCHAR2(200);
      l_val    VARCHAR2(4000);
      l_safe   VARCHAR2(32767) := '';
    BEGIN
      LOOP
        l_s1_pos := INSTR(l_qry, CHR(1), l_qpos);
        EXIT WHEN l_s1_pos = 0;
        l_s2_pos := INSTR(l_qry, CHR(2), l_s1_pos + 1);
        EXIT WHEN l_s2_pos = 0;
        l_safe := l_safe || SUBSTR(l_qry, l_qpos, l_s1_pos - l_qpos);
        l_tok  := SUBSTR(l_qry, l_s1_pos + 1, l_s2_pos - l_s1_pos - 1);
        l_val  := g_qbind_map(l_tok);
        -- Safely quote: wrap in ' and double any embedded '
        l_safe := l_safe || '''' || REPLACE(l_val, '''', '''''') || '''';
        l_qpos := l_s2_pos + 1;
      END LOOP;
      l_safe := l_safe || SUBSTR(l_qry, l_qpos);
      l_qry  := l_safe;
    END;
  END IF;
  IF NOT g_col_registry.EXISTS(UPPER(l_col_name)) THEN
    RAISE_APPLICATION_ERROR(c_err_table_cols,
      '<table> column set not registered: "' || l_col_name || '"');
  END IF;
  -- Security double opt-in: tag AND options must both enable queries.
  -- Two separate checks so the error message names the missing piece.
  l_allow_q := LOWER(NVL(extract_attr(p_tag, 'allow_query'), 'false'));
  IF l_allow_q != 'true' THEN
    RAISE_APPLICATION_ERROR(c_err_table_qry,
      '<table> query execution blocked: '
      || 'add allow_query="true" to the <table> tag');
  END IF;
  IF NOT NVL(p_options.allow_queries, FALSE) THEN
    RAISE_APPLICATION_ERROR(c_err_table_qry,
      '<table> query execution blocked: '
      || 'set allow_queries => TRUE in t_template_options');
  END IF;
  l_tdef.query_txt    := l_qry;
  l_tdef.col_defs     := g_col_registry(UPPER(l_col_name));
  l_tdef.color_scheme := rad_pdf_styles.default_scheme;
  l_tdef.options      := rad_pdf_units.default_table_options;

  -- Optional colour overrides (invalid hex values silently ignored).
  l_hdr_bg  := UPPER(extract_attr(p_tag, 'header_bg'));
  l_alt_bg  := UPPER(extract_attr(p_tag, 'alt_bg'));
  l_brd_clr := UPPER(extract_attr(p_tag, 'border_color'));
  IF is_valid_rgb(l_hdr_bg) THEN l_tdef.color_scheme.header_paper  := l_hdr_bg; END IF;
  IF is_valid_rgb(l_alt_bg) THEN l_tdef.color_scheme.odd_paper     := l_alt_bg; END IF;
  IF is_valid_rgb(l_brd_clr) THEN
    l_tdef.color_scheme.header_border := l_brd_clr;
    l_tdef.color_scheme.even_border   := l_brd_clr;
    l_tdef.color_scheme.odd_border    := l_brd_clr;
  END IF;

  -- Optional layout overrides.
  -- max_rows: tag attribute takes precedence over the global options cap.
  l_row_h := parse_unit_attr(p_tag, 'row_height', NULL);
  IF l_row_h IS NOT NULL THEN
    l_tdef.options.h_row_height := l_row_h;
    l_tdef.options.t_row_height := l_row_h;
  END IF;
  l_max_rows := extract_attr(p_tag, 'max_rows');
  IF l_max_rows IS NOT NULL THEN
    BEGIN
      l_tdef.options.max_rows := TO_NUMBER(l_max_rows);
    EXCEPTION WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(c_err_attr_val,
        '<table> invalid max_rows value: "' || l_max_rows || '"');
    END;
  ELSIF p_options.max_rows IS NOT NULL THEN
    l_tdef.options.max_rows := p_options.max_rows;
  END IF;

  l_ref_id            := rad_pdf_layout.register_table(p_doc, l_tdef);
  l_flow.flow_type    := rad_pdf_types.c_flow_table;
  l_flow.table_ref_id := l_ref_id;
  rad_pdf_layout.add(p_doc, l_flow);
END handle_table_tag;

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
BEGIN
  CASE p_name

    -- <spacer height="20pt"/> ------------------------------------------------
    WHEN 'spacer' THEN
      l_h := parse_unit_attr(p_tag, 'height', 12);
      rad_pdf_layout.add(p_doc, rad_pdf_layout.spacer(l_h));

    -- <hr [color="cccccc"] [width="0.5"]/>  ----------------------------------
    WHEN 'hr' THEN
      l_color := UPPER(NVL(extract_attr(p_tag, 'color'), '000000'));
      -- Silently clamp to black when the value is not a valid 6-hex colour.
      -- Consistent with <color rgb="..."> inline validation in parse_inline.
      IF NOT is_valid_rgb(l_color) THEN l_color := '000000'; END IF;
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
      handle_table_tag(p_doc, p_tag, p_options);

    ELSE
      IF NVL(p_options.strict_tags, TRUE) THEN
        RAISE_APPLICATION_ERROR(c_err_unknown_tag,
          'Unknown block tag: <' || p_name || '>');
      END IF;
  END CASE;
END dispatch_self_close;

-- ---------------------------------------------------------------------------
-- Private: render a single list item.
-- Prepends the bullet prefix (*  for <ul>, N.  for <ol>) then dispatches
-- the result as a paragraph via dispatch_paragraph.  Isolated here so the
-- prefix logic is not duplicated across the short (VARCHAR2) and long (CLOB)
-- list-parsing paths in dispatch_open_close.
-- ---------------------------------------------------------------------------
PROCEDURE emit_list_item(
  p_doc    IN     rad_pdf_types.t_doc_handle,
  p_name   IN     VARCHAR2,       -- 'ul' or 'ol'
  p_text   IN     VARCHAR2,       -- item text (may contain inline tags, ≤32767)
  p_style  IN     VARCHAR2,
  p_nr     IN OUT NOCOPY PLS_INTEGER
) IS
  l_prefix VARCHAR2(20);
BEGIN
  p_nr     := p_nr + 1;
  l_prefix := CASE WHEN p_name = 'ol'
                   THEN TO_CHAR(p_nr) || '.  '
                   ELSE '*  ' END;
  dispatch_paragraph(p_doc, l_prefix || p_text, p_style);
END emit_list_item;

-- ---------------------------------------------------------------------------
-- Private: dispatch an open/close block tag pair.
-- p_tag     = opening tag raw string (may contain attributes).
-- p_content = CLOB slice of the content between the opening and closing tags.
--             May be NULL for empty tags such as <p></p>.
--
-- <p>   : content <= 32767 chars uses the full inline-markup path.
--         content  > 32767 chars without inline tags uses the CLOB overload
--         of rad_pdf_layout.paragraph (no 32767 limit for plain text).
--         content  > 32767 chars with inline tags raises ORA-20810.
--
-- <h1>-<h6> : always converted to VARCHAR2 (headings are always short).
--             When inline tags are detected, dispatched as PARA_RUNS using
--             the predefined 'h{N}' style so mixed markup is rendered inline.
--
-- <ul>/<ol> : short lists (content <= 32767) use LOWER for case-insensitive
--             <li> search while preserving original case for extraction.
--             Long lists (content > 32767) use DBMS_LOB.INSTR.  <LI> / </LI>
--             are normalised to lowercase by Phase 0 of the render pipeline
--             before the CLOB reaches this procedure.
-- ---------------------------------------------------------------------------
PROCEDURE dispatch_open_close(
  p_doc     IN rad_pdf_types.t_doc_handle,
  p_name    IN VARCHAR2,
  p_tag     IN VARCHAR2,
  p_content IN CLOB,
  p_options IN rad_pdf_types.t_template_options
) IS
  l_style      VARCHAR2(100);
  l_level      PLS_INTEGER;
  l_cnt_len    PLS_INTEGER;      -- CLOB length of p_content
  l_content_vc VARCHAR2(32767);  -- VARCHAR2 extract for short content
  l_con_lc     VARCHAR2(32767);  -- lowercase copy for case-insensitive search
  -- List parsing
  l_li_s    PLS_INTEGER;
  l_li_e    PLS_INTEGER;
  l_li_txt  VARCHAR2(32767);
  l_cnt_li  PLS_INTEGER;
  l_nr      PLS_INTEGER;
BEGIN
  l_cnt_len := NVL(DBMS_LOB.GETLENGTH(p_content), 0);

  IF p_name = 'p' THEN
    -- -----------------------------------------------------------------------
    -- Paragraph: optional style attribute, inline markup, CLOB-aware.
    -- -----------------------------------------------------------------------
    l_style := NVL(extract_attr(p_tag, 'style'),
               NVL(p_options.default_style, 'body'));
    IF l_cnt_len = 0 THEN
      NULL;  -- <p></p>: no-op
    ELSIF l_cnt_len <= 32767 THEN
      -- Short content: full inline-markup path.
      dispatch_paragraph(p_doc, DBMS_LOB.SUBSTR(p_content, l_cnt_len, 1), l_style);
    ELSE
      -- Long content (> 32767 chars).
      IF DBMS_LOB.INSTR(p_content, '<') > 0 THEN
        -- Inline markup present: can't scan inline tags beyond VARCHAR2 limit.
        RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_template,
          '<p> content exceeds 32767 characters and contains inline tags. '
          || 'Split the paragraph into multiple <p> blocks.');
      END IF;
      -- Plain long text: use the CLOB overload of rad_pdf_layout.paragraph.
      rad_pdf_layout.add(p_doc, rad_pdf_layout.paragraph(p_content, l_style));
    END IF;

  ELSIF REGEXP_LIKE(p_name, '^h[1-6]$') THEN
    -- -----------------------------------------------------------------------
    -- Heading: extract to VARCHAR2 (headings are always short in practice).
    -- When inline tags are detected, dispatch as PARA_RUNS using the
    -- predefined 'h{N}' style so <b>, <color>, etc. render inline.
    -- -----------------------------------------------------------------------
    l_level := TO_NUMBER(SUBSTR(p_name, 2));
    IF l_cnt_len > 0 THEN
      l_content_vc := DBMS_LOB.SUBSTR(p_content, LEAST(l_cnt_len, 32767), 1);
      IF INSTR(l_content_vc, '<') > 0 THEN
        -- Inline markup detected: route through PARA_RUNS with heading style.
        dispatch_paragraph(p_doc, l_content_vc, 'h' || l_level);
      ELSE
        rad_pdf_layout.add(p_doc,
          rad_pdf_layout.heading(decode_entities(l_content_vc), l_level));
      END IF;
    END IF;

  ELSIF p_name IN ('ul', 'ol') THEN
    -- -----------------------------------------------------------------------
    -- List: parse <li>...</li> items and emit each as a paragraph.
    -- Short lists: LOWER applied to a VARCHAR2 copy for case-insensitive
    --              <li>/<li> search; extraction uses the original case.
    -- Long lists:  DBMS_LOB.INSTR on the CLOB (lowercase <li> required).
    -- Bullet prefix: '*  ' for <ul>, 'N.  ' for <ol>.
    -- Optional style="..." on the <ul>/<ol> tag sets the item text style.
    -- -----------------------------------------------------------------------
    l_style := NVL(extract_attr(p_tag, 'style'),
               NVL(p_options.default_style, 'body'));
    l_nr    := 0;

    IF l_cnt_len > 0 THEN
      IF l_cnt_len <= 32767 THEN
        -- Short list: case-insensitive <li> search via LOWER copy.
        l_content_vc := DBMS_LOB.SUBSTR(p_content, l_cnt_len, 1);
        l_con_lc     := LOWER(l_content_vc);
        l_li_s       := INSTR(l_con_lc, '<li>');
        WHILE l_li_s > 0 LOOP
          l_li_e := INSTR(l_con_lc, '</li>', l_li_s + 4);
          IF l_li_e = 0 THEN EXIT; END IF;
          l_li_txt := SUBSTR(l_content_vc, l_li_s + 4, l_li_e - (l_li_s + 4));
          emit_list_item(p_doc, p_name, l_li_txt, l_style, l_nr);
          l_li_s := INSTR(l_con_lc, '<li>', l_li_e + 5);
        END LOOP;
      ELSE
        -- Long list: CLOB-based search (<LI> normalised to <li> by Phase 0).
        l_li_s := DBMS_LOB.INSTR(p_content, '<li>');
        WHILE l_li_s > 0 LOOP
          l_li_e := DBMS_LOB.INSTR(p_content, '</li>', l_li_s + 4);
          IF l_li_e = 0 THEN EXIT; END IF;
          l_cnt_li := l_li_e - (l_li_s + 4);
          l_li_txt := CASE WHEN l_cnt_li > 0
                           THEN DBMS_LOB.SUBSTR(p_content,
                                  LEAST(l_cnt_li, 32767), l_li_s + 4)
                           ELSE NULL END;
          emit_list_item(p_doc, p_name, l_li_txt, l_style, l_nr);
          l_li_s := DBMS_LOB.INSTR(p_content, '<li>', l_li_e + 5);
        END LOOP;
      END IF;
    END IF;

  ELSE
    IF NVL(p_options.strict_tags, TRUE) THEN
      RAISE_APPLICATION_ERROR(c_err_unknown_tag,
        'Unknown block tag: <' || p_name || '>');
    END IF;
  END IF;
END dispatch_open_close;

-- ---------------------------------------------------------------------------
-- Private: quote-aware tag-end search.
-- Returns the 1-based CLOB position of the '>' that closes the tag starting
-- at p_start, skipping any '>' characters that appear inside single- or
-- double-quoted attribute values.
--
-- Without this, a query attribute such as
--   query="SELECT * FROM emp WHERE sal > 1000"
-- causes the naive DBMS_LOB.INSTR(clob,'>') to stop at the '>' inside the
-- SQL expression, truncating the tag and losing the query attribute entirely.
--
-- Algorithm: read the CLOB in 512-byte chunks from p_start; scan each chunk
-- character-by-character tracking quote state.  Returns 0 when no unquoted
-- '>' is found (caller raises ORA-20810).
-- ---------------------------------------------------------------------------
FUNCTION find_tag_end(
  p_clob  IN CLOB,
  p_start IN PLS_INTEGER,
  p_len   IN PLS_INTEGER
) RETURN PLS_INTEGER IS
  c_chunk  CONSTANT PLS_INTEGER := 512;
  l_pos    PLS_INTEGER := p_start;
  -- Buffer must hold c_chunk CHARACTERS in the database character set.
  -- AL32UTF8 uses up to 4 bytes per character, so 512 chars * 4 = 2048 bytes.
  -- Declaring VARCHAR2(512) in a BYTE-semantics database (NLS_LENGTH_SEMANTICS=BYTE)
  -- would overflow when the chunk contains multi-byte characters (e.g. em-dash U+2014
  -- = 3 bytes), causing ORA-06502.  2048 bytes is safe for any UTF-8 content.
  l_buf    VARCHAR2(2048);
  l_buflen PLS_INTEGER;
  l_c      VARCHAR2(1);
  l_inq    VARCHAR2(1) := NULL;   -- quote char we are inside, or NULL
  l_i      PLS_INTEGER;
BEGIN
  WHILE l_pos <= p_len LOOP
    l_buflen := LEAST(c_chunk, p_len - l_pos + 1);
    l_buf    := DBMS_LOB.SUBSTR(p_clob, l_buflen, l_pos);
    l_i := 1;
    WHILE l_i <= l_buflen LOOP
      l_c := SUBSTR(l_buf, l_i, 1);
      IF l_inq IS NULL THEN
        IF l_c = '>'                     THEN RETURN l_pos + l_i - 1; END IF;
        IF l_c = '"' OR l_c = CHR(39)   THEN l_inq := l_c; END IF;
      ELSIF l_c = l_inq THEN
        l_inq := NULL;
      END IF;
      l_i := l_i + 1;
    END LOOP;
    l_pos := l_pos + l_buflen;
  END LOOP;
  RETURN 0;   -- unquoted '>' not found
END find_tag_end;

-- ---------------------------------------------------------------------------
-- Private: shield #TOKEN# placeholders inside <table query="..."/> attributes
-- from Phase 2 (apply_binds_clob) by replacing them with
--   CHR(1) || UPPER(token_name) || CHR(2)
-- and storing the bind value in g_qbind_map.  handle_table_tag later
-- resolves these sentinels via safely-quoted string literals, so the values
-- never end up concatenated into a SQL string.
--
-- Returns p_src unchanged (same LOB locator) when no shielding is needed,
-- or a new temporary CLOB when at least one sentinel was written.
-- Also sets g_qbind_active := TRUE when any sentinel was placed.
-- ---------------------------------------------------------------------------
FUNCTION shield_query_attrs(
  p_src   IN CLOB,
  p_binds IN rad_pdf_types.t_bind_array
) RETURN CLOB IS
  -- Sentinel delimiters (never appear in SQL or template text)
  c_s1 CONSTANT VARCHAR2(1) := CHR(1);
  c_s2 CONSTANT VARCHAR2(1) := CHR(2);

  TYPE t_lookup IS TABLE OF BINARY_INTEGER INDEX BY VARCHAR2(204);
  l_lookup  t_lookup;

  l_src_len  PLS_INTEGER;
  l_pos      PLS_INTEGER := 1;
  l_tbl_pos  PLS_INTEGER;
  l_tag_end  PLS_INTEGER;
  l_tag_raw  VARCHAR2(32767);
  l_qry      VARCHAR2(32767);
  l_qry_new  VARCHAR2(32767);
  l_any      BOOLEAN := FALSE;
  l_dst      CLOB;
  i          BINARY_INTEGER;

  -- Scan query VARCHAR2 for #TOKEN# and replace matched tokens with sentinels.
  FUNCTION process_query(p_q IN VARCHAR2) RETURN VARCHAR2 IS
    l_out  VARCHAR2(32767) := '';
    l_qpos PLS_INTEGER := 1;
    l_qlen PLS_INTEGER := LENGTH(p_q);
    l_h1   PLS_INTEGER;
    l_h2   PLS_INTEGER;
    l_slen PLS_INTEGER;
    l_key  VARCHAR2(200);
    l_tok  VARCHAR2(204);
  BEGIN
    IF l_qlen = 0 OR INSTR(p_q, '#') = 0 THEN RETURN p_q; END IF;
    LOOP
      l_h1 := INSTR(p_q, '#', l_qpos);
      IF l_h1 = 0 THEN
        l_out := l_out || SUBSTR(p_q, l_qpos);
        EXIT;
      END IF;
      l_out := l_out || SUBSTR(p_q, l_qpos, l_h1 - l_qpos);
      -- '##' escape -> single '#', not a token
      IF l_h1 < l_qlen AND SUBSTR(p_q, l_h1 + 1, 1) = '#' THEN
        l_out  := l_out || '#';
        l_qpos := l_h1 + 2;
        CONTINUE;
      END IF;
      l_h2 := INSTR(p_q, '#', l_h1 + 1);
      IF l_h2 = 0 THEN
        l_out := l_out || SUBSTR(p_q, l_h1);
        EXIT;
      END IF;
      l_slen := l_h2 - l_h1 - 1;
      IF l_slen = 0 OR l_slen > 200 THEN
        l_out  := l_out || '#';
        l_qpos := l_h1 + 1;
        CONTINUE;
      END IF;
      l_key := SUBSTR(p_q, l_h1 + 1, l_slen);
      l_tok := '#' || UPPER(l_key) || '#';
      IF l_lookup.EXISTS(l_tok) THEN
        -- Matched bind: store value in g_qbind_map, emit sentinel
        g_qbind_map(UPPER(l_key)) := p_binds(l_lookup(l_tok)).value;
        l_out  := l_out || c_s1 || UPPER(l_key) || c_s2;
        l_any  := TRUE;
      ELSE
        -- No matching bind: write verbatim (will stay as #TOKEN# in Phase 2)
        l_out  := l_out || '#' || l_key || '#';
      END IF;
      l_qpos := l_h2 + 1;
    END LOOP;
    RETURN l_out;
  END process_query;

  -- Copy p_src[p_from..p_to] to l_dst
  PROCEDURE copy_slice(p_from IN PLS_INTEGER, p_to IN PLS_INTEGER) IS
  BEGIN
    IF p_to >= p_from THEN
      DBMS_LOB.COPY(l_dst, p_src, p_to - p_from + 1,
                    NVL(DBMS_LOB.GETLENGTH(l_dst), 0) + 1, p_from);
    END IF;
  END copy_slice;

  PROCEDURE append_str(p_str IN VARCHAR2) IS
  BEGIN
    IF p_str IS NOT NULL THEN
      DBMS_LOB.WRITEAPPEND(l_dst, LENGTH(p_str), p_str);
    END IF;
  END append_str;

BEGIN
  -- Build bind lookup
  i := p_binds.FIRST;
  WHILE i IS NOT NULL LOOP
    l_lookup('#' || UPPER(p_binds(i).key) || '#') := i;
    i := p_binds.NEXT(i);
  END LOOP;

  -- Reset session state
  g_qbind_map.DELETE;
  g_qbind_active := FALSE;

  l_src_len := NVL(DBMS_LOB.GETLENGTH(p_src), 0);
  IF l_src_len = 0 THEN RETURN p_src; END IF;

  -- Quick check: any <table at all?
  IF DBMS_LOB.INSTR(p_src, '<table', 1) = 0
     AND DBMS_LOB.INSTR(p_src, '<TABLE', 1) = 0
  THEN
    RETURN p_src;
  END IF;

  DBMS_LOB.CREATETEMPORARY(l_dst, TRUE);

  LOOP
    -- Find next <table (try lowercase first, then uppercase)
    DECLARE
      l_p1 PLS_INTEGER := DBMS_LOB.INSTR(p_src, '<table', l_pos);
      l_p2 PLS_INTEGER := DBMS_LOB.INSTR(p_src, '<TABLE', l_pos);
    BEGIN
      IF    l_p1 > 0 AND l_p2 > 0 THEN l_tbl_pos := LEAST(l_p1, l_p2);
      ELSIF l_p1 > 0               THEN l_tbl_pos := l_p1;
      ELSIF l_p2 > 0               THEN l_tbl_pos := l_p2;
      ELSE  l_tbl_pos := 0;
      END IF;
    END;

    IF l_tbl_pos = 0 THEN
      -- No more <table> tags: flush remainder and exit
      copy_slice(l_pos, l_src_len);
      EXIT;
    END IF;

    -- Find '>' that closes this tag (quote-aware)
    l_tag_end := find_tag_end(p_src, l_tbl_pos, l_src_len);
    IF l_tag_end = 0 THEN
      -- Unclosed tag: flush remainder verbatim (do_render will raise the error)
      copy_slice(l_pos, l_src_len);
      EXIT;
    END IF;

    -- Extract tag text (<=32767 chars; query attrs are well within this)
    l_tag_raw := DBMS_LOB.SUBSTR(p_src,
                   LEAST(l_tag_end - l_tbl_pos + 1, 32767), l_tbl_pos);

    -- Try to extract and shield the query attribute
    l_qry     := extract_attr(l_tag_raw, 'query');
    l_qry_new := process_query(l_qry);

    IF l_qry IS NULL OR l_qry_new = l_qry THEN
      -- No query attr or nothing to shield: copy tag verbatim
      copy_slice(l_pos, l_tag_end);
    ELSE
      -- Rebuild tag with shielded query value.
      -- Replace only the first occurrence of the exact quoted value.
      DECLARE
        l_old VARCHAR2(32767);
        l_new VARCHAR2(32767);
        l_rep_pos PLS_INTEGER;
      BEGIN
        -- Determine which quote style wraps the value (double or single)
        IF INSTR(l_tag_raw, '"' || l_qry || '"') > 0 THEN
          l_old := '"' || l_qry     || '"';
          l_new := '"' || l_qry_new || '"';
        ELSE
          l_old := CHR(39) || l_qry     || CHR(39);
          l_new := CHR(39) || l_qry_new || CHR(39);
        END IF;
        l_rep_pos := INSTR(l_tag_raw, l_old);
        IF l_rep_pos > 0 THEN
          -- Copy: source[l_pos..l_tbl_pos-1] + tag_prefix + new_qry_val + tag_suffix
          copy_slice(l_pos, l_tbl_pos - 1);
          append_str(SUBSTR(l_tag_raw, 1, l_rep_pos - 1));  -- before old attr
          append_str(l_new);
          append_str(SUBSTR(l_tag_raw, l_rep_pos + LENGTH(l_old)));  -- after old attr
        ELSE
          -- Safety fallback: copy tag verbatim
          copy_slice(l_pos, l_tag_end);
        END IF;
      END;
    END IF;

    l_pos := l_tag_end + 1;
  END LOOP;

  IF NOT l_any THEN
    -- No sentinels were actually written: free temp CLOB and return original
    IF l_dst IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_dst) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_dst);
    END IF;
    RETURN p_src;
  END IF;

  g_qbind_active := TRUE;
  RETURN l_dst;
END shield_query_attrs;

-- ---------------------------------------------------------------------------
-- Private: CLOB-based bind substitution.  Replaces #KEY# tokens throughout
-- p_src using the supplied bind array and appends the result to p_dest.
-- Handles CLOBs of any size (no 32767-character limit).
--
-- Token rules:
--   ##       ->  literal '#'
--   #KEY#    ->  bind value (auto-escaped unless raw=TRUE on the bind entry)
--   #OTHER#  ->  written verbatim when no matching bind key exists
--
-- Raises c_err_template when a token present in the source maps to a NULL
-- bind value (guards against silent token removal by Oracle REPLACE).
-- ---------------------------------------------------------------------------
PROCEDURE apply_binds_clob(
  p_src   IN CLOB,
  p_dest  IN OUT NOCOPY CLOB,
  p_binds IN rad_pdf_types.t_bind_array
) IS
  TYPE t_lookup IS TABLE OF BINARY_INTEGER INDEX BY VARCHAR2(204);
  l_lookup  t_lookup;
  l_src_len PLS_INTEGER;
  l_pos     PLS_INTEGER;
  l_hash1   PLS_INTEGER;
  l_hash2   PLS_INTEGER;
  l_key     VARCHAR2(200);
  l_token   VARCHAR2(204);
  l_val     VARCHAR2(32767);
  l_seg_len PLS_INTEGER;
  i         BINARY_INTEGER;

  -- Append p_src[p_from..p_to] to p_dest using DBMS_LOB.COPY.
  -- COPY handles CLOBs of any length; no VARCHAR2 32767 limit.
  PROCEDURE copy_src_slice(p_from IN PLS_INTEGER, p_to IN PLS_INTEGER) IS
  BEGIN
    IF p_to >= p_from THEN
      DBMS_LOB.COPY(p_dest, p_src, p_to - p_from + 1,
                    NVL(DBMS_LOB.GETLENGTH(p_dest), 0) + 1, p_from);
    END IF;
  END copy_src_slice;

BEGIN
  -- Build lookup: '#UPPER(KEY)#' -> index into p_binds
  i := p_binds.FIRST;
  WHILE i IS NOT NULL LOOP
    l_lookup('#' || UPPER(p_binds(i).key) || '#') := i;
    i := p_binds.NEXT(i);
  END LOOP;

  l_src_len := NVL(DBMS_LOB.GETLENGTH(p_src), 0);
  IF l_src_len = 0 THEN RETURN; END IF;

  l_pos := 1;
  LOOP
    -- Locate the next '#' in the source
    l_hash1 := DBMS_LOB.INSTR(p_src, '#', l_pos);
    IF l_hash1 = 0 OR l_hash1 > l_src_len THEN
      -- No more '#': copy remainder and exit
      IF l_pos <= l_src_len THEN
        copy_src_slice(l_pos, l_src_len);
      END IF;
      EXIT;
    END IF;

    -- Copy the segment before this '#'
    IF l_hash1 > l_pos THEN
      copy_src_slice(l_pos, l_hash1 - 1);
    END IF;

    -- '##' escape sequence -> single '#'
    IF l_hash1 < l_src_len
       AND DBMS_LOB.SUBSTR(p_src, 1, l_hash1 + 1) = '#'
    THEN
      DBMS_LOB.WRITEAPPEND(p_dest, 1, '#');
      l_pos := l_hash1 + 2;
      CONTINUE;
    END IF;

    -- Find the closing '#' of the token
    l_hash2 := DBMS_LOB.INSTR(p_src, '#', l_hash1 + 1);
    IF l_hash2 = 0 THEN
      -- No closing '#': write the lone '#' literally and advance
      DBMS_LOB.WRITEAPPEND(p_dest, 1, '#');
      l_pos := l_hash1 + 1;
    ELSE
      l_seg_len := l_hash2 - l_hash1 - 1;
      IF l_seg_len = 0 THEN
        -- Defensive: adjacent '##' not caught by earlier check (unreachable)
        DBMS_LOB.WRITEAPPEND(p_dest, 1, '#');
        l_pos := l_hash2 + 1;
      ELSIF l_seg_len > 200 THEN
        -- Too long to be a valid bind key; treat '#' as a literal character
        DBMS_LOB.WRITEAPPEND(p_dest, 1, '#');
        l_pos := l_hash1 + 1;
      ELSE
        l_key   := DBMS_LOB.SUBSTR(p_src, l_seg_len, l_hash1 + 1);
        l_token := '#' || UPPER(l_key) || '#';
        IF l_lookup.EXISTS(l_token) THEN
          i := l_lookup(l_token);
          IF p_binds(i).value IS NULL THEN
            RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_template,
              'Bind key "' || UPPER(p_binds(i).key)
              || '" is NULL. Use NVL to supply a safe default'
              || ' (e.g. NVL(value, 0) or NVL(value, '' '')).');
          END IF;
          IF NVL(p_binds(i).raw, FALSE) THEN
            l_val := p_binds(i).value;
          ELSE
            l_val := escape_value(p_binds(i).value);
          END IF;
          IF l_val IS NOT NULL THEN
            DBMS_LOB.WRITEAPPEND(p_dest, LENGTH(l_val), l_val);
          END IF;
        ELSE
          -- Unknown token: write verbatim (no matching bind key)
          l_val := '#' || l_key || '#';
          DBMS_LOB.WRITEAPPEND(p_dest, LENGTH(l_val), l_val);
        END IF;
        l_pos := l_hash2 + 1;
      END IF;
    END IF;
  END LOOP;
END apply_binds_clob;

-- ---------------------------------------------------------------------------
-- Private: evaluate <if bind="KEY">...</if> conditional blocks.
-- Copies p_src to p_dest, including block content only when the bind key
-- resolves to a non-NULL value in p_binds.  The <if>…</if> wrapper tags
-- are always removed; bind token substitution runs in the subsequent
-- apply_binds_clob pass.
--
-- Rules:
--   - Condition TRUE  (key exists, value non-NULL): content is copied as-is.
--   - Condition FALSE (key absent or value NULL):   the entire block is skipped.
--   - Nested <if> blocks are not supported (first </if> closes the block).
--   - Raises c_err_template when bind="KEY" is missing or </if> is absent.
-- ---------------------------------------------------------------------------
PROCEDURE apply_conditionals(
  p_src   IN CLOB,
  p_dest  IN OUT NOCOPY CLOB,
  p_binds IN rad_pdf_types.t_bind_array
) IS
  TYPE t_cond_lookup IS TABLE OF BOOLEAN INDEX BY VARCHAR2(200);
  l_cond_lkp  t_cond_lookup;
  l_src_len   PLS_INTEGER;
  l_pos       PLS_INTEGER;
  l_if_start  PLS_INTEGER;
  l_tag_end   PLS_INTEGER;
  l_tag_raw   VARCHAR2(32767);
  l_bind_key  VARCHAR2(200);
  l_close_pos PLS_INTEGER;
  l_cnt_start PLS_INTEGER;
  l_cnt_len   PLS_INTEGER;
  c_close_tag CONSTANT VARCHAR2(6) := '</if>';
  c_open_pfx  CONSTANT VARCHAR2(4) := '<if ';
  i           BINARY_INTEGER;

  PROCEDURE copy_src_slice(p_from IN PLS_INTEGER, p_to IN PLS_INTEGER) IS
  BEGIN
    IF p_to >= p_from THEN
      DBMS_LOB.COPY(p_dest, p_src, p_to - p_from + 1,
                    NVL(DBMS_LOB.GETLENGTH(p_dest), 0) + 1, p_from);
    END IF;
  END copy_src_slice;

BEGIN
  -- Build lookup: UPPER(key) present only when the value is non-NULL
  i := p_binds.FIRST;
  WHILE i IS NOT NULL LOOP
    IF p_binds(i).value IS NOT NULL THEN
      l_cond_lkp(UPPER(p_binds(i).key)) := TRUE;
    END IF;
    i := p_binds.NEXT(i);
  END LOOP;

  l_src_len := NVL(DBMS_LOB.GETLENGTH(p_src), 0);
  IF l_src_len = 0 THEN RETURN; END IF;

  l_pos := 1;
  LOOP
    -- Locate the next '<if ' prefix
    l_if_start := DBMS_LOB.INSTR(p_src, c_open_pfx, l_pos);
    IF l_if_start = 0 OR l_if_start > l_src_len THEN
      -- No more <if> blocks: copy remainder
      IF l_pos <= l_src_len THEN
        copy_src_slice(l_pos, l_src_len);
      END IF;
      EXIT;
    END IF;

    -- Copy content before '<if '
    IF l_if_start > l_pos THEN
      copy_src_slice(l_pos, l_if_start - 1);
    END IF;

    -- Find the closing '>' of the <if ...> tag (quote-aware)
    l_tag_end := find_tag_end(p_src, l_if_start, l_src_len);
    IF l_tag_end = 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_template,
        'Unclosed <if> tag at position ' || l_if_start);
    END IF;

    -- Extract tag text for attribute parsing (up to 32767 chars)
    l_tag_raw  := DBMS_LOB.SUBSTR(p_src,
                    LEAST(l_tag_end - l_if_start + 1, 32767), l_if_start);
    l_bind_key := UPPER(extract_attr(l_tag_raw, 'bind'));
    IF l_bind_key IS NULL THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_template,
        '<if> tag missing required "bind" attribute at position ' || l_if_start);
    END IF;

    -- Locate the matching </if>
    l_cnt_start := l_tag_end + 1;
    l_close_pos := DBMS_LOB.INSTR(p_src, c_close_tag, l_cnt_start);
    IF l_close_pos = 0 THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_template,
        'No matching </if> for <if bind="' || l_bind_key
        || '"> at position ' || l_if_start);
    END IF;

    -- Condition TRUE: copy the block content (between '>' and '</if>')
    IF l_cond_lkp.EXISTS(l_bind_key) THEN
      l_cnt_len := l_close_pos - l_cnt_start;
      IF l_cnt_len > 0 THEN
        copy_src_slice(l_cnt_start, l_close_pos - 1);
      END IF;
    END IF;
    -- Condition FALSE: skip the entire <if>...</if> block

    l_pos := l_close_pos + LENGTH(c_close_tag);
  END LOOP;
END apply_conditionals;

-- ---------------------------------------------------------------------------
-- Private: main CLOB render loop.
-- Scans the CLOB for block-level tags using DBMS_LOB.INSTR / DBMS_LOB.SUBSTR.
-- Text between block tags is silently skipped (whitespace / newlines).
-- Options are normalised before entering the loop.
--
-- Block content is extracted into a temporary CLOB (no 32767-char limit).
-- dispatch_open_close handles content > 32767 for the tags that support it
-- (plain <p>, long lists) and raises ORA-20810 when inline markup prevents it.
--
-- default_font_name / default_font_style / default_font_size:
--   When any of these are set, a derived style variant is created lazily
--   from the effective default_style and used as the new default_style for
--   the duration of this render call.  This makes the font options work.
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
  l_content   CLOB;             -- temporary CLOB for each block's content
  l_is_self   BOOLEAN;
  l_opts      rad_pdf_types.t_template_options;
  -- For default_font_* style derivation
  l_dft_fmt   rad_pdf_types.t_cell_format;
  l_dft_sty   VARCHAR2(150);
BEGIN
  -- -------------------------------------------------------------------------
  -- Normalise options (apply defaults for NULL fields).
  -- -------------------------------------------------------------------------
  l_opts.default_font_name  := p_options.default_font_name;
  l_opts.default_font_style := p_options.default_font_style;
  l_opts.default_font_size  := p_options.default_font_size;
  l_opts.default_style      := NVL(p_options.default_style, 'body');
  l_opts.strict_tags        := NVL(p_options.strict_tags,   TRUE);
  l_opts.allow_queries      := NVL(p_options.allow_queries, FALSE);

  -- -------------------------------------------------------------------------
  -- Implement default_font_name / default_font_style / default_font_size.
  -- Create a derived style variant from the effective default_style and
  -- substitute it as l_opts.default_style for this render call.
  -- -------------------------------------------------------------------------
  IF l_opts.default_font_name  IS NOT NULL
     OR l_opts.default_font_style IS NOT NULL
     OR l_opts.default_font_size  IS NOT NULL
  THEN
    l_dft_sty := l_opts.default_style || '__dft'
      || CASE WHEN l_opts.default_font_name IS NOT NULL
              THEN '_fn' || LOWER(REGEXP_REPLACE(l_opts.default_font_name,
                                                 '[^a-zA-Z0-9]', ''))
              ELSE '' END
      || CASE WHEN l_opts.default_font_style IS NOT NULL
              THEN '_' || LOWER(l_opts.default_font_style)
              ELSE '' END
      || CASE WHEN l_opts.default_font_size IS NOT NULL
              THEN '_s' || TO_CHAR(ROUND(l_opts.default_font_size))
              ELSE '' END;

    IF NOT rad_pdf_styles.exists_style(l_dft_sty) THEN
      l_dft_fmt := rad_pdf_styles.get(l_opts.default_style);
      IF l_opts.default_font_name  IS NOT NULL THEN
        l_dft_fmt.font_name  := l_opts.default_font_name;
      END IF;
      IF l_opts.default_font_style IS NOT NULL THEN
        l_dft_fmt.font_style := l_opts.default_font_style;
      END IF;
      IF l_opts.default_font_size  IS NOT NULL THEN
        l_dft_fmt.font_size  := l_opts.default_font_size;
      END IF;
      rad_pdf_styles.define(
        p_name       => l_dft_sty,
        p_font_name  => l_dft_fmt.font_name,
        p_font_style => l_dft_fmt.font_style,
        p_font_size  => l_dft_fmt.font_size,
        p_font_color => l_dft_fmt.font_color,
        p_back_color => l_dft_fmt.back_color);
    END IF;
    l_opts.default_style := l_dft_sty;
  END IF;

  l_len := NVL(DBMS_LOB.GETLENGTH(p_clob), 0);
  IF l_len = 0 THEN RETURN; END IF;

  WHILE l_pos <= l_len LOOP
    l_content := NULL;  -- reset each iteration for EXCEPTION cleanup

    -- Locate next '<'
    l_tag_start := DBMS_LOB.INSTR(p_clob, '<', l_pos);
    IF l_tag_start = 0 OR l_tag_start > l_len THEN EXIT; END IF;

    -- Locate the '>' that closes this tag, skipping any '>' inside
    -- quoted attribute values (quote-aware; fixes SQL comparisons in
    -- <table query="... WHERE col > val ..."/>).
    l_tag_end := find_tag_end(p_clob, l_tag_start, l_len);
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

          -- Extract block content into a temporary CLOB (no 32767 limit).
          -- DBMS_LOB.COPY requires amount > 0; adjacent tags yield NULL.
          l_cnt_len := l_close_pos - l_tag_end - 1;
          IF l_cnt_len > 0 THEN
            DBMS_LOB.CREATETEMPORARY(l_content, TRUE);
            DBMS_LOB.COPY(l_content, p_clob, l_cnt_len, 1, l_tag_end + 1);
          END IF;

          dispatch_open_close(p_doc, l_tag_name, l_tag_raw, l_content, l_opts);

          -- Free the content CLOB after dispatching
          IF l_content IS NOT NULL
             AND DBMS_LOB.ISTEMPORARY(l_content) = 1
          THEN
            DBMS_LOB.FREETEMPORARY(l_content);
            l_content := NULL;
          END IF;

          l_pos := l_close_pos + LENGTH(l_close_tag);
        END IF;
      END IF;
    END IF;

  END LOOP;
EXCEPTION
  WHEN OTHERS THEN
    IF l_content IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_content) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_content);
    END IF;
    RAISE;
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

-- CLOB + binds — full CLOB pipeline, no size limit on the template.
-- Phase 0: normalise uppercase <IF ...> / </IF> to lowercase (DBMS_LOB.INSTR
--          is case-sensitive; Oracle REPLACE works on CLOB).
-- Phase 1 (when <if> blocks are present): evaluate conditional blocks.
-- Phase 2: substitute bind tokens via CLOB-level scanning.
-- Phase 3: parse and render the resulting CLOB.
PROCEDURE render(
  p_doc     IN rad_pdf_types.t_doc_handle,
  p_clob    IN CLOB,
  p_binds   IN rad_pdf_types.t_bind_array,
  p_options IN rad_pdf_types.t_template_options DEFAULT NULL
) IS
  l_bound    CLOB;
  l_cond     CLOB;
  l_src      CLOB;      -- normalised source
  l_shielded CLOB;      -- after shield_query_attrs (= l_src when no shielding)
BEGIN
  rad_pdf_ctx.assert_valid(p_doc);

  -- Phase 0: normalise uppercase block-tag names (<IF>/<LI> → lowercase).
  l_src := normalize_clob(p_clob, p_normalise_if => TRUE);

  -- Phase 0b: protect #TOKEN# inside <table query="..."> from Phase 2 text
  -- substitution.  Tokens in query attributes are replaced with
  -- CHR(1)..CHR(2) sentinels; their values are stored in g_qbind_map and
  -- injected as safely-quoted SQL literals in handle_table_tag.
  l_shielded := shield_query_attrs(l_src, p_binds);

  DBMS_LOB.CREATETEMPORARY(l_bound, TRUE);
  IF DBMS_LOB.INSTR(l_shielded, '<if ', 1) > 0 THEN
    -- Phase 1: resolve <if bind="KEY"> conditional blocks
    DBMS_LOB.CREATETEMPORARY(l_cond, TRUE);
    apply_conditionals(l_shielded, l_cond, p_binds);
    -- Phase 2: bind substitution on the post-conditional CLOB
    apply_binds_clob(l_cond, l_bound, p_binds);
    DBMS_LOB.FREETEMPORARY(l_cond);
  ELSE
    -- No conditionals: bind substitution directly on the shielded CLOB
    apply_binds_clob(l_shielded, l_bound, p_binds);
  END IF;
  do_render(p_doc, l_bound, p_options);
  DBMS_LOB.FREETEMPORARY(l_bound);
  IF l_shielded IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_shielded) = 1 THEN
    DBMS_LOB.FREETEMPORARY(l_shielded);
  END IF;
  IF l_src IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_src) = 1 THEN
    DBMS_LOB.FREETEMPORARY(l_src);
  END IF;
  -- Reset session-scoped query-bind state
  g_qbind_active := FALSE;
  g_qbind_map.DELETE;
EXCEPTION
  WHEN OTHERS THEN
    g_qbind_active := FALSE;
    g_qbind_map.DELETE;
    IF DBMS_LOB.ISTEMPORARY(l_bound)    = 1 THEN DBMS_LOB.FREETEMPORARY(l_bound);    END IF;
    IF DBMS_LOB.ISTEMPORARY(l_cond)     = 1 THEN DBMS_LOB.FREETEMPORARY(l_cond);     END IF;
    IF l_shielded IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_shielded) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_shielded);
    END IF;
    IF l_src IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_src) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_src);
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
-- Phase 0: normalise <LI> / </LI> for the CLOB-level list scanner, matching
-- the same normalisation applied by the binds overload.
PROCEDURE render(
  p_doc     IN rad_pdf_types.t_doc_handle,
  p_clob    IN CLOB,
  p_options IN rad_pdf_types.t_template_options DEFAULT NULL
) IS
  l_src CLOB;  -- normalised source (alias to p_clob when no normalisation needed)
BEGIN
  rad_pdf_ctx.assert_valid(p_doc);
  -- Phase 0: normalise uppercase <LI> / </LI> → lowercase.
  l_src := normalize_clob(p_clob);
  do_render(p_doc, l_src, p_options);
  IF l_src IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_src) = 1 THEN
    DBMS_LOB.FREETEMPORARY(l_src);
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    IF l_src IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_src) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_src);
    END IF;
    RAISE;
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
