-- quote_ri.sql - step B1 of the Word evolution (middleware-docs 96a §1b.1): the RI of the sal_ quote template BUILT BY
-- HAND (tests/word/samples/sal_quote_v1.docx, its values read from its XML: margins, styles, table, header/footer),
-- sealed, dumped as JSON, then rendered with the data of sal_quote_v1.json through the EXISTING engine to compare the
-- page count with Word's export (sal_quote_v1_word.pdf: 3 pages; lines 1-18 on page 1, 19-40 on page 2).
--
-- Run by tests/word/quote_ri.py (it puts the data in place of @@DATA@@ and reads RIJSON:/PDFHEX: lines). The code
-- and the data are ASCII (UNISTR, JSON \u escapes): SQLcl does not read its standard input as UTF-8.
--
-- The bridge below (merge + mapping to rad_pdf_layout/rad_pdf_table flowables) is a TEST OBJECT, not the B3
-- paginator: it handles exactly what the quote uses, with these known approximations, said in the report:
--   - a tab is rendered as a space (the engine has no tab stops yet: B3);
--   - ind_left is not applied (no paragraph indent in the engine: B3); the indented lines are short, one line either way;
--   - Arial is drawn with the standard Helvetica (identical advance widths), not Liberation Sans (D3, B3);
--   - Word's row border (0.5 pt) is added to the row height as Word does; the cell paragraph's space_after becomes the
--     cell's bottom margin;
--   - between two paragraphs Word applies the LARGER of space_after and space_before, not their sum (measured on
--     sal_quote_v1_word.pdf: 10 after + 12 before = a 12 pt gap): a rule for the B3 paginator, applied here.
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
  c_cm    CONSTANT NUMBER := 72 / 2.54;
  c_arial CONSTANT NUMBER := (1854 + 434 + 67) / 2048;   -- Arial: (ascent + descent + line gap) / em = Word's single line
  l_data  CLOB := q'~@@DATA@@~';
  ri      rad_pdf_ri.t_ri;
  l_json  CLOB;
  l_pdf   BLOB;
  l_doc   rad_pdf_types.t_doc_handle;
  l_root  json_object_t;
  l_after NUMBER := 0;                                   -- the space_after still to place (Word: max with space_before)

  -- ===========================================================================
  -- 1. the template, by hand
  -- ===========================================================================
  FUNCTION build RETURN rad_pdf_ri.t_ri IS
    q    rad_pdf_ri.t_ri;
    s    rad_pdf_ri.t_id;
    b    rad_pdf_ri.t_id;
    p    rad_pdf_ri.t_id;
    t    rad_pdf_ri.t_id;
    r    rad_pdf_ri.t_id;
    c    rad_pdf_ri.t_id;
    g    rad_pdf_ri.t_id;
    x    rad_pdf_ri.t_id;
    fN   rad_pdf_ri.t_run_fmt;     -- Normal: Arial 10
    fB   rad_pdf_ri.t_run_fmt;
    fI   rad_pdf_ri.t_run_fmt;
    fH   rad_pdf_ri.t_run_fmt;     -- Heading 1: Arial 16 bold 1F3A5F
    pN   rad_pdf_ri.t_para_fmt;    -- Normal: after 10 pt, line 1.15 (docDefaults 200/276)
    pHF  rad_pdf_ri.t_para_fmt;    -- Header/Footer: after 0, single
    pX   rad_pdf_ri.t_para_fmt;
    cf   rad_pdf_ri.t_cell_fmt;
    bd   rad_pdf_ri.t_borders;
    tabs rad_pdf_ri.t_tab_list := rad_pdf_ri.t_tab_list();
    TYPE t_cols IS TABLE OF VARCHAR2(30);
    l_lab t_cols := t_cols('Pos.', 'Codice', 'Descrizione', 'Q.t' || UNISTR('\00E0'), 'UM', 'Prezzo', 'Importo');
    l_key t_cols := t_cols('line_no', 'code', 'description', 'qty', 'uom', 'unit_price', 'amount');
    l_w   rad_pdf_ri.t_num_list := rad_pdf_ri.t_num_list(1.2, 2.3, 6.5, 1.5, 1.2, 2.2, 2.1);

    PROCEDURE totals(p_label VARCHAR2, p_path VARCHAR2, p_fmt rad_pdf_ri.t_run_fmt) IS
      l_tabs rad_pdf_ri.t_tab_list := rad_pdf_ri.t_tab_list();
    BEGIN
      l_tabs.EXTEND; l_tabs(1).pos := 17 * c_cm; l_tabs(1).kind := 'D';
      pX := pN; pX.keep_next := 'Y';
      p := rad_pdf_ri.paragraph(q, b, pX, l_tabs);
      x := rad_pdf_ri.run(q, p, p_label, p_fmt);
      x := rad_pdf_ri.tab(q, p);
      x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, p_path, p_fmt);
    END;
  BEGIN
    fN.font := 'Arial'; fN.size_pt := 10;
    fB := fN; fB.bold := 'Y';
    fI := fN; fI.italic := 'Y';
    fH := fN; fH.size_pt := 16; fH.bold := 'Y'; fH.color := '1F3A5F';
    pN.space_after := 10; pN.line_mult := 1.15;
    q := rad_pdf_ri.new_ri;
    -- A4 11906x16838 twips, margins top 1417 right/bottom/left 1134, header/footer 720, titlePg
    s := rad_pdf_ri.section(q, 11906 / 20, 16838 / 20, 'P', 1417 / 20, 1134 / 20, 1134 / 20, 1134 / 20, 36, 36, 'Y');
    -- headers and footers
    p := rad_pdf_ri.paragraph(q, rad_pdf_ri.zone(q, 'header_first'), pHF);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'company.name', fB);
    p := rad_pdf_ri.paragraph(q, rad_pdf_ri.zone(q, 'header_first'), pHF);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'company.address', fN);
    p := rad_pdf_ri.paragraph(q, rad_pdf_ri.zone(q, 'header_default'), pHF);
    x := rad_pdf_ri.run(q, p, 'Offerta ', fN);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'quote.no', fN);
    pX := pHF; pX.align := 'R';
    FOR z IN 1 .. 2 LOOP
      p := rad_pdf_ri.paragraph(q, rad_pdf_ri.zone(q, CASE z WHEN 1 THEN 'footer_first' ELSE 'footer_default' END), pX);
      x := rad_pdf_ri.run(q, p, 'Pagina ', fN);
      x := rad_pdf_ri.field(q, p, 'PAGE', fN);
      x := rad_pdf_ri.run(q, p, ' di ', fN);
      x := rad_pdf_ri.field(q, p, 'NUMPAGES', fN);
    END LOOP;
    -- the body
    b := rad_pdf_ri.zone(q, 'body');
    pX := pN; pX.space_before := 24; pX.space_after := 0; pX.keep_next := 'Y';
    p := rad_pdf_ri.paragraph(q, b, pX);
    x := rad_pdf_ri.run(q, p, 'Offerta ', fH);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'quote.no', fH);
    x := rad_pdf_ri.run(q, p, ' ' || UNISTR('\00B7') || ' ', fH);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'quote.title', fH);
    tabs.EXTEND; tabs(1).pos := 17 * c_cm; tabs(1).kind := 'R';
    p := rad_pdf_ri.paragraph(q, b, pN, tabs);
    x := rad_pdf_ri.run(q, p, 'Data: ', fN);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'quote.date', fN);
    x := rad_pdf_ri.tab(q, p);
    x := rad_pdf_ri.run(q, p, 'Valida fino al: ', fN);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'quote.valid_until', fN);
    pX := pN; pX.ind_left := 5102 / 20; pX.space_before := 12;
    p := rad_pdf_ri.paragraph(q, b, pX);
    x := rad_pdf_ri.run(q, p, 'Spett.le ', fI);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'customer.name', fB);
    pX.space_before := 0;
    p := rad_pdf_ri.paragraph(q, b, pX);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'customer.address', fN);
    pX := pN; pX.align := 'J'; pX.space_before := 12; pX.space_after := 6;
    p := rad_pdf_ri.paragraph(q, b, pX);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'intro_text', fN);
    -- the lines: a repeated header row, one row repeated by the LOOP lines (a row_region)
    FOR i IN 1 .. l_w.COUNT LOOP l_w(i) := l_w(i) * c_cm; END LOOP;
    bd := rad_pdf_ri.borders_all(rad_pdf_ri.border('SINGLE', 0.5, '999999'));
    t := rad_pdf_ri.table_(q, b, l_w, bd);
    r := rad_pdf_ri.row_(q, t, 'Y', 'Y');
    cf.mar_left := 108 / 20; cf.mar_right := 108 / 20; cf.shading := 'DCE6F0';
    FOR k IN 1 .. l_lab.COUNT LOOP
      c := rad_pdf_ri.cell(q, r, cf);
      p := rad_pdf_ri.paragraph(q, c, pN);
      x := rad_pdf_ri.run(q, p, l_lab(k), fB);
    END LOOP;
    g := rad_pdf_ri.row_region(q, t, 'LOOP', NULL, 'lines');
    r := rad_pdf_ri.row_(q, g);
    cf.shading := NULL;
    FOR k IN 1 .. l_key.COUNT LOOP
      c := rad_pdf_ri.cell(q, r, cf);
      pX := pN; pX.align := CASE WHEN k >= 4 AND k <> 5 THEN 'R' ELSE 'L' END;
      p := rad_pdf_ri.paragraph(q, c, pX);
      x := rad_pdf_ri.tag(q, p, 'FIELD', 'lines', 'lines[].' || l_key(k), fN);
    END LOOP;
    -- totals: decimal tab, kept with the next
    totals('Imponibile', 'totals.net', fN);
    totals('IVA', 'totals.vat', fN);
    totals('Totale', 'totals.gross', fB);
    -- {#has_discount}...{/has_discount} inside one paragraph: an inline_region (the paragraph stays when false)
    p := rad_pdf_ri.paragraph(q, b, pN);
    g := rad_pdf_ri.inline_region(q, p, 'SECTION', NULL, 'has_discount');
    x := rad_pdf_ri.run(q, g, 'Gli importi includono gli sconti indicati.', fN);
    p := rad_pdf_ri.paragraph(q, b, pN);
    x := rad_pdf_ri.run(q, p, 'Condizioni di pagamento: ', fN);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'payment_term', fN);
    pX := pN; pX.align := 'J';
    p := rad_pdf_ri.paragraph(q, b, pX);
    x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'closing_text', fN);
    rad_pdf_ri.seal(q);
    RETURN q;
  END build;

  -- ===========================================================================
  -- 2. the bridge (test object): data merge + existing flowables
  -- ===========================================================================
  -- the value at a dotted path of an object (NULL when absent)
  FUNCTION val(p_obj json_object_t, p_path VARCHAR2) RETURN VARCHAR2 IS
    l_o   json_object_t := p_obj;
    l_key VARCHAR2(400);
    l_rest VARCHAR2(400) := p_path;
    l_e   json_element_t;
  BEGIN
    LOOP
      l_key := REGEXP_SUBSTR(l_rest, '^[^.]+');
      l_rest := SUBSTR(l_rest, LENGTH(l_key) + 2);
      IF l_o IS NULL OR NOT l_o.has(l_key) THEN RETURN NULL; END IF;
      l_e := l_o.get(l_key);
      EXIT WHEN l_rest IS NULL;
      IF NOT l_e.is_object THEN RETURN NULL; END IF;
      l_o := TREAT(l_e AS json_object_t);
    END LOOP;
    IF l_e.is_null THEN RETURN NULL; END IF;
    IF l_e.is_string THEN RETURN l_o.get_string(l_key); END IF;
    RETURN l_e.to_string;
  END val;

  -- SECTION: false, null, absent, '' and [] hide
  FUNCTION truthy(p_path VARCHAR2) RETURN BOOLEAN IS
    l_v VARCHAR2(32767) := val(l_root, p_path);
  BEGIN
    RETURN l_v IS NOT NULL AND l_v NOT IN ('false', '[]', 'null');
  END truthy;

  -- one engine style per (format, alignment, line spacing): Word's line = size * Arial ratio * multiple
  FUNCTION style_of(p_fmt rad_pdf_ri.t_run_fmt, p_align CHAR, p_mult NUMBER) RETURN VARCHAR2 IS
    l_st   VARCHAR2(2) := CASE WHEN p_fmt.bold = 'Y' AND p_fmt.italic = 'Y' THEN 'BI' WHEN p_fmt.bold = 'Y' THEN 'B'
                               WHEN p_fmt.italic = 'Y' THEN 'I' ELSE 'N' END;
    l_name VARCHAR2(100) := 'ri_' || l_st || '_' || p_fmt.size_pt || '_' || p_fmt.color || '_' || p_align || '_' || p_mult;
  BEGIN
    IF NOT rad_pdf_styles.exists_style(l_name) THEN
      rad_pdf_styles.define(l_name, 'Helvetica', l_st, p_fmt.size_pt, p_fmt.color, p_align_h => p_align,
                            p_leading => ROUND(p_fmt.size_pt * c_arial * p_mult, 3));
    END IF;
    RETURN l_name;
  END style_of;

  -- the text of the inlines of a paragraph or an inline_region, merged (fields as engine tokens for headers/footers)
  PROCEDURE inlines(p_id rad_pdf_ri.t_id, p_para rad_pdf_types.t_inline_run_list, p_runs IN OUT NOCOPY rad_pdf_types.t_inline_run_list,
                    p_align CHAR, p_mult NUMBER) IS
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(ri, p_id);
    n rad_pdf_ri.t_node;
    i PLS_INTEGER;
    PROCEDURE add(p_text VARCHAR2, p_fmt rad_pdf_ri.t_run_fmt, p_br BOOLEAN DEFAULT FALSE) IS
    BEGIN
      i := p_runs.COUNT + 1;
      p_runs(i).text := p_text; p_runs(i).is_br := p_br;
      p_runs(i).style_name := style_of(p_fmt, p_align, p_mult);
    END;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      n := ri.nodes(k(j));
      CASE n.kind
        WHEN 'run'        THEN add(n.text, n.fmt);
        WHEN 'tag'        THEN add(val(l_root, n.ref_path), n.fmt);
        WHEN 'field'      THEN add(CASE n.field_code WHEN 'PAGE' THEN '#PAGE_NR#' ELSE '#PAGE_COUNT#' END, n.fmt);
        WHEN 'tab'        THEN add(' ', ri.nodes(p_id).fmt);              -- B3: tab stops
        WHEN 'line_break' THEN add(NULL, ri.nodes(p_id).fmt, TRUE);
        WHEN 'inline_region' THEN IF truthy(n.ref_path) THEN inlines(k(j), p_para, p_runs, p_align, p_mult); END IF;
      END CASE;
    END LOOP;
  END inlines;

  FUNCTION first_fmt(p_id rad_pdf_ri.t_id) RETURN rad_pdf_ri.t_run_fmt IS
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(ri, p_id);
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      IF ri.nodes(k(j)).kind IN ('run', 'tag', 'field') THEN RETURN ri.nodes(k(j)).fmt; END IF;
    END LOOP;
    RETURN NULL;
  END first_fmt;

  PROCEDURE paragraph(p_id rad_pdf_ri.t_id) IS
    pf    rad_pdf_ri.t_para_fmt := ri.nodes(p_id).para;
    l_runs rad_pdf_types.t_inline_run_list;
    l_none rad_pdf_types.t_inline_run_list;
    l_f   rad_pdf_types.t_flowable;
  BEGIN
    IF GREATEST(l_after, pf.space_before) > 0 THEN
      rad_pdf_layout.add(l_doc, rad_pdf_layout.spacer(GREATEST(l_after, pf.space_before)));
    END IF;
    inlines(p_id, l_none, l_runs, pf.align, pf.line_mult);
    IF l_runs.COUNT = 0 OR (l_runs.COUNT = 1 AND l_runs(1).text IS NULL) THEN
      -- an empty paragraph still takes its line (Word)
      rad_pdf_layout.add(l_doc, rad_pdf_layout.spacer(ROUND(10 * c_arial * pf.line_mult, 3)));
    ELSE
      l_f := rad_pdf_layout.paragraph_runs(l_doc, l_runs, l_runs(1).style_name);
      l_f.keep_with_next := pf.keep_next = 'Y';
      rad_pdf_layout.add(l_doc, l_f);
    END IF;
    l_after := pf.space_after;
  END paragraph;

  -- a table of the quote: header row + a row_region LOOP (JSON_TABLE over the array), mapped to rad_pdf_table
  PROCEDURE table_(p_id rad_pdf_ri.t_id) IS
    n     rad_pdf_ri.t_node := ri.nodes(p_id);
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(ri, p_id);
    l_hdr rad_pdf_ri.t_num_list;
    l_reg rad_pdf_ri.t_id;
    l_row rad_pdf_ri.t_num_list;
    l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
    l_cs  rad_pdf_types.t_color_scheme;
    l_opt rad_pdf_types.t_table_options;
    l_sql VARCHAR2(32767);
    l_rc  SYS_REFCURSOR;
    l_cp  rad_pdf_ri.t_id;       -- the paragraph of a cell
    l_tag rad_pdf_ri.t_node;
    l_fmt rad_pdf_types.t_cell_format;
    l_line NUMBER;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      IF ri.nodes(k(j)).kind = 'row' THEN l_hdr := rad_pdf_ri.kids(ri, k(j)); ELSE l_reg := k(j); END IF;
    END LOOP;
    l_row := rad_pdf_ri.kids(ri, rad_pdf_ri.kids(ri, l_reg)(1));
    l_sql := 'SELECT * FROM JSON_TABLE(:d, ''$.' || ri.nodes(l_reg).ref_path || '[*]'' COLUMNS (';
    FOR c IN 1 .. l_row.COUNT LOOP
      l_cp  := rad_pdf_ri.kids(ri, l_row(c))(1);
      l_tag := ri.nodes(rad_pdf_ri.kids(ri, l_cp)(1));
      l_line := ROUND(l_tag.fmt.size_pt * c_arial * ri.nodes(l_cp).para.line_mult, 3);
      l_sql := l_sql || CASE WHEN c > 1 THEN ', ' END || 'c' || c || ' VARCHAR2(4000) PATH ''$.'
               || SUBSTR(l_tag.ref_path, LENGTH(ri.nodes(l_reg).ref_path) + 4) || '''';
      l_cols.EXTEND;
      l_cols(c).label := ri.nodes(rad_pdf_ri.kids(ri, rad_pdf_ri.kids(ri, l_hdr(c))(1))(1)).text;
      l_cols(c).width := n.grid(c);
      l_cols(c).wrap  := TRUE;
      l_fmt.font_name := 'Helvetica'; l_fmt.font_size := l_tag.fmt.size_pt; l_fmt.font_style := 'N';
      l_fmt.align_h := ri.nodes(l_cp).para.align; l_fmt.align_v := 'T';
      l_fmt.border := rad_pdf_types.c_border_all; l_fmt.line_size := n.borders.top.width; l_fmt.line_color := n.borders.top.color;
      l_fmt.margin_left := ri.nodes(l_row(c)).cell.mar_left; l_fmt.margin_rgt := ri.nodes(l_row(c)).cell.mar_right;
      l_fmt.margin_top := 0;
      l_fmt.margin_bot := ri.nodes(l_cp).para.space_after + n.borders.inside_h.width;   -- Word adds the row border
      l_fmt.spacing := TO_CHAR(l_line, 'FM990.999', 'NLS_NUMERIC_CHARACTERS=''.,''');
      l_cols(c).data_fmt := l_fmt;
      l_fmt.font_style := 'B'; l_fmt.align_h := 'L';
      l_cols(c).header_fmt := l_fmt;
      l_opt.h_row_height := l_line + l_fmt.margin_bot;
      l_opt.t_row_height := l_line + l_fmt.margin_bot;
    END LOOP;
    l_sql := l_sql || ')) jt';
    l_cs.header_ink := '000000'; l_cs.header_paper := ri.nodes(l_hdr(1)).cell.shading; l_cs.header_border := n.borders.top.color;
    l_cs.even_paper := 'ffffff'; l_cs.odd_paper := 'ffffff';
    l_cs.even_border := n.borders.top.color; l_cs.odd_border := n.borders.top.color;
    l_opt.unit := 'pt';
    IF l_after > 0 THEN rad_pdf_layout.add(l_doc, rad_pdf_layout.spacer(l_after)); l_after := 0; END IF;
    OPEN l_rc FOR l_sql USING l_data;
    rad_pdf_layout.add(l_doc, rad_pdf_table.table_flow(l_doc, l_rc, l_cols, l_cs, l_opt));
  END table_;

  PROCEDURE blocks(p_id rad_pdf_ri.t_id) IS
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(ri, p_id);
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      CASE ri.nodes(k(j)).kind
        WHEN 'paragraph'    THEN paragraph(k(j));
        WHEN 'table'        THEN table_(k(j));
        WHEN 'page_break'   THEN rad_pdf_layout.add(l_doc, rad_pdf_layout.page_break);
        WHEN 'block_region' THEN IF truthy(ri.nodes(k(j)).ref_path) THEN blocks(k(j)); END IF;
      END CASE;
    END LOOP;
  END blocks;

  -- a header/footer zone as engine page-procedure code (the engine replaces #PAGE_NR# #PAGE_COUNT# #DOC_HANDLE#)
  FUNCTION zone_code(p_zone VARCHAR2, p_top BOOLEAN) RETURN VARCHAR2 IS
    s     rad_pdf_ri.t_node := ri.nodes(ri.section_id);
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(ri, rad_pdf_ri.zone(ri, p_zone));
    l_runs rad_pdf_types.t_inline_run_list;
    l_none rad_pdf_types.t_inline_run_list;
    l_code VARCHAR2(32767);
    l_text VARCHAR2(4000);
    l_fmt  rad_pdf_ri.t_run_fmt;
    l_line NUMBER;
    l_y    NUMBER;
    l_st   VARCHAR2(2);
  BEGIN
    l_y := CASE WHEN p_top THEN s.page_h - s.mar_header ELSE s.mar_footer END;
    IF NOT p_top THEN                                       -- a footer grows upwards from its distance
      FOR j IN 1 .. k.COUNT LOOP
        l_y := l_y + first_fmt(k(j)).size_pt * c_arial * ri.nodes(k(j)).para.line_mult;
      END LOOP;
    END IF;
    FOR j IN 1 .. k.COUNT LOOP
      l_runs := l_none;
      inlines(k(j), l_none, l_runs, 'L', 1);
      l_text := NULL;
      FOR i IN 1 .. l_runs.COUNT LOOP l_text := l_text || l_runs(i).text; END LOOP;
      l_fmt := first_fmt(k(j));
      l_st := CASE WHEN l_fmt.bold = 'Y' THEN 'B' ELSE 'N' END;
      l_line := l_fmt.size_pt * c_arial * ri.nodes(k(j)).para.line_mult;
      l_y := l_y - 1854 / 2048 * l_fmt.size_pt;            -- baseline: Arial ascent
      l_code := l_code || 'rad_pdf_canvas.set_font(#DOC_HANDLE#,''Helvetica'',''' || l_st || ''',' || l_fmt.size_pt || ');'
        || 'l_t:=''' || REPLACE(l_text, '''', '''''') || ''';'
        || 'rad_pdf_canvas.write_text(#DOC_HANDLE#,l_t,'
        || CASE ri.nodes(k(j)).para.align
             WHEN 'R' THEN TO_CHAR(s.page_w - s.mar_right, 'FM9990.99', 'NLS_NUMERIC_CHARACTERS=''.,''')
                           || '-rad_pdf_fonts.text_width(l_t,rad_pdf_fonts.find_font(#DOC_HANDLE#,''Helvetica'',''' || l_st || '''),' || l_fmt.size_pt || ')'
             ELSE TO_CHAR(s.mar_left, 'FM9990.99', 'NLS_NUMERIC_CHARACTERS=''.,''') END
        || ',' || TO_CHAR(l_y, 'FM9990.99', 'NLS_NUMERIC_CHARACTERS=''.,''') || ');';
      l_y := l_y - (l_line - 1854 / 2048 * l_fmt.size_pt);
    END LOOP;
    RETURN l_code;
  END zone_code;

  PROCEDURE out_lob(p_tag VARCHAR2, p_clob CLOB) IS
    l_pos PLS_INTEGER := 1;
  BEGIN
    WHILE l_pos <= DBMS_LOB.GETLENGTH(p_clob) LOOP
      DBMS_OUTPUT.PUT_LINE(p_tag || DBMS_LOB.SUBSTR(p_clob, 8000, l_pos));
      l_pos := l_pos + 8000;
    END LOOP;
  END out_lob;

  PROCEDURE render IS
    s     rad_pdf_ri.t_node := ri.nodes(ri.section_id);
    l_tpl rad_pdf_types.t_page_template;
    l_info rad_pdf_types.t_doc_info;
  BEGIN
    l_tpl.page_width := s.page_w; l_tpl.page_height := s.page_h;
    l_tpl.margin_top := s.mar_top; l_tpl.margin_bottom := s.mar_bottom;
    l_tpl.margin_left := s.mar_left; l_tpl.margin_right := s.mar_right;
    l_tpl.header_proc := 'DECLARE l_t VARCHAR2(4000); BEGIN IF #PAGE_NR# = 1 AND ''' || s.title_page || ''' = ''Y'' THEN '
      || NVL(zone_code('header_first', TRUE), 'NULL;') || ' ELSE ' || NVL(zone_code('header_default', TRUE), 'NULL;')
      || ' END IF; END;';
    l_tpl.footer_proc := 'DECLARE l_t VARCHAR2(4000); BEGIN IF #PAGE_NR# = 1 AND ''' || s.title_page || ''' = ''Y'' THEN '
      || NVL(zone_code('footer_first', FALSE), 'NULL;') || ' ELSE ' || NVL(zone_code('footer_default', FALSE), 'NULL;')
      || ' END IF; END;';
    l_info.title := 'sal_quote_v1 (RI B1)';
    l_doc := rad_pdf.new_document(p_info => l_info, p_template => l_tpl);
    blocks(rad_pdf_ri.zone(ri, 'body'));
    l_pdf := rad_pdf.finalize(l_doc);
  END render;

BEGIN
  rad_pdf_ctx.set_fixed_clock(TIMESTAMP '2026-01-01 00:00:00');
  ri := build;
  l_json := rad_pdf_ri.to_json(ri);
  -- the dump reads back to the same text
  IF DBMS_LOB.COMPARE(rad_pdf_ri.to_json(rad_pdf_ri.from_json(l_json)), l_json) <> 0 THEN
    RAISE_APPLICATION_ERROR(-20999, 'FAIL the quote RI does not read back to the same JSON');
  END IF;
  DBMS_OUTPUT.PUT_LINE('RINODES:' || rad_pdf_ri.node_count(ri));
  out_lob('RIJSON:', l_json);
  l_root := json_object_t.parse(l_data);
  render;
  rad_pdf_test_dump('sal_quote_v1_ri', l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
