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
    top1 NUMBER, bottom1 NUMBER, topn NUMBER, bottomn NUMBER,   -- the body frame of page 1 and of the others
    after    NUMBER := 0,                                -- the space_after still to place
    fresh    BOOLEAN := FALSE,                           -- at the top of a page after an automatic break
    guess    PLS_INTEGER := 1,                           -- the page count the fields are measured with
    dfmt     rad_pdf_ri.t_run_fmt,                       -- the format of an empty paragraph (the first run's)
    dry      BOOLEAN := FALSE);                          -- measuring: no operation recorded

  PROCEDURE fail(p_code IN PLS_INTEGER, p_msg IN VARCHAR2) IS
  BEGIN
    raise_application_error(p_code, CASE p_code WHEN c_err_font THEN '[PDF_FONT] ' ELSE '[PDF_LAYOUT] ' END || substr(p_msg, 1, 1900));
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

  FUNCTION plan_para(st IN OUT NOCOPY t_st, p_id IN rad_pdf_ri.t_id, p_width IN NUMBER, p_page IN PLS_INTEGER DEFAULT NULL,
                     p_pages IN PLS_INTEGER DEFAULT NULL) RETURN t_plan IS
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
                                ELSE to_char(nvl(p_pages, st.guess)) END, n.fmt, 'FLD', CASE WHEN p_page IS NULL THEN n.field_code END);
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
    x := l_left + p.para.ind_first;
    FOR i IN 1 .. p.toks.COUNT LOOP
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
          IF l_vis AND x + p.toks(i).w > l_right + 0.001 THEN
            end_line(i - 1, FALSE);
            x := l_left; l_vis := FALSE;
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

  FUNCTION edge(p_cell rad_pdf_ri.t_border, p_table rad_pdf_ri.t_border) RETURN rad_pdf_ri.t_border IS
  BEGIN
    RETURN CASE WHEN p_cell.style IS NOT NULL THEN p_cell ELSE p_table END;
  END edge;

  -- the top border of a row: the table's top for the first row on a page, inside_h otherwise
  FUNCTION top_width(t rad_pdf_ri.t_node, p_first BOOLEAN) RETURN NUMBER IS
    b rad_pdf_ri.t_border := CASE WHEN p_first THEN t.borders.top ELSE t.borders.inside_h END;
  BEGIN
    RETURN CASE WHEN b.style = 'SINGLE' THEN nvl(b.width, 0) ELSE 0 END;
  END top_width;

  -- a row measured (dry) or drawn at y; returns its height (its top border + its tallest cell)
  FUNCTION do_row(st IN OUT NOCOPY t_st, p_tbl rad_pdf_ri.t_id, p_row rad_pdf_ri.t_id, x0 NUMBER, y NUMBER,
                  p_first BOOLEAN, p_draw BOOLEAN, p_page PLS_INTEGER DEFAULT NULL, p_pages PLS_INTEGER DEFAULT NULL) RETURN NUMBER IS
    t     rad_pdf_ri.t_node := st.inst.nodes(p_tbl);
    cx    rad_pdf_ri.t_num_list := col_x(t.grid);
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, p_row);
    c     rad_pdf_ri.t_cell_fmt;
    l_col PLS_INTEGER := 1;
    l_bt  NUMBER := top_width(t, p_first);
    l_h   NUMBER := 0;
    l_x1  NUMBER;
    l_x2  NUMBER;
    l_dry BOOLEAN := st.dry;
    l_end NUMBER;
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
        -- borders: top, left; right of the last cell
        op_line(st, l_x1, y + l_bt / 2, l_x2, y + l_bt / 2,
                edge(c.borders.top, CASE WHEN p_first THEN t.borders.top ELSE t.borders.inside_h END));
        op_line(st, l_x1, y, l_x1, y + l_bt + l_h, edge(c.borders.lft, CASE WHEN l_col = 1 THEN t.borders.lft ELSE t.borders.inside_v END));
        IF j = k.COUNT THEN
          op_line(st, l_x2, y, l_x2, y + l_bt + l_h, edge(c.borders.rgt, t.borders.rgt));
        END IF;
        l_col := l_col + c.grid_span;
      END LOOP;
    END IF;
    RETURN l_bt + l_h;
  END do_row;

  -- the bottom border of a table (or of its part on a page) under the row ending at y
  FUNCTION bottom_border(st IN OUT NOCOPY t_st, p_tbl rad_pdf_ri.t_id, x0 NUMBER, y NUMBER) RETURN NUMBER IS
    t  rad_pdf_ri.t_node := st.inst.nodes(p_tbl);
    cx rad_pdf_ri.t_num_list := col_x(t.grid);
    w  NUMBER := CASE WHEN t.borders.bottom.style = 'SINGLE' THEN nvl(t.borders.bottom.width, 0) ELSE 0 END;
  BEGIN
    op_line(st, x0, y + w / 2, x0 + cx(cx.COUNT), y + w / 2, t.borders.bottom);
    RETURN w;
  END bottom_border;

  FUNCTION fixed_table(st IN OUT NOCOPY t_st, p_id rad_pdf_ri.t_id, x0 NUMBER, y NUMBER, p_page PLS_INTEGER, p_pages PLS_INTEGER) RETURN NUMBER IS
    k   rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, p_id);
    l_y NUMBER := y;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      l_y := l_y + do_row(st, p_id, k(j), x0, l_y, j = 1, TRUE, p_page, p_pages);
    END LOOP;
    RETURN l_y + bottom_border(st, p_id, x0, l_y);
  END fixed_table;

  -- ---------------------------------------------------------------------------
  -- the page flow of the body
  -- ---------------------------------------------------------------------------
  FUNCTION top_of(st IN t_st, p_pg PLS_INTEGER) RETURN NUMBER IS
  BEGIN
    RETURN CASE WHEN p_pg = 1 THEN st.top1 ELSE st.topn END;
  END top_of;

  FUNCTION bottom_of(st IN t_st, p_pg PLS_INTEGER) RETURN NUMBER IS
  BEGIN
    RETURN CASE WHEN p_pg = 1 THEN st.bottom1 ELSE st.bottomn END;
  END bottom_of;

  PROCEDURE new_page(st IN OUT NOCOPY t_st) IS
  BEGIN
    st.pg := st.pg + 1;
    st.y := top_of(st, st.pg);
    st.fresh := TRUE;
    st.after := 0;
  END new_page;

  -- the height a block needs at the top of a chain: a paragraph whole (p_whole) or its first line; a table its header
  -- rows and its first body row
  FUNCTION need_of(st IN OUT NOCOPY t_st, p_id rad_pdf_ri.t_id, p_whole BOOLEAN) RETURN NUMBER IS
    n  rad_pdf_ri.t_node := st.inst.nodes(p_id);
    p  t_plan;
    k  rad_pdf_ri.t_num_list;
    l_h NUMBER := 0;
    l_dry BOOLEAN := st.dry;
  BEGIN
    IF n.kind = 'paragraph' THEN
      p := plan_para(st, p_id, st.width);
      RETURN CASE WHEN p_whole THEN p.h ELSE p.lines(1).h END;
    ELSIF n.kind = 'table' THEN
      st.dry := TRUE;
      k := rad_pdf_ri.kids(st.inst, p_id);
      FOR j IN 1 .. k.COUNT LOOP
        l_h := l_h + do_row(st, p_id, k(j), 0, 0, j = 1, FALSE);
        EXIT WHEN st.inst.nodes(k(j)).header <> 'Y';
      END LOOP;
      st.dry := l_dry;
      RETURN l_h;
    ELSIF n.kind = 'fixed_box' THEN RETURN n.height;
    END IF;
    RETURN 0;
  END need_of;

  -- keep_next (96a §8): the chain from block j must fit; it starts on a new page when it does not fit here
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
    IF l_need > bottom_of(st, st.pg + 1) - top_of(st, st.pg + 1) + 0.001 THEN
      fail(c_err_layout, 'a keep-with-next chain of ' || round(l_need, 2) || ' pt is taller than the page');
    END IF;
    IF st.y + l_need > bottom_of(st, st.pg) + 0.001 AND NOT st.fresh THEN new_page(st); END IF;
  END keep_chain;

  PROCEDURE flow_para(st IN OUT NOCOPY t_st, p_id rad_pdf_ri.t_id) IS
    p     t_plan := plan_para(st, p_id, st.width);
    l_gap NUMBER := greatest(st.after, p.para.space_before);
    l_y   NUMBER;
  BEGIN
    IF st.fresh THEN l_gap := 0; END IF;                 -- the top of a page after an automatic break
    IF st.y + l_gap + p.lines(1).h > bottom_of(st, st.pg) + 0.001 AND NOT st.fresh THEN new_page(st); l_gap := 0; END IF;
    st.y := st.y + l_gap;
    FOR l IN 1 .. p.lines.COUNT LOOP
      IF st.y + p.lines(l).h > bottom_of(st, st.pg) + 0.001 AND NOT st.fresh THEN new_page(st); END IF;
      l_y := draw_lines(st, p, l, l, st.left, st.y);
      st.y := l_y;
      st.fresh := FALSE;
    END LOOP;
    st.after := p.para.space_after;
  END flow_para;

  PROCEDURE flow_table(st IN OUT NOCOPY t_st, p_id rad_pdf_ri.t_id) IS
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, p_id);
    l_hdr PLS_INTEGER := 0;                              -- the leading header rows
    l_h   NUMBER;
    l_first BOOLEAN := TRUE;                             -- the first row of the table on this page
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      EXIT WHEN st.inst.nodes(k(j)).header <> 'Y';
      l_hdr := j;
    END LOOP;
    IF NOT st.fresh THEN st.y := st.y + st.after; END IF;
    st.after := 0;
    FOR j IN 1 .. k.COUNT LOOP
      l_h := do_row(st, p_id, k(j), st.left, st.y, l_first, FALSE);
      IF st.y + l_h > bottom_of(st, st.pg) + 0.001 AND NOT (st.fresh AND l_first) THEN
        IF NOT l_first THEN st.y := st.y + bottom_border(st, p_id, st.left, st.y); END IF;
        new_page(st);
        l_first := TRUE;
        IF j > l_hdr THEN                                -- the header rows repeated
          FOR h IN 1 .. l_hdr LOOP
            st.y := st.y + do_row(st, p_id, k(h), st.left, st.y, l_first, TRUE);
            l_first := FALSE;
          END LOOP;
        END IF;
        l_h := do_row(st, p_id, k(j), st.left, st.y, l_first, FALSE);
      END IF;
      IF l_h > bottom_of(st, st.pg) - top_of(st, st.pg) + 0.001 THEN
        fail(c_err_layout, 'a table row of ' || round(l_h, 2) || ' pt is taller than the page (rows are not split in v1)');
      END IF;
      st.y := st.y + do_row(st, p_id, k(j), st.left, st.y, l_first, TRUE);
      l_first := FALSE;
      st.fresh := FALSE;
    END LOOP;
    st.y := st.y + bottom_border(st, p_id, st.left, st.y);
  END flow_table;

  PROCEDURE flow_body(st IN OUT NOCOPY t_st) IS
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(st.inst, rad_pdf_ri.zone(st.inst, 'body'));
    n rad_pdf_ri.t_node;
  BEGIN
    st.pg := 1; st.y := st.top1; st.fresh := FALSE; st.after := 0; st.ops.DELETE;
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
        WHEN 'page_break' THEN st.pg := st.pg + 1; st.y := top_of(st, st.pg); st.fresh := FALSE; st.after := 0;
        WHEN 'fixed_box'  THEN
          IF NOT st.fresh THEN st.y := st.y + st.after; END IF;
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

  PROCEDURE frames(st IN OUT NOCOPY t_st) IS
    s rad_pdf_ri.t_node := st.inst.nodes(st.inst.section_id);
  BEGIN
    st.top1    := greatest(s.mar_top, s.mar_header + zone_h(st, zone_name(st, 'header', 1), 1, st.guess));
    st.bottom1 := st.page_h - greatest(s.mar_bottom, s.mar_footer + zone_h(st, zone_name(st, 'footer', 1), 1, st.guess));
    st.topn    := greatest(s.mar_top, s.mar_header + zone_h(st, zone_name(st, 'header', 2), 2, st.guess));
    st.bottomn := st.page_h - greatest(s.mar_bottom, s.mar_footer + zone_h(st, zone_name(st, 'footer', 2), 2, st.guess));
    IF st.bottom1 - st.top1 < 1 OR st.bottomn - st.topn < 1 THEN fail(c_err_layout, 'the header and footer leave no body'); END IF;
  END frames;

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
    l_tpl   rad_pdf_types.t_page_template;
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
    l_tpl.page_width := s.page_w; l_tpl.page_height := s.page_h;
    l_tpl.margin_top := s.mar_top; l_tpl.margin_bottom := s.mar_bottom;
    l_tpl.margin_left := s.mar_left; l_tpl.margin_right := s.mar_right;
    l_info.title := p_options.title;
    st.doc := rad_pdf.new_document(p_info => l_info, p_template => l_tpl);
    -- the double pass of NUMPAGES: again while the count has more digits than the guess
    FOR pass IN 1 .. 3 LOOP
      frames(st);
      flow_body(st);
      l_pages := st.pg;
      EXIT WHEN length(to_char(l_pages)) <= length(to_char(st.guess));
      st.guess := l_pages;
    END LOOP;
    zones(st, l_pages);
    RETURN l_pages;
  END paginate;

  PROCEDURE close_quietly(st IN OUT NOCOPY t_st) IS
  BEGIN
    IF st.doc IS NOT NULL THEN
      BEGIN rad_pdf.close_document(st.doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
  END close_quietly;

  FUNCTION render(p_inst IN rad_pdf_ri.t_ri, p_fonts IN t_font_files, p_options IN t_options DEFAULT NULL) RETURN BLOB IS
    st      t_st;
    l_pages PLS_INTEGER;
  BEGIN
    l_pages := paginate(st, p_inst, p_fonts, p_options);
    draw(st, p_inst, l_pages);
    RETURN rad_pdf.finalize(st.doc);
  EXCEPTION
    WHEN OTHERS THEN
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
