CREATE OR REPLACE PACKAGE BODY rad_pdf_pager AS

  -- a loaded font: its index in the document and its metrics per em
  TYPE t_fm IS RECORD (idx PLS_INTEGER, ascn NUMBER, dsc NUMBER, gap NUMBER);
  TYPE t_fms IS TABLE OF t_fm INDEX BY VARCHAR2(120);

  -- a token of a paragraph: T text, SP spaces, TAB, BR line break, IMG image, FLD field
  TYPE t_tok IS RECORD (
    kind VARCHAR2(3), txt VARCHAR2(32767), fidx PLS_INTEGER, sz NUMBER, color VARCHAR2(6), ul CHAR(1),
    w NUMBER, ascn NUMBER, lh NUMBER, res PLS_INTEGER, ih NUMBER, fcode VARCHAR2(8), x NUMBER := 0);
  TYPE t_toks IS TABLE OF t_tok INDEX BY PLS_INTEGER;
  TYPE t_line IS RECORD (first PLS_INTEGER, last PLS_INTEGER, h NUMBER, ascn NUMBER);
  TYPE t_lines IS TABLE OF t_line INDEX BY PLS_INTEGER;
  TYPE t_plan IS RECORD (toks t_toks, lines t_lines, para rad_pdf_ri.t_para_fmt, h NUMBER := 0);

  -- a drawing operation (y from the top of the page): T text, F filled rectangle, L line, I image
  TYPE t_op IS RECORD (
    pg PLS_INTEGER, kind CHAR(1), x NUMBER, y NUMBER, x2 NUMBER, y2 NUMBER, w NUMBER, h NUMBER,
    txt VARCHAR2(32767), fidx PLS_INTEGER, sz NUMBER, color VARCHAR2(6), lw NUMBER, fcode VARCHAR2(8), res PLS_INTEGER);
  TYPE t_ops IS TABLE OF t_op INDEX BY PLS_INTEGER;

  TYPE t_imgids IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;   -- resource of the instance -> image of the document
  TYPE t_frames IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

  -- one render (never package state)
  TYPE t_st IS RECORD (
    doc      rad_pdf_types.t_doc_handle,
    inst     rad_pdf_ri.t_ri,
    files    t_font_files,
    opt      t_options,
    fms      t_fms,
    ops      t_ops,
    imgs     t_imgids,
    page_w   NUMBER, page_h NUMBER,
    left     NUMBER, width NUMBER,
    pg       PLS_INTEGER,                                -- the current page
    y        NUMBER,                                     -- the cursor on it (from the top)
    tops     t_frames,                                   -- the body frame of each page (R3: measured per page)
    bottoms  t_frames,
    after    NUMBER := 0,                                -- the space_after still to place
    fresh    BOOLEAN := FALSE,                           -- at the top of a page after an automatic break
    guess    PLS_INTEGER := 1,                           -- the page count the fields are measured with
    dfmt     rad_pdf_ri.t_run_fmt,                       -- the format of an empty paragraph (the first run's)
    dry      BOOLEAN := FALSE);                          -- measuring: no operation recorded

  PROCEDURE fail(p_code IN PLS_INTEGER, p_msg IN VARCHAR2) IS
  BEGIN
    raise_application_error(p_code, CASE p_code WHEN c_err_font THEN '[PDF_FONT] ' WHEN c_err_budget THEN '[PDF_BUDGET] '
                                                ELSE '[PDF_LAYOUT] ' END || substr(p_msg, 1, 1900));
  END fail;

  -- ---------------------------------------------------------------------------
  -- fonts (D3)
  -- ---------------------------------------------------------------------------
  FUNCTION substitute(p_family IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE lower(p_family)
             WHEN 'calibri'         THEN 'Carlito'
             WHEN 'cambria'         THEN 'Caladea'
             WHEN 'arial'           THEN 'Liberation Sans'
             WHEN 'times new roman' THEN 'Liberation Serif'
             WHEN 'courier new'     THEN 'Liberation Mono'
             ELSE p_family END;
  END substitute;

  FUNCTION u16(p_b IN BLOB, p_pos IN PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN
    RETURN to_number(rawtohex(dbms_lob.substr(p_b, 2, p_pos)), 'XXXX');
  END u16;

  FUNCTION s16(p_b IN BLOB, p_pos IN PLS_INTEGER) RETURN PLS_INTEGER IS
    l PLS_INTEGER := u16(p_b, p_pos);
  BEGIN
    RETURN CASE WHEN l >= 32768 THEN l - 65536 ELSE l END;
  END s16;

  -- the position (1-based) of a table of a TrueType font, NULL when absent
  FUNCTION ttf_table(p_b IN BLOB, p_tag IN VARCHAR2) RETURN PLS_INTEGER IS
    l_n PLS_INTEGER := u16(p_b, 5);
  BEGIN
    FOR i IN 0 .. l_n - 1 LOOP
      IF utl_raw.cast_to_varchar2(dbms_lob.substr(p_b, 4, 13 + i * 16)) = p_tag THEN
        RETURN to_number(rawtohex(dbms_lob.substr(p_b, 4, 13 + i * 16 + 8)), 'XXXXXXXX') + 1;
      END IF;
    END LOOP;
    RETURN NULL;
  END ttf_table;

  FUNCTION font_of(st IN OUT NOCOPY t_st, f IN rad_pdf_ri.t_run_fmt) RETURN t_fm IS
    l_var  CHAR(1) := CASE WHEN f.bold = 'Y' AND f.italic = 'Y' THEN 'X' WHEN f.bold = 'Y' THEN 'B'
                           WHEN f.italic = 'Y' THEN 'I' ELSE 'R' END;
    l_key  VARCHAR2(120) := f.font || '|' || l_var;
    l_file PLS_INTEGER;
    l_b    BLOB;
    l_head PLS_INTEGER;
    l_hhea PLS_INTEGER;
    l_os2  PLS_INTEGER;
    l_upem NUMBER;
    l_fs   PLS_INTEGER;
    fm     t_fm;
  BEGIN
    IF st.fms.EXISTS(l_key) THEN RETURN st.fms(l_key); END IF;
    -- the original first (an installation may upload it), then the fixed substitute
    FOR pass IN 1 .. 2 LOOP
      FOR i IN 1 .. st.files.COUNT LOOP
        IF lower(st.files(i).family) = lower(CASE pass WHEN 1 THEN f.font ELSE substitute(f.font) END)
           AND st.files(i).variant = l_var THEN
          l_file := i; EXIT;
        END IF;
      END LOOP;
      EXIT WHEN l_file IS NOT NULL;
    END LOOP;
    IF l_file IS NULL THEN
      fail(c_err_font, 'no font file for ' || f.font || ' (' || substitute(f.font) || ') variant ' || l_var);
    END IF;
    l_b := st.files(l_file).bytes;
    l_head := ttf_table(l_b, 'head'); l_hhea := ttf_table(l_b, 'hhea'); l_os2 := ttf_table(l_b, 'OS/2');
    IF l_head IS NULL OR l_hhea IS NULL THEN fail(c_err_font, st.files(l_file).family || ' ' || l_var || ': not a TrueType font'); END IF;
    IF l_os2 IS NOT NULL THEN
      l_fs := u16(l_b, l_os2 + 8);
      IF bitand(l_fs, 15) = 2 THEN fail(c_err_font, st.files(l_file).family || ' ' || l_var || ': fsType forbids embedding'); END IF;
      IF bitand(l_fs, 256) = 256 OR bitand(l_fs, 512) = 512 THEN
        fail(c_err_font, st.files(l_file).family || ' ' || l_var || ': fsType forbids subsetting (not in v1)');
      END IF;
    END IF;
    l_upem := u16(l_b, l_head + 18);
    fm.ascn := s16(l_b, l_hhea + 4) / l_upem;
    fm.dsc := -s16(l_b, l_hhea + 6) / l_upem;
    fm.gap := s16(l_b, l_hhea + 8) / l_upem;
    fm.idx := rad_pdf_fonts.load_ttf(st.doc, l_b, p_encoding => 'CID', p_embed => TRUE);
    st.fms(l_key) := fm;
    RETURN fm;
  END font_of;

  -- ---------------------------------------------------------------------------
  -- operations
  -- ---------------------------------------------------------------------------
  PROCEDURE op_text(st IN OUT NOCOPY t_st, p_x NUMBER, p_base NUMBER, t IN t_tok) IS
    n PLS_INTEGER;
  BEGIN
    IF st.dry THEN RETURN; END IF;
    n := st.ops.COUNT + 1;
    st.ops(n).pg := st.pg; st.ops(n).kind := 'T'; st.ops(n).x := p_x; st.ops(n).y := p_base;
    st.ops(n).txt := t.txt; st.ops(n).fidx := t.fidx; st.ops(n).sz := t.sz; st.ops(n).color := t.color;
    st.ops(n).fcode := t.fcode;
    IF t.ul = 'Y' THEN
      n := n + 1;
      st.ops(n).pg := st.pg; st.ops(n).kind := 'L'; st.ops(n).x := p_x; st.ops(n).x2 := p_x + t.w;
      st.ops(n).y := p_base + 0.1 * t.sz; st.ops(n).y2 := st.ops(n).y; st.ops(n).lw := 0.05 * t.sz; st.ops(n).color := t.color;
    END IF;
  END op_text;

  PROCEDURE op_line(st IN OUT NOCOPY t_st, x1 NUMBER, y1 NUMBER, x2 NUMBER, y2 NUMBER, b IN rad_pdf_ri.t_border) IS
    n PLS_INTEGER;
  BEGIN
    IF st.dry OR nvl(b.style, 'NONE') <> 'SINGLE' THEN RETURN; END IF;
    n := st.ops.COUNT + 1;
    st.ops(n).pg := st.pg; st.ops(n).kind := 'L'; st.ops(n).x := x1; st.ops(n).y := y1; st.ops(n).x2 := x2; st.ops(n).y2 := y2;
    st.ops(n).lw := b.width; st.ops(n).color := nvl(b.color, '000000');
  END op_line;

  PROCEDURE op_fill(st IN OUT NOCOPY t_st, p_x NUMBER, p_y NUMBER, p_w NUMBER, p_h NUMBER, p_color VARCHAR2) IS
    n PLS_INTEGER;
  BEGIN
    IF st.dry OR p_color IS NULL THEN RETURN; END IF;
    n := st.ops.COUNT + 1;
    st.ops(n).pg := st.pg; st.ops(n).kind := 'F'; st.ops(n).x := p_x; st.ops(n).y := p_y; st.ops(n).w := p_w; st.ops(n).h := p_h;
    st.ops(n).color := p_color;
  END op_fill;

  PROCEDURE op_image(st IN OUT NOCOPY t_st, p_x NUMBER, p_y NUMBER, p_w NUMBER, p_h NUMBER, p_res PLS_INTEGER) IS
    n PLS_INTEGER;
  BEGIN
    IF st.dry THEN RETURN; END IF;
    n := st.ops.COUNT + 1;
    st.ops(n).pg := st.pg; st.ops(n).kind := 'I'; st.ops(n).x := p_x; st.ops(n).y := p_y; st.ops(n).w := p_w; st.ops(n).h := p_h;
    st.ops(n).res := p_res;
  END op_image;

  -- ---------------------------------------------------------------------------
  -- a paragraph: tokens, lines, tab stops, alignment
  -- ---------------------------------------------------------------------------
  PROCEDURE add_tok(p IN OUT NOCOPY t_plan, t IN t_tok) IS
  BEGIN
    p.toks(p.toks.COUNT + 1) := t;
  END add_tok;

  -- a text as word and space tokens of one format
  PROCEDURE text_toks(st IN OUT NOCOPY t_st, p IN OUT NOCOPY t_plan, p_text IN VARCHAR2, f IN rad_pdf_ri.t_run_fmt,
                      p_kind IN VARCHAR2 DEFAULT 'T', p_fcode IN VARCHAR2 DEFAULT NULL) IS
    fm    t_fm := font_of(st, f);
    t     t_tok;
    l_pos PLS_INTEGER := 1;
    l_len PLS_INTEGER := nvl(length(p_text), 0);
    l_sp  PLS_INTEGER;
    l_end PLS_INTEGER;
  BEGIN
    t.fidx := fm.idx; t.sz := f.size_pt; t.color := nvl(f.color, '000000'); t.ul := nvl(f.underline, 'N');
    t.ascn := fm.ascn * f.size_pt; t.lh := (fm.ascn + fm.dsc + fm.gap) * f.size_pt; t.fcode := p_fcode;
    WHILE l_pos <= l_len LOOP
      IF substr(p_text, l_pos, 1) = ' ' THEN
        l_end := l_pos;
        WHILE l_end < l_len AND substr(p_text, l_end + 1, 1) = ' ' LOOP l_end := l_end + 1; END LOOP;
        t.kind := 'SP'; t.txt := substr(p_text, l_pos, l_end - l_pos + 1);
      ELSE
        l_sp := instr(p_text, ' ', l_pos);
        l_end := CASE WHEN l_sp = 0 THEN l_len ELSE l_sp - 1 END;
        t.kind := p_kind; t.txt := substr(p_text, l_pos, l_end - l_pos + 1);
      END IF;
      t.w := rad_pdf_fonts.text_width(t.txt, fm.idx, f.size_pt);
      add_tok(p, t);
      l_pos := l_end + 1;
    END LOOP;
  END text_toks;

  -- p_page, p_pages: the page and the page count the fields are measured with; p_body: the fields keep their code, so
  -- the drawing writes the page that holds them (the body); otherwise their text is final (a header, a footer)
  -- p_from: lay out the paragraph from this token on (the continuation of a paragraph split by a page: no first-line
  -- indent; the tokens before it belong to the previous page)
  FUNCTION plan_para(st IN OUT NOCOPY t_st, p_id IN rad_pdf_ri.t_id, p_width IN NUMBER, p_page IN PLS_INTEGER DEFAULT NULL,
                     p_pages IN PLS_INTEGER DEFAULT NULL, p_body IN BOOLEAN DEFAULT FALSE, p_from IN PLS_INTEGER DEFAULT 1) RETURN t_plan IS
    p      t_plan;
    n      rad_pdf_ri.t_node;
    k      rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, p_id);
    tabs   rad_pdf_ri.t_tab_list := st.inst.nodes(p_id).tabs;
    t      t_tok;
    l_last rad_pdf_ri.t_run_fmt := st.dfmt;
    x      NUMBER;
    l_left NUMBER;
    l_right NUMBER;
    l_line PLS_INTEGER := 0;
    l_first PLS_INTEGER := 1;
    l_vis  BOOLEAN := FALSE;                             -- the line holds something visible
    -- a right or decimal tab: its segment is placed when it ends
    l_seg  PLS_INTEGER;                                  -- the first token of the segment
    l_skind CHAR(1);
    l_spos NUMBER;
    l_sx   NUMBER;                                       -- x at the tab
    l_brk  BOOLEAN;
    l_word NUMBER;
    fm     t_fm;

    PROCEDURE end_segment(p_to PLS_INTEGER) IS
      l_w   NUMBER := 0;
      l_wb  NUMBER;
      l_sh  NUMBER;
      l_at  PLS_INTEGER;
    BEGIN
      IF l_seg IS NULL THEN RETURN; END IF;
      FOR i IN l_seg .. p_to LOOP
        IF l_wb IS NULL AND l_skind = 'D' AND p.toks(i).kind IN ('T', 'FLD') THEN
          l_at := instr(p.toks(i).txt, st.opt.decimal_char);
          IF l_at > 0 THEN
            l_wb := l_w + rad_pdf_fonts.text_width(substr(p.toks(i).txt, 1, l_at - 1), p.toks(i).fidx, p.toks(i).sz);
          END IF;
        END IF;
        l_w := l_w + p.toks(i).w;
      END LOOP;
      l_sh := greatest(0, l_spos - CASE WHEN l_skind = 'D' THEN nvl(l_wb, l_w) ELSE l_w END - l_sx);
      FOR i IN l_seg .. p_to LOOP p.toks(i).x := p.toks(i).x + l_sh; END LOOP;
      x := x + l_sh;
      l_seg := NULL;
    END end_segment;

    PROCEDURE end_line(p_to PLS_INTEGER, p_brk BOOLEAN) IS
      l_h   NUMBER := 0;
      l_a   NUMBER := 0;
      l_end NUMBER;
      l_sh  NUMBER;
      l_nsp PLS_INTEGER := 0;
      l_ext NUMBER;
      l_from PLS_INTEGER := l_first;
      l_lastvis PLS_INTEGER;
    BEGIN
      end_segment(p_to);
      l_line := l_line + 1;
      FOR i IN l_first .. p_to LOOP
        IF p.toks(i).kind IN ('T', 'SP', 'FLD', 'TAB', 'BR') AND p.toks(i).lh IS NOT NULL THEN
          l_h := greatest(l_h, p.toks(i).lh); l_a := greatest(l_a, p.toks(i).ascn);
        ELSIF p.toks(i).kind = 'IMG' THEN
          l_h := greatest(l_h, p.toks(i).ih); l_a := greatest(l_a, p.toks(i).ih);
        END IF;
        IF p.toks(i).kind IN ('T', 'FLD', 'IMG') THEN l_lastvis := i; END IF;
        IF p.toks(i).kind = 'TAB' THEN l_from := i + 1; END IF;
      END LOOP;
      IF l_h = 0 THEN                                    -- an empty line: the paragraph's format
        fm := font_of(st, l_last);
        l_h := (fm.ascn + fm.dsc + fm.gap) * l_last.size_pt; l_a := fm.ascn * l_last.size_pt;
      END IF;
      p.lines(l_line).first := l_first; p.lines(l_line).last := p_to;
      p.lines(l_line).h := l_h * p.para.line_mult; p.lines(l_line).ascn := l_a;
      p.h := p.h + p.lines(l_line).h;
      -- alignment on the visible content (trailing spaces do not count)
      IF l_lastvis IS NOT NULL THEN
        l_end := p.toks(l_lastvis).x + p.toks(l_lastvis).w;
        IF p.para.align IN ('C', 'R') THEN
          l_sh := (l_right - l_end) / CASE p.para.align WHEN 'C' THEN 2 ELSE 1 END;
          FOR i IN l_first .. p_to LOOP p.toks(i).x := p.toks(i).x + greatest(l_sh, 0); END LOOP;
        ELSIF p.para.align = 'J' AND NOT p_brk THEN      -- justified, never the last line nor a line before a break
          FOR i IN l_from .. l_lastvis LOOP IF p.toks(i).kind = 'SP' THEN l_nsp := l_nsp + 1; END IF; END LOOP;
          IF l_nsp > 0 AND l_right > l_end THEN
            l_ext := (l_right - l_end) / l_nsp; l_sh := 0;
            FOR i IN l_from .. l_lastvis LOOP
              p.toks(i).x := p.toks(i).x + l_sh;
              IF p.toks(i).kind = 'SP' THEN l_sh := l_sh + l_ext; END IF;
            END LOOP;
          END IF;
        END IF;
      END IF;
      l_first := p_to + 1;
    END end_line;
  BEGIN
    p.para := st.inst.nodes(p_id).para;
    -- the tokens
    FOR j IN 1 .. k.COUNT LOOP
      n := st.inst.nodes(k(j));
      CASE n.kind
        WHEN 'run' THEN text_toks(st, p, n.text, n.fmt); l_last := n.fmt;
        WHEN 'field' THEN
          text_toks(st, p, CASE WHEN n.field_code = 'PAGE' THEN to_char(nvl(p_page, st.guess))
                                ELSE to_char(nvl(p_pages, st.guess)) END, n.fmt, 'FLD', CASE WHEN p_body THEN n.field_code END);
          l_last := n.fmt;
        WHEN 'tab' THEN
          t := NULL; t.kind := 'TAB'; t.w := 0; fm := font_of(st, l_last);
          t.lh := (fm.ascn + fm.dsc + fm.gap) * l_last.size_pt; t.ascn := fm.ascn * l_last.size_pt; add_tok(p, t);
        WHEN 'line_break' THEN
          t := NULL; t.kind := 'BR'; t.w := 0; fm := font_of(st, l_last);
          t.lh := (fm.ascn + fm.dsc + fm.gap) * l_last.size_pt; t.ascn := fm.ascn * l_last.size_pt; add_tok(p, t);
        WHEN 'image' THEN
          t := NULL; t.kind := 'IMG'; t.w := n.width; t.ih := n.height; t.res := n.image_res; add_tok(p, t);
        ELSE NULL;
      END CASE;
    END LOOP;
    -- the lines
    l_left := p.para.ind_left; l_right := p_width - p.para.ind_right;
    x := l_left + CASE WHEN p_from = 1 THEN p.para.ind_first ELSE 0 END;
    l_first := p_from;
    FOR i IN p_from .. p.toks.COUNT LOOP
      CASE p.toks(i).kind
        WHEN 'SP' THEN
          IF NOT l_vis AND l_line > 0 AND l_first = i THEN p.toks(i).w := 0; END IF;       -- a wrapped line starts with no space
          p.toks(i).x := x; x := x + p.toks(i).w;
        WHEN 'TAB' THEN
          end_segment(i - 1);
          l_spos := NULL; l_skind := 'L';
          IF tabs IS NOT NULL THEN
            FOR s IN 1 .. tabs.COUNT LOOP
              IF tabs(s).pos > x + 0.001 THEN l_spos := tabs(s).pos; l_skind := tabs(s).kind; EXIT; END IF;
            END LOOP;
          END IF;
          IF l_spos IS NULL THEN                         -- the default stops
            l_spos := (floor(x / st.opt.default_tab) + 1) * st.opt.default_tab; l_skind := 'L';
          END IF;
          p.toks(i).x := x;
          IF l_skind = 'L' THEN x := l_spos;
          ELSE l_seg := i + 1; l_sx := x;
          END IF;
        WHEN 'BR' THEN
          p.toks(i).x := x;
          end_line(i, TRUE);
          x := l_left; l_vis := FALSE;
        ELSE                                             -- T FLD IMG
          -- R6: a line breaks only before a word, never inside one: the tokens of a word (several runs, several
          -- formats, no space between them) are measured together and move together
          IF i = 1 OR p.toks(i - 1).kind NOT IN ('T', 'FLD') OR p.toks(i).kind = 'IMG' THEN
            l_word := p.toks(i).w;
            IF p.toks(i).kind <> 'IMG' THEN
              FOR w IN i + 1 .. p.toks.COUNT LOOP
                EXIT WHEN p.toks(w).kind NOT IN ('T', 'FLD');
                l_word := l_word + p.toks(w).w;
              END LOOP;
            END IF;
            IF l_vis AND x + l_word > l_right + 0.001 THEN
              end_line(i - 1, FALSE);
              x := l_left; l_vis := FALSE;
            END IF;
          END IF;
          p.toks(i).x := x; x := x + p.toks(i).w; l_vis := TRUE;
      END CASE;
    END LOOP;
    IF l_first <= p.toks.COUNT OR p.toks.COUNT = 0 OR l_line = 0 THEN end_line(p.toks.COUNT, TRUE); END IF;
    RETURN p;
  END plan_para;

  -- draws the lines from..to of a plan from y (top of the first line), at x0; returns the y after them
  FUNCTION draw_lines(st IN OUT NOCOPY t_st, p IN t_plan, p_from PLS_INTEGER, p_to PLS_INTEGER, x0 NUMBER, y NUMBER) RETURN NUMBER IS
    l_y    NUMBER := y;
    l_base NUMBER;
  BEGIN
    FOR l IN p_from .. p_to LOOP
      l_base := l_y + p.lines(l).ascn;
      FOR i IN p.lines(l).first .. p.lines(l).last LOOP
        IF p.toks(i).kind IN ('T', 'FLD') THEN op_text(st, x0 + p.toks(i).x, l_base, p.toks(i));
        ELSIF p.toks(i).kind = 'IMG' THEN op_image(st, x0 + p.toks(i).x, l_base - p.toks(i).ih, p.toks(i).w, p.toks(i).ih, p.toks(i).res);
        END IF;
      END LOOP;
      l_y := l_y + p.lines(l).h;
    END LOOP;
    RETURN l_y;
  END draw_lines;

  -- ---------------------------------------------------------------------------
  -- blocks outside the page flow: a cell, a header, a footer (no page break; dry = measure only)
  -- ---------------------------------------------------------------------------
  FUNCTION fixed_table(st IN OUT NOCOPY t_st, p_id rad_pdf_ri.t_id, x0 NUMBER, y NUMBER, p_page PLS_INTEGER, p_pages PLS_INTEGER) RETURN NUMBER;

  FUNCTION fixed_blocks(st IN OUT NOCOPY t_st, p_id rad_pdf_ri.t_id, x0 NUMBER, p_width NUMBER, y NUMBER,
                        p_page PLS_INTEGER DEFAULT NULL, p_pages PLS_INTEGER DEFAULT NULL) RETURN NUMBER IS
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, p_id);
    n     rad_pdf_ri.t_node;
    p     t_plan;
    l_y   NUMBER := y;
    l_aft NUMBER := 0;
    l_first BOOLEAN := TRUE;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      n := st.inst.nodes(k(j));
      CASE n.kind
        WHEN 'paragraph' THEN
          p := plan_para(st, k(j), p_width, p_page, p_pages);
          l_y := l_y + CASE WHEN l_first THEN p.para.space_before ELSE greatest(l_aft, p.para.space_before) END;
          l_y := draw_lines(st, p, 1, p.lines.COUNT, x0, l_y);
          l_aft := p.para.space_after;
        WHEN 'table' THEN
          l_y := fixed_table(st, k(j), x0, l_y + l_aft, p_page, p_pages); l_aft := 0;
        WHEN 'fixed_box' THEN
          l_y := l_y + l_aft; op_image(st, x0, l_y, n.width, n.height, n.image_res); l_y := l_y + n.height; l_aft := 0;
        ELSE NULL;                                       -- a page break has no meaning here
      END CASE;
      l_first := FALSE;
    END LOOP;
    RETURN l_y + l_aft;                                  -- the last space_after counts (a cell: measured on Word)
  END fixed_blocks;

  -- the x of each grid column (from the left of the table)
  FUNCTION col_x(p_grid rad_pdf_ri.t_num_list) RETURN rad_pdf_ri.t_num_list IS
    l rad_pdf_ri.t_num_list := rad_pdf_ri.t_num_list();
  BEGIN
    l.EXTEND(p_grid.COUNT + 1);
    l(1) := 0;
    FOR i IN 1 .. p_grid.COUNT LOOP l(i + 1) := l(i) + p_grid(i); END LOOP;
    RETURN l;
  END col_x;

  -- ---------------------------------------------------------------------------
  -- borders (R4): one resolution of every edge, for the measure and for the drawing. A border a cell sets wins over
  -- the table's; between two cells (or two rows) the set one wins, SINGLE over NONE, the wider SINGLE over the other
  -- ---------------------------------------------------------------------------
  FUNCTION bw(b rad_pdf_ri.t_border) RETURN NUMBER IS
  BEGIN
    RETURN CASE WHEN b.style = 'SINGLE' THEN nvl(b.width, 0) ELSE 0 END;
  END bw;

  FUNCTION stronger(a rad_pdf_ri.t_border, b rad_pdf_ri.t_border) RETURN rad_pdf_ri.t_border IS
  BEGIN
    IF a.style IS NULL THEN RETURN b; END IF;
    IF b.style IS NULL THEN RETURN a; END IF;
    IF bw(b) > bw(a) THEN RETURN b; END IF;
    RETURN a;
  END stronger;

  -- the cell of a row that covers grid column p_col (NULL when none)
  FUNCTION cell_at(st IN t_st, p_row rad_pdf_ri.t_id, p_col PLS_INTEGER) RETURN rad_pdf_ri.t_id IS
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, p_row);
    l_col PLS_INTEGER := 1;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      IF p_col BETWEEN l_col AND l_col + st.inst.nodes(k(j)).cell.grid_span - 1 THEN RETURN k(j); END IF;
      l_col := l_col + st.inst.nodes(k(j)).cell.grid_span;
    END LOOP;
    RETURN NULL;
  END cell_at;

  -- the top edge of grid column p_col in p_row (R4: by segments of the grid, so a gridSpan that changes between rows
  -- meets every neighbour): the top of the cell below and the bottom of the cell above in p_prev, the stronger; else the
  -- table's top (the first row on a page: p_prev NULL) or inside_h
  FUNCTION top_edge(st IN t_st, t rad_pdf_ri.t_node, p_row rad_pdf_ri.t_id, p_col PLS_INTEGER, p_prev rad_pdf_ri.t_id) RETURN rad_pdf_ri.t_border IS
    l_here rad_pdf_ri.t_id := cell_at(st, p_row, p_col);
    l_set  rad_pdf_ri.t_border;
    l_up   rad_pdf_ri.t_id;
  BEGIN
    IF l_here IS NOT NULL THEN l_set := st.inst.nodes(l_here).cell.borders.top; END IF;
    IF p_prev IS NOT NULL THEN
      l_up := cell_at(st, p_prev, p_col);
      IF l_up IS NOT NULL THEN l_set := stronger(l_set, st.inst.nodes(l_up).cell.borders.bottom); END IF;
    END IF;
    IF l_set.style IS NOT NULL THEN RETURN l_set; END IF;
    RETURN CASE WHEN p_prev IS NULL THEN t.borders.top ELSE t.borders.inside_h END;
  END top_edge;

  -- the bottom edge of grid column p_col under p_row when it ends the table or its part on a page: the cell's bottom,
  -- else the table's
  FUNCTION bottom_edge(st IN t_st, t rad_pdf_ri.t_node, p_row rad_pdf_ri.t_id, p_col PLS_INTEGER) RETURN rad_pdf_ri.t_border IS
    l_here rad_pdf_ri.t_id := cell_at(st, p_row, p_col);
  BEGIN
    IF l_here IS NOT NULL AND st.inst.nodes(l_here).cell.borders.bottom.style IS NOT NULL THEN
      RETURN st.inst.nodes(l_here).cell.borders.bottom;
    END IF;
    RETURN t.borders.bottom;
  END bottom_edge;

  -- the left edge of the cell starting at p_col: its own left and the right of the cell before it, else the table's
  FUNCTION left_edge(st IN t_st, t rad_pdf_ri.t_node, p_row rad_pdf_ri.t_id, p_cell rad_pdf_ri.t_id, p_col PLS_INTEGER) RETURN rad_pdf_ri.t_border IS
    l_set rad_pdf_ri.t_border := st.inst.nodes(p_cell).cell.borders.lft;
    l_lft rad_pdf_ri.t_id;
  BEGIN
    IF p_col > 1 THEN
      l_lft := cell_at(st, p_row, p_col - 1);
      IF l_lft IS NOT NULL THEN l_set := stronger(l_set, st.inst.nodes(l_lft).cell.borders.rgt); END IF;
    END IF;
    IF l_set.style IS NOT NULL THEN RETURN l_set; END IF;
    RETURN CASE WHEN p_col = 1 THEN t.borders.lft ELSE t.borders.inside_v END;
  END left_edge;

  -- the top border width of a row: the widest of its segments' top edges
  FUNCTION row_top(st IN t_st, t rad_pdf_ri.t_node, p_row rad_pdf_ri.t_id, p_prev rad_pdf_ri.t_id) RETURN NUMBER IS
    l_w NUMBER := 0;
  BEGIN
    FOR c IN 1 .. t.grid.COUNT LOOP l_w := greatest(l_w, bw(top_edge(st, t, p_row, c, p_prev))); END LOOP;
    RETURN l_w;
  END row_top;

  -- a row measured (dry) or drawn at y, after p_prev on this page (NULL: the first); returns its height (its top border +
  -- its tallest cell)
  FUNCTION do_row(st IN OUT NOCOPY t_st, p_tbl rad_pdf_ri.t_id, p_row rad_pdf_ri.t_id, x0 NUMBER, y NUMBER,
                  p_prev rad_pdf_ri.t_id, p_draw BOOLEAN, p_page PLS_INTEGER DEFAULT NULL, p_pages PLS_INTEGER DEFAULT NULL) RETURN NUMBER IS
    t     rad_pdf_ri.t_node := st.inst.nodes(p_tbl);
    cx    rad_pdf_ri.t_num_list := col_x(t.grid);
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, p_row);
    c     rad_pdf_ri.t_cell_fmt;
    l_col PLS_INTEGER := 1;
    l_bt  NUMBER := row_top(st, t, p_row, p_prev);
    l_h   NUMBER := 0;
    l_x1  NUMBER;
    l_x2  NUMBER;
    l_dry BOOLEAN := st.dry;
    l_end NUMBER;
    l_b   rad_pdf_ri.t_border;
  BEGIN
    st.dry := TRUE;                                      -- the height first
    FOR j IN 1 .. k.COUNT LOOP
      c := st.inst.nodes(k(j)).cell;
      l_x1 := cx(l_col); l_x2 := cx(l_col + c.grid_span);
      l_h := greatest(l_h, c.mar_top + c.mar_bottom
                      + fixed_blocks(st, k(j), 0, l_x2 - l_x1 - c.mar_left - c.mar_right, 0, p_page, p_pages));
      l_col := l_col + c.grid_span;
    END LOOP;
    st.dry := l_dry;
    IF p_draw AND NOT st.dry THEN
      l_col := 1;
      FOR j IN 1 .. k.COUNT LOOP
        c := st.inst.nodes(k(j)).cell;
        l_x1 := x0 + cx(l_col); l_x2 := x0 + cx(l_col + c.grid_span);
        op_fill(st, l_x1, y, l_x2 - l_x1, l_bt + l_h, c.shading);
        l_end := fixed_blocks(st, k(j), l_x1 + c.mar_left, l_x2 - l_x1 - c.mar_left - c.mar_right, y + l_bt + c.mar_top, p_page, p_pages);
        op_line(st, l_x1, y, l_x1, y + l_bt + l_h, left_edge(st, t, p_row, k(j), l_col));
        IF j = k.COUNT THEN
          op_line(st, l_x2, y, l_x2, y + l_bt + l_h, CASE WHEN c.borders.rgt.style IS NOT NULL THEN c.borders.rgt ELSE t.borders.rgt END);
        END IF;
        l_col := l_col + c.grid_span;
      END LOOP;
      FOR g IN 1 .. t.grid.COUNT LOOP                    -- the top edge, segment by segment, over the shading
        l_b := top_edge(st, t, p_row, g, p_prev);
        op_line(st, x0 + cx(g), y + bw(l_b) / 2, x0 + cx(g + 1), y + bw(l_b) / 2, l_b);
      END LOOP;
    END IF;
    RETURN l_bt + l_h;
  END do_row;

  -- the bottom edge under p_row (the last row of the table, or of its part on a page), segment by segment; drawn at y
  -- when drawing; returns its width (the widest segment)
  FUNCTION bottom_border(st IN OUT NOCOPY t_st, p_tbl rad_pdf_ri.t_id, p_row rad_pdf_ri.t_id, x0 NUMBER, y NUMBER,
                         p_draw BOOLEAN DEFAULT TRUE) RETURN NUMBER IS
    t     rad_pdf_ri.t_node := st.inst.nodes(p_tbl);
    cx    rad_pdf_ri.t_num_list := col_x(t.grid);
    l_b   rad_pdf_ri.t_border;
    l_w   NUMBER := 0;
  BEGIN
    FOR g IN 1 .. t.grid.COUNT LOOP
      l_b := bottom_edge(st, t, p_row, g);
      l_w := greatest(l_w, bw(l_b));
      IF p_draw THEN op_line(st, x0 + cx(g), y + bw(l_b) / 2, x0 + cx(g + 1), y + bw(l_b) / 2, l_b); END IF;
    END LOOP;
    RETURN l_w;
  END bottom_border;

  FUNCTION fixed_table(st IN OUT NOCOPY t_st, p_id rad_pdf_ri.t_id, x0 NUMBER, y NUMBER, p_page PLS_INTEGER, p_pages PLS_INTEGER) RETURN NUMBER IS
    k   rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, p_id);
    l_y NUMBER := y;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      l_y := l_y + do_row(st, p_id, k(j), x0, l_y, CASE WHEN j > 1 THEN k(j - 1) END, TRUE, p_page, p_pages);
    END LOOP;
    RETURN l_y + bottom_border(st, p_id, k(k.COUNT), x0, l_y, NOT st.dry);
  END fixed_table;

  -- ---------------------------------------------------------------------------
  -- the frames of the pages (R3): per page, the header and the footer measured with that page's number and the page
  -- count of this pass
  -- ---------------------------------------------------------------------------
  FUNCTION zone_name(st IN t_st, p_kind VARCHAR2, p_pg PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN p_kind || CASE WHEN p_pg = 1 AND st.inst.nodes(st.inst.section_id).title_page = 'Y' THEN '_first' ELSE '_default' END;
  END zone_name;

  FUNCTION zone_h(st IN OUT NOCOPY t_st, p_zone VARCHAR2, p_pg PLS_INTEGER, p_pages PLS_INTEGER) RETURN NUMBER IS
    l_dry BOOLEAN := st.dry;
    l_h   NUMBER;
  BEGIN
    st.dry := TRUE;
    l_h := fixed_blocks(st, rad_pdf_ri.zone(st.inst, p_zone), st.left, st.width, 0, p_pg, p_pages);
    st.dry := l_dry;
    RETURN l_h;
  END zone_h;

  PROCEDURE frame(st IN OUT NOCOPY t_st, p_pg PLS_INTEGER) IS
    s rad_pdf_ri.t_node := st.inst.nodes(st.inst.section_id);
  BEGIN
    IF st.tops.EXISTS(p_pg) THEN RETURN; END IF;
    st.tops(p_pg) := greatest(s.mar_top, s.mar_header + zone_h(st, zone_name(st, 'header', p_pg), p_pg, st.guess));
    st.bottoms(p_pg) := st.page_h - greatest(s.mar_bottom, s.mar_footer + zone_h(st, zone_name(st, 'footer', p_pg), p_pg, st.guess));
    IF st.bottoms(p_pg) - st.tops(p_pg) < 1 THEN fail(c_err_layout, 'the header and footer of page ' || p_pg || ' leave no body'); END IF;
  END frame;

  FUNCTION top_of(st IN OUT NOCOPY t_st, p_pg PLS_INTEGER) RETURN NUMBER IS
  BEGIN
    frame(st, p_pg);
    RETURN st.tops(p_pg);
  END top_of;

  FUNCTION bottom_of(st IN OUT NOCOPY t_st, p_pg PLS_INTEGER) RETURN NUMBER IS
  BEGIN
    frame(st, p_pg);
    RETURN st.bottoms(p_pg);
  END bottom_of;

  FUNCTION height_of(st IN OUT NOCOPY t_st, p_pg PLS_INTEGER) RETURN NUMBER IS
  BEGIN
    RETURN bottom_of(st, p_pg) - top_of(st, p_pg);
  END height_of;

  -- ---------------------------------------------------------------------------
  -- the page flow of the body
  -- ---------------------------------------------------------------------------
  -- the one way to a new page (R5): automatic or manual, within the budget of 96a §8
  PROCEDURE new_page(st IN OUT NOCOPY t_st, p_manual BOOLEAN DEFAULT FALSE) IS
  BEGIN
    IF st.pg + 1 > c_max_pages THEN fail(c_err_budget, 'the document exceeds ' || c_max_pages || ' pages'); END IF;
    st.pg := st.pg + 1;
    st.y := top_of(st, st.pg);
    st.fresh := NOT p_manual;                            -- after a manual break the space_before stays
    st.after := 0;
  END new_page;

  -- the leading gap a block gets here: none at the top of a page after an automatic break, else the larger of the
  -- space_after still to place and the block's space_before (R1: the same rule for the measure and for the flow)
  FUNCTION gap_of(st IN t_st, n rad_pdf_ri.t_node) RETURN NUMBER IS
  BEGIN
    IF st.fresh THEN RETURN 0; END IF;
    RETURN greatest(st.after, CASE WHEN n.kind = 'paragraph' THEN n.para.space_before ELSE 0 END);
  END gap_of;

  FUNCTION table_hdr(st IN t_st, k rad_pdf_ri.t_num_list) RETURN PLS_INTEGER IS
    l PLS_INTEGER := 0;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      EXIT WHEN st.inst.nodes(k(j)).header <> 'Y';
      l := j;
    END LOOP;
    RETURN l;
  END table_hdr;

  -- the rows from..to measured as a group placed together on a page (the first after p_prev), with the bottom border
  -- that closes it
  -- p_close: with the closing border (FALSE: a part of a larger group, closed by its last part)
  FUNCTION group_h(st IN OUT NOCOPY t_st, p_tbl rad_pdf_ri.t_id, k rad_pdf_ri.t_num_list, p_from PLS_INTEGER, p_to PLS_INTEGER,
                   p_prev rad_pdf_ri.t_id, p_close BOOLEAN DEFAULT TRUE) RETURN NUMBER IS
    l_h   NUMBER := 0;
    l_dry BOOLEAN := st.dry;
  BEGIN
    st.dry := TRUE;
    FOR j IN p_from .. p_to LOOP
      l_h := l_h + do_row(st, p_tbl, k(j), 0, 0, CASE WHEN j = p_from THEN p_prev ELSE k(j - 1) END, FALSE, st.pg, st.guess);
    END LOOP;
    -- R2: the closing border of the group's last row, reserved always: the group may end the table or its part on a page
    IF p_close THEN l_h := l_h + bottom_border(st, p_tbl, k(p_to), 0, 0, FALSE); END IF;
    st.dry := l_dry;
    RETURN l_h;
  END group_h;

  -- the height a block needs at the top of a chain: a paragraph whole (p_whole) or its first line; a table its header
  -- rows and its first body row (an indivisible group)
  FUNCTION need_of(st IN OUT NOCOPY t_st, p_id rad_pdf_ri.t_id, p_whole BOOLEAN) RETURN NUMBER IS
    n  rad_pdf_ri.t_node := st.inst.nodes(p_id);
    p  t_plan;
    k  rad_pdf_ri.t_num_list;
  BEGIN
    IF n.kind = 'paragraph' THEN
      p := plan_para(st, p_id, st.width, st.pg, st.guess, TRUE);
      RETURN CASE WHEN p_whole THEN p.h ELSE p.lines(1).h END;
    ELSIF n.kind = 'table' THEN
      k := rad_pdf_ri.kids(st.inst, p_id);
      RETURN group_h(st, p_id, k, 1, least(table_hdr(st, k) + 1, k.COUNT), NULL);
    ELSIF n.kind = 'fixed_box' THEN RETURN n.height;
    END IF;
    RETURN 0;
  END need_of;

  -- keep_next (96a §8): the chain from block j, with the gap its first block gets here (R1); it starts on a new page
  -- when it does not fit here; taller than the page that would hold it: [PDF_LAYOUT]
  PROCEDURE keep_chain(st IN OUT NOCOPY t_st, k IN rad_pdf_ri.t_num_list, j IN PLS_INTEGER) IS
    l_need NUMBER := 0;
    l_i    PLS_INTEGER := j;
    n      rad_pdf_ri.t_node;
    l_aft  NUMBER := 0;
    l_gap  NUMBER;
  BEGIN
    LOOP
      n := st.inst.nodes(k(l_i));
      l_gap := CASE WHEN l_i = j THEN 0 ELSE greatest(l_aft, CASE WHEN n.kind = 'paragraph' THEN n.para.space_before ELSE 0 END) END;
      IF (n.kind = 'paragraph' AND n.para.keep_next = 'Y') OR (n.kind = 'fixed_box' AND n.keep_next = 'Y') THEN
        l_need := l_need + l_gap + need_of(st, k(l_i), TRUE);
        l_aft := CASE WHEN n.kind = 'paragraph' THEN n.para.space_after ELSE 0 END;
        l_i := l_i + 1;
        EXIT WHEN l_i > k.COUNT;
      ELSE
        l_need := l_need + l_gap + need_of(st, k(l_i), FALSE);
        EXIT;
      END IF;
    END LOOP;
    IF st.y + gap_of(st, st.inst.nodes(k(j))) + l_need <= bottom_of(st, st.pg) + 0.001 THEN RETURN; END IF;   -- fits here
    IF st.fresh THEN                                     -- already at the top of a page: nowhere better
      fail(c_err_layout, 'a keep-with-next chain of ' || round(l_need, 2) || ' pt is taller than the page');
    END IF;
    IF l_need > height_of(st, st.pg + 1) + 0.001 THEN
      fail(c_err_layout, 'a keep-with-next chain of ' || round(l_need, 2) || ' pt is taller than the page');
    END IF;
    new_page(st);
  END keep_chain;

  PROCEDURE flow_para(st IN OUT NOCOPY t_st, p_id rad_pdf_ri.t_id) IS
    p     t_plan := plan_para(st, p_id, st.width, st.pg, st.guess, TRUE);
    l_gap NUMBER := gap_of(st, st.inst.nodes(p_id));
    l     PLS_INTEGER := 1;
  BEGIN
    IF st.y + l_gap + p.lines(1).h > bottom_of(st, st.pg) + 0.001 AND NOT st.fresh THEN
      new_page(st); l_gap := 0;
      p := plan_para(st, p_id, st.width, st.pg, st.guess, TRUE);    -- its fields measured on the page that holds it (R3)
    END IF;
    st.y := st.y + l_gap;
    WHILE l <= p.lines.COUNT LOOP
      IF st.y + p.lines(l).h > bottom_of(st, st.pg) + 0.001 AND NOT st.fresh THEN
        new_page(st);
        -- R3: the continuation laid out again on its own page (its fields measured with that page's number)
        p := plan_para(st, p_id, st.width, st.pg, st.guess, TRUE, p.lines(l).first);
        l := 1;
      END IF;
      st.y := draw_lines(st, p, l, l, st.left, st.y);
      st.fresh := FALSE;
      l := l + 1;
    END LOOP;
    st.after := p.para.space_after;
  END flow_para;

  -- a table (R2): the leading header rows and the first body row are one group; after a page break the repeated header
  -- rows and the row are one group; the bottom border is reserved with the last row; a group taller than an empty page
  -- is [PDF_LAYOUT]; a row is never split (v1)
  PROCEDURE flow_table(st IN OUT NOCOPY t_st, p_id rad_pdf_ri.t_id) IS
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, p_id);
    l_hdr PLS_INTEGER := table_hdr(st, k);
    j     PLS_INTEGER := 1;
    l_to  PLS_INTEGER;
    l_need NUMBER;
    l_prev rad_pdf_ri.t_id;                              -- the row before on this page (NULL: none)
  BEGIN
    st.y := st.y + gap_of(st, st.inst.nodes(p_id));
    st.after := 0;
    WHILE j <= k.COUNT LOOP
      l_to := CASE WHEN j = 1 AND l_hdr > 0 THEN least(l_hdr + 1, k.COUNT) ELSE j END;
      l_need := group_h(st, p_id, k, j, l_to, l_prev);
      IF st.y + l_need > bottom_of(st, st.pg) + 0.001 AND NOT (st.fresh AND l_prev IS NULL) THEN
        IF l_prev IS NOT NULL THEN st.y := st.y + bottom_border(st, p_id, l_prev, st.left, st.y); END IF;
        new_page(st);
        l_prev := NULL;
        IF j > l_hdr AND l_hdr > 0 THEN                  -- the header rows repeated, with the row: one group
          l_need := group_h(st, p_id, k, 1, l_hdr, NULL, FALSE);     -- one closing border: the row's (codex-055)
          FOR h IN 1 .. l_hdr LOOP l_prev := k(h); END LOOP;
          l_need := l_need + group_h(st, p_id, k, j, l_to, l_prev);
          IF l_need > height_of(st, st.pg) + 0.001 THEN
            fail(c_err_layout, 'the header rows and a table row of ' || round(l_need, 2) || ' pt are taller than the page');
          END IF;
          l_prev := NULL;
          FOR h IN 1 .. l_hdr LOOP
            st.y := st.y + do_row(st, p_id, k(h), st.left, st.y, l_prev, TRUE, st.pg, st.guess);
            l_prev := k(h);
          END LOOP;
        END IF;
      END IF;
      IF group_h(st, p_id, k, j, l_to, l_prev) > height_of(st, st.pg) + 0.001 THEN
        fail(c_err_layout, 'a table row of ' || round(group_h(st, p_id, k, j, l_to, l_prev), 2)
             || ' pt is taller than the page (rows are not split in v1)');
      END IF;
      FOR r IN j .. l_to LOOP
        st.y := st.y + do_row(st, p_id, k(r), st.left, st.y, l_prev, TRUE, st.pg, st.guess);
        l_prev := k(r);
      END LOOP;
      st.fresh := FALSE;
      j := l_to + 1;
    END LOOP;
    st.y := st.y + bottom_border(st, p_id, k(k.COUNT), st.left, st.y);
  END flow_table;

  PROCEDURE flow_body(st IN OUT NOCOPY t_st) IS
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, rad_pdf_ri.zone(st.inst, 'body'));
    n rad_pdf_ri.t_node;
  BEGIN
    st.tops.DELETE; st.bottoms.DELETE;
    st.pg := 1; st.y := top_of(st, 1); st.fresh := FALSE; st.after := 0; st.ops.DELETE;
    FOR j IN 1 .. k.COUNT LOOP
      n := st.inst.nodes(k(j));
      IF (n.kind = 'paragraph' AND n.para.keep_next = 'Y') OR (n.kind = 'fixed_box' AND n.keep_next = 'Y') THEN
        IF j = 1 OR NOT ((st.inst.nodes(k(j - 1)).kind = 'paragraph' AND st.inst.nodes(k(j - 1)).para.keep_next = 'Y')
                         OR (st.inst.nodes(k(j - 1)).kind = 'fixed_box' AND st.inst.nodes(k(j - 1)).keep_next = 'Y')) THEN
          keep_chain(st, k, j);                          -- once, at the start of a chain
        END IF;
      END IF;
      CASE n.kind
        WHEN 'paragraph'  THEN flow_para(st, k(j));
        WHEN 'table'      THEN flow_table(st, k(j));
        WHEN 'page_break' THEN new_page(st, TRUE);
        WHEN 'fixed_box'  THEN
          st.y := st.y + gap_of(st, n);
          IF st.y + n.height > bottom_of(st, st.pg) + 0.001 AND NOT st.fresh THEN new_page(st); END IF;
          op_image(st, st.left, st.y, n.width, n.height, n.image_res);
          st.y := st.y + n.height; st.after := 0; st.fresh := FALSE;
        ELSE NULL;
      END CASE;
    END LOOP;
  END flow_body;

  -- ---------------------------------------------------------------------------
  -- zones and the render
  -- ---------------------------------------------------------------------------
  PROCEDURE zones(st IN OUT NOCOPY t_st, p_pages PLS_INTEGER) IS
    s   rad_pdf_ri.t_node := st.inst.nodes(st.inst.section_id);
    l_y NUMBER;
  BEGIN
    FOR pg IN 1 .. p_pages LOOP
      st.pg := pg;
      l_y := fixed_blocks(st, rad_pdf_ri.zone(st.inst, zone_name(st, 'header', pg)), st.left, st.width, s.mar_header, pg, p_pages);
      l_y := fixed_blocks(st, rad_pdf_ri.zone(st.inst, zone_name(st, 'footer', pg)), st.left, st.width,
                          st.page_h - s.mar_footer - zone_h(st, zone_name(st, 'footer', pg), pg, p_pages), pg, p_pages);
    END LOOP;
  END zones;

  -- the first run format of the instance: the format of an empty paragraph (the paragraph mark is not in the RI)
  FUNCTION first_fmt(p_inst rad_pdf_ri.t_ri) RETURN rad_pdf_ri.t_run_fmt IS
    f rad_pdf_ri.t_run_fmt;
  BEGIN
    FOR id IN 1 .. rad_pdf_ri.node_count(p_inst) LOOP
      IF p_inst.nodes(id).kind IN ('run', 'field') THEN RETURN p_inst.nodes(id).fmt; END IF;
    END LOOP;
    f.font := 'Arial'; f.size_pt := 10;
    RETURN f;
  END first_fmt;

  PROCEDURE draw(st IN OUT NOCOPY t_st, p_inst IN rad_pdf_ri.t_ri, p_pages PLS_INTEGER) IS
    o     t_op;
    l_txt VARCHAR2(32767);
  BEGIN
    FOR pg IN 1 .. p_pages LOOP
      IF pg > 1 THEN rad_pdf_canvas.new_page(st.doc); END IF;
      FOR i IN 1 .. st.ops.COUNT LOOP
        o := st.ops(i);
        CONTINUE WHEN o.pg <> pg;
        CASE o.kind
          WHEN 'T' THEN
            l_txt := CASE o.fcode WHEN 'PAGE' THEN to_char(pg) WHEN 'NUMPAGES' THEN to_char(p_pages) ELSE o.txt END;
            rad_pdf_canvas.set_font(st.doc, o.fidx, o.sz);
            rad_pdf_canvas.set_color(st.doc, o.color);
            rad_pdf_canvas.write_text(st.doc, l_txt, o.x, st.page_h - o.y);
          WHEN 'L' THEN rad_pdf_canvas.line(st.doc, o.x, st.page_h - o.y, o.x2, st.page_h - o.y2, o.color, o.lw);
          WHEN 'F' THEN rad_pdf_canvas.rect(st.doc, o.x, st.page_h - o.y - o.h, o.w, o.h, NULL, o.color);
          WHEN 'I' THEN
            IF NOT st.imgs.EXISTS(o.res) THEN
              st.imgs(o.res) := rad_pdf_images.load_image(st.doc, p_inst.images(o.res).bytes);
            END IF;
            rad_pdf_canvas.put_image(st.doc, st.imgs(o.res), o.x, st.page_h - o.y, o.w, o.h);
        END CASE;
      END LOOP;
    END LOOP;
  END draw;

  -- the whole layout of an instance into st (the document is open: the fonts are loaded in it); returns the pages
  FUNCTION paginate(st IN OUT NOCOPY t_st, p_inst IN rad_pdf_ri.t_ri, p_fonts IN t_font_files, p_options IN t_options) RETURN PLS_INTEGER IS
    s       rad_pdf_ri.t_node;
    l_fmt   rad_pdf_types.t_page_format;
    l_info  rad_pdf_types.t_doc_info;
    l_pages PLS_INTEGER;
  BEGIN
    rad_pdf_ri.validate(p_inst);                         -- the consume boundary
    IF p_inst.instance <> 'Y' THEN fail(c_err_layout, 'the paginator draws an instance (rad_pdf_merge.merge), not a template'); END IF;
    -- the tree only; the images are read from p_inst when drawn (one owner of the bytes; a temporary LOB assigned to
    -- another variable is shared until a write copies it)
    st.inst.ri_version := p_inst.ri_version; st.inst.n := p_inst.n; st.inst.nodes := p_inst.nodes;
    st.inst.children := p_inst.children; st.inst.section_id := p_inst.section_id; st.inst.sealed := p_inst.sealed;
    st.inst.instance := p_inst.instance;
    st.files := nvl(p_fonts, t_font_files());
    st.opt := p_options;
    st.opt.decimal_char := nvl(st.opt.decimal_char, ',');
    st.opt.default_tab := nvl(st.opt.default_tab, 36);
    s := p_inst.nodes(p_inst.section_id);
    st.page_w := s.page_w; st.page_h := s.page_h;
    st.left := s.mar_left; st.width := s.page_w - s.mar_left - s.mar_right;
    st.dfmt := first_fmt(p_inst);
    l_info.title := p_options.title;
    -- the core only (96a §1b): no facade, no flowable layer
    st.doc := rad_pdf_doc.open_doc(p_info => l_info);
    l_fmt.width := s.page_w; l_fmt.height := s.page_h;
    rad_pdf_canvas.set_page_format(st.doc, l_fmt);
    rad_pdf_canvas.new_page(st.doc);
    -- PAGE and NUMPAGES (R3): the body is laid out with a page count, and again with the count it gave, until the count
    -- it gives is the count it was laid out with (the fields, the zones and their heights then agree)
    FOR pass IN 1 .. 4 LOOP
      flow_body(st);
      l_pages := st.pg;
      EXIT WHEN l_pages = st.guess;
      IF pass = 4 THEN fail(c_err_layout, 'the page count does not settle (' || st.guess || ', ' || l_pages || ')'); END IF;
      st.guess := l_pages;
    END LOOP;
    zones(st, l_pages);
    RETURN l_pages;
  END paginate;

  PROCEDURE close_quietly(st IN OUT NOCOPY t_st) IS
  BEGIN
    IF st.doc IS NOT NULL THEN
      BEGIN rad_pdf_doc.close_doc(st.doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
  END close_quietly;

  FUNCTION render(p_inst IN rad_pdf_ri.t_ri, p_fonts IN t_font_files, p_options IN t_options DEFAULT NULL) RETURN BLOB IS
    st      t_st;
    l_pages PLS_INTEGER;
    l_pdf   BLOB;
  BEGIN
    l_pages := paginate(st, p_inst, p_fonts, p_options);
    draw(st, p_inst, l_pages);
    l_pdf := rad_pdf_doc.assemble(st.doc);
    rad_pdf_doc.close_doc(st.doc);
    RETURN l_pdf;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_pdf IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_pdf) = 1 THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
      close_quietly(st);
      RAISE;
  END render;

  FUNCTION layout_dump(p_inst IN rad_pdf_ri.t_ri, p_fonts IN t_font_files, p_options IN t_options DEFAULT NULL) RETURN CLOB IS
    st      t_st;
    l_pages PLS_INTEGER;
    l_out   CLOB;
    o       t_op;
    FUNCTION n(v NUMBER) RETURN VARCHAR2 IS
    BEGIN
      RETURN rtrim(rtrim(to_char(round(v, 2), 'FM99990.99', 'NLS_NUMERIC_CHARACTERS=''.,'''), '0'), '.');
    END;
  BEGIN
    l_pages := paginate(st, p_inst, p_fonts, p_options);
    dbms_lob.createtemporary(l_out, TRUE);
    dbms_lob.append(l_out, 'PAGES ' || l_pages || chr(10));
    FOR pg IN 1 .. l_pages LOOP
      FOR i IN 1 .. st.ops.COUNT LOOP
        o := st.ops(i);
        CONTINUE WHEN o.pg <> pg;
        dbms_lob.append(l_out, pg || ' ' || o.kind || ' ' || n(o.x) || ' ' || n(o.y) || ' '
          || CASE o.kind
               WHEN 'T' THEN CASE o.fcode WHEN 'PAGE' THEN to_char(pg) WHEN 'NUMPAGES' THEN to_char(l_pages) ELSE o.txt END
                             || ' [' || o.sz || CASE WHEN o.color <> '000000' THEN ' #' || o.color END || ']'
               WHEN 'L' THEN n(o.x2) || ' ' || n(o.y2) || ' ' || n(o.lw) || ' #' || o.color
               WHEN 'F' THEN n(o.w) || 'x' || n(o.h) || ' #' || o.color
               ELSE n(o.w) || 'x' || n(o.h) || ' res ' || o.res END || chr(10));
      END LOOP;
    END LOOP;
    close_quietly(st);
    RETURN l_out;
  EXCEPTION
    WHEN OTHERS THEN
      close_quietly(st);
      RAISE;
  END layout_dump;

END rad_pdf_pager;
/
