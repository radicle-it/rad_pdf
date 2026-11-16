-- quote_ri.sql - step B1 of the Word evolution (middleware-docs 96a §1b.1): the RI of the sal_ quote template BUILT BY
-- HAND (tests/word/samples/sal_quote_v1.docx, its values read from its XML: margins, styles, table, header/footer),
-- sealed, dumped as JSON, then rendered with the data of sal_quote_v1.json through the EXISTING engine to compare the
-- page count with Word's export (sal_quote_v1_word.pdf: 3 pages; lines 1-18 on page 1, 19-40 on page 2).
--
-- Since B2 the bridge renders the INSTANCE given by rad_pdf_merge (template + sal_quote_v1_schema.json + data); the
-- negative samples sal_quote_v1_neg_*.json go through the same merge and must be refused with [PRT_DATA].
-- Run by tests/word/quote_ri.py (it puts the data, the schema and the negatives in place of @@DATA@@, @@SCHEMA@@ and
-- @@NEG@@, and reads RIJSON:/INSTNODES:/NEG:/PDFHEX: lines). The code
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
  l_schema CLOB := q'~@@SCHEMA@@~';
  inst    rad_pdf_ri.t_ri;
  l_sch   rad_pdf_merge.t_schema;
  TYPE t_texts IS TABLE OF CLOB INDEX BY PLS_INTEGER;
  TYPE t_names IS TABLE OF VARCHAR2(100) INDEX BY PLS_INTEGER;
  l_neg   t_texts;
  l_negn  t_names;
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
  -- 2. the bridge (test object): the merged INSTANCE (rad_pdf_merge) mapped to the existing flowables
  -- ===========================================================================
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

  FUNCTION first_fmt(p_id rad_pdf_ri.t_id) RETURN rad_pdf_ri.t_run_fmt IS
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(inst, p_id);
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      IF inst.nodes(k(j)).kind IN ('run', 'field') THEN RETURN inst.nodes(k(j)).fmt; END IF;
    END LOOP;
    RETURN NULL;
  END first_fmt;

  -- the inlines of a paragraph of the instance (fields as engine tokens for headers/footers)
  PROCEDURE inlines(p_id rad_pdf_ri.t_id, p_runs IN OUT NOCOPY rad_pdf_types.t_inline_run_list, p_align CHAR, p_mult NUMBER) IS
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(inst, p_id);
    n rad_pdf_ri.t_node;
    i PLS_INTEGER;
    l_last rad_pdf_ri.t_run_fmt := first_fmt(p_id);
    PROCEDURE add(p_text VARCHAR2, p_fmt rad_pdf_ri.t_run_fmt, p_br BOOLEAN DEFAULT FALSE) IS
    BEGIN
      i := p_runs.COUNT + 1;
      p_runs(i).text := p_text; p_runs(i).is_br := p_br;
      p_runs(i).style_name := style_of(p_fmt, p_align, p_mult);
    END;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      n := inst.nodes(k(j));
      CASE n.kind
        WHEN 'run'        THEN add(n.text, n.fmt); l_last := n.fmt;
        WHEN 'field'      THEN add(CASE n.field_code WHEN 'PAGE' THEN '#PAGE_NR#' ELSE '#PAGE_COUNT#' END, n.fmt);
        WHEN 'tab'        THEN add(' ', l_last);                    -- B3: tab stops
        WHEN 'line_break' THEN add(NULL, l_last, TRUE);
        ELSE NULL;
      END CASE;
    END LOOP;
  END inlines;

  -- the plain text of a paragraph of the instance (a table cell)
  FUNCTION text_of(p_id rad_pdf_ri.t_id) RETURN VARCHAR2 IS
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(inst, p_id);
    l VARCHAR2(32767);
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      IF inst.nodes(k(j)).kind = 'run' THEN l := l || inst.nodes(k(j)).text; END IF;
    END LOOP;
    RETURN l;
  END text_of;

  PROCEDURE paragraph(p_id rad_pdf_ri.t_id) IS
    pf    rad_pdf_ri.t_para_fmt := inst.nodes(p_id).para;
    l_runs rad_pdf_types.t_inline_run_list;
    l_f   rad_pdf_types.t_flowable;
  BEGIN
    IF GREATEST(l_after, pf.space_before) > 0 THEN
      rad_pdf_layout.add(l_doc, rad_pdf_layout.spacer(GREATEST(l_after, pf.space_before)));
    END IF;
    inlines(p_id, l_runs, pf.align, pf.line_mult);
    IF l_runs.COUNT = 0 THEN
      -- an empty paragraph still takes its line (Word)
      rad_pdf_layout.add(l_doc, rad_pdf_layout.spacer(ROUND(10 * c_arial * pf.line_mult, 3)));
    ELSE
      l_f := rad_pdf_layout.paragraph_runs(l_doc, l_runs, l_runs(1).style_name);
      l_f.keep_with_next := pf.keep_next = 'Y';
      rad_pdf_layout.add(l_doc, l_f);
    END IF;
    l_after := pf.space_after;
  END paragraph;

  -- a table of the instance: its header row + its body rows, given to rad_pdf_table as a JSON array of cell texts
  PROCEDURE table_(p_id rad_pdf_ri.t_id) IS
    n     rad_pdf_ri.t_node := inst.nodes(p_id);
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(inst, p_id);
    l_hdr rad_pdf_ri.t_num_list;
    l_row rad_pdf_ri.t_num_list;
    l_rows json_array_t := json_array_t();
    l_one json_array_t;
    l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
    l_cs  rad_pdf_types.t_color_scheme;
    l_opt rad_pdf_types.t_table_options;
    l_sql VARCHAR2(32767);
    l_rc  SYS_REFCURSOR;
    l_cp  rad_pdf_ri.t_id;
    l_fmt rad_pdf_types.t_cell_format;
    l_rf  rad_pdf_ri.t_run_fmt;
    l_line NUMBER;
    l_rows_clob CLOB;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      IF inst.nodes(k(j)).header = 'Y' THEN l_hdr := rad_pdf_ri.kids(inst, k(j));
      ELSE
        l_row := rad_pdf_ri.kids(inst, k(j));
        l_one := json_array_t();
        FOR c IN 1 .. l_row.COUNT LOOP l_one.append(text_of(rad_pdf_ri.kids(inst, l_row(c))(1))); END LOOP;
        l_rows.append(l_one);
      END IF;
    END LOOP;
    l_sql := 'SELECT * FROM JSON_TABLE(:d, ''$[*]'' COLUMNS (';
    FOR c IN 1 .. l_row.COUNT LOOP
      l_cp := rad_pdf_ri.kids(inst, l_row(c))(1);
      l_rf := first_fmt(rad_pdf_ri.kids(inst, l_hdr(c))(1));       -- the format of the cells: Arial 10 here
      l_line := ROUND(l_rf.size_pt * c_arial * inst.nodes(l_cp).para.line_mult, 3);
      l_sql := l_sql || CASE WHEN c > 1 THEN ', ' END || 'c' || c || ' VARCHAR2(4000) PATH ''$[' || (c - 1) || ']''';
      l_cols.EXTEND;
      l_cols(c).label := text_of(rad_pdf_ri.kids(inst, l_hdr(c))(1));
      l_cols(c).width := n.grid(c);
      l_cols(c).wrap  := TRUE;
      l_fmt.font_name := 'Helvetica'; l_fmt.font_size := l_rf.size_pt; l_fmt.font_style := 'N';
      l_fmt.align_h := inst.nodes(l_cp).para.align; l_fmt.align_v := 'T';
      l_fmt.border := rad_pdf_types.c_border_all; l_fmt.line_size := n.borders.top.width; l_fmt.line_color := n.borders.top.color;
      l_fmt.margin_left := inst.nodes(l_row(c)).cell.mar_left; l_fmt.margin_rgt := inst.nodes(l_row(c)).cell.mar_right;
      l_fmt.margin_top := 0;
      l_fmt.margin_bot := inst.nodes(l_cp).para.space_after + n.borders.inside_h.width;   -- Word adds the row border
      l_fmt.spacing := TO_CHAR(l_line, 'FM990.999', 'NLS_NUMERIC_CHARACTERS=''.,''');
      l_cols(c).data_fmt := l_fmt;
      l_fmt.font_style := 'B'; l_fmt.align_h := 'L';
      l_cols(c).header_fmt := l_fmt;
      l_opt.h_row_height := l_line + l_fmt.margin_bot;
      l_opt.t_row_height := l_line + l_fmt.margin_bot;
    END LOOP;
    l_sql := l_sql || ')) jt';
    l_cs.header_ink := '000000'; l_cs.header_paper := inst.nodes(l_hdr(1)).cell.shading; l_cs.header_border := n.borders.top.color;
    l_cs.even_paper := 'ffffff'; l_cs.odd_paper := 'ffffff';
    l_cs.even_border := n.borders.top.color; l_cs.odd_border := n.borders.top.color;
    l_opt.unit := 'pt';
    IF l_after > 0 THEN rad_pdf_layout.add(l_doc, rad_pdf_layout.spacer(l_after)); l_after := 0; END IF;
    l_rows_clob := l_rows.to_clob;
    OPEN l_rc FOR l_sql USING l_rows_clob;
    rad_pdf_layout.add(l_doc, rad_pdf_table.table_flow(l_doc, l_rc, l_cols, l_cs, l_opt));
  END table_;

  PROCEDURE blocks(p_id rad_pdf_ri.t_id) IS
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(inst, p_id);
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      CASE inst.nodes(k(j)).kind
        WHEN 'paragraph'    THEN paragraph(k(j));
        WHEN 'table'        THEN table_(k(j));
        WHEN 'page_break'   THEN rad_pdf_layout.add(l_doc, rad_pdf_layout.page_break);
        ELSE NULL;
      END CASE;
    END LOOP;
  END blocks;

  -- a header/footer zone as engine page-procedure code (the engine replaces #PAGE_NR# #PAGE_COUNT# #DOC_HANDLE#)
  FUNCTION zone_code(p_zone VARCHAR2, p_top BOOLEAN) RETURN VARCHAR2 IS
    s     rad_pdf_ri.t_node := inst.nodes(inst.section_id);
    k     rad_pdf_ri.t_num_list := rad_pdf_ri.kids(inst, rad_pdf_ri.zone(inst, p_zone));
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
        l_y := l_y + first_fmt(k(j)).size_pt * c_arial * inst.nodes(k(j)).para.line_mult;
      END LOOP;
    END IF;
    FOR j IN 1 .. k.COUNT LOOP
      l_runs := l_none;
      inlines(k(j), l_runs, 'L', 1);
      l_text := NULL;
      FOR i IN 1 .. l_runs.COUNT LOOP l_text := l_text || l_runs(i).text; END LOOP;
      l_fmt := first_fmt(k(j));
      l_st := CASE WHEN l_fmt.bold = 'Y' THEN 'B' ELSE 'N' END;
      l_line := l_fmt.size_pt * c_arial * inst.nodes(k(j)).para.line_mult;
      l_y := l_y - 1854 / 2048 * l_fmt.size_pt;            -- baseline: Arial ascent
      l_code := l_code || 'rad_pdf_canvas.set_font(#DOC_HANDLE#,''Helvetica'',''' || l_st || ''',' || l_fmt.size_pt || ');'
        || 'l_t:=''' || REPLACE(l_text, '''', '''''') || ''';'
        || 'rad_pdf_canvas.write_text(#DOC_HANDLE#,l_t,'
        || CASE inst.nodes(k(j)).para.align
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
    s     rad_pdf_ri.t_node := inst.nodes(inst.section_id);
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
    blocks(rad_pdf_ri.zone(inst, 'body'));
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
  -- the merge (B2): the template + the schema + the data -> the instance, then the bridge renders the instance
  l_sch := rad_pdf_merge.schema_from_json(l_schema);
  rad_pdf_merge.check_template(ri, l_sch);
  inst := rad_pdf_merge.merge(ri, l_sch, l_data);
  DBMS_OUTPUT.PUT_LINE('INSTNODES:' || rad_pdf_ri.node_count(inst));
  -- the negative samples (96a section 10): each refused with [PRT_DATA] and its path
@@NEG@@
  FOR i IN 1 .. l_neg.COUNT LOOP
    DECLARE
      x rad_pdf_ri.t_ri;
    BEGIN
      x := rad_pdf_merge.merge(ri, l_sch, l_neg(i));
      DBMS_OUTPUT.PUT_LINE('NEG:' || l_negn(i) || ':ACCEPTED');
      rad_pdf_ri.free(x);
    EXCEPTION
      WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('NEG:' || l_negn(i) || ':' || REGEXP_SUBSTR(SQLERRM, '\[[A-Z_]+\][^' || CHR(10) || ']*'));
    END;
  END LOOP;
  render;
  rad_pdf_test_dump('sal_quote_v1_ri', l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  -- the paginator (B3): the same instance, Arial drawn with its D3 substitute from rad_pdf_test_font
  DECLARE
    l_fonts rad_pdf_pager.t_font_files;
    l_opt   rad_pdf_pager.t_options;
  BEGIN
    SELECT family, variant, bytes BULK COLLECT INTO l_fonts FROM rad_pdf_test_font ORDER BY family, variant;
    l_opt.title := 'sal_quote_v1 (pager)';
    l_pdf := rad_pdf_pager.render(inst, l_fonts, l_opt);
    rad_pdf_test_dump('sal_quote_v1_pager', l_pdf);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;
  -- volume (96a section 10.5): the same quote with 500 lines (the 40 of the sample repeated), merged and paginated,
  -- timed in hundredths of a second; reported, not a gate
  DECLARE
    l_fonts rad_pdf_pager.t_font_files;
    l_root  json_object_t := json_object_t.parse(l_data);
    l_lines json_array_t := l_root.get_array('lines');
    l_big   json_array_t := json_array_t();
    l_t0    PLS_INTEGER;
    l_t1    PLS_INTEGER;
    l_t2    PLS_INTEGER;
    l_inst  rad_pdf_ri.t_ri;
    l_vol   BLOB;
  BEGIN
    SELECT family, variant, bytes BULK COLLECT INTO l_fonts FROM rad_pdf_test_font ORDER BY family, variant;
    FOR i IN 0 .. 499 LOOP l_big.append(l_lines.get(MOD(i, l_lines.get_size))); END LOOP;
    l_root.put('lines', l_big);
    l_t0 := DBMS_UTILITY.GET_TIME;
    l_inst := rad_pdf_merge.merge(ri, l_sch, l_root.to_clob);
    l_t1 := DBMS_UTILITY.GET_TIME;
    l_vol := rad_pdf_pager.render(l_inst, l_fonts);
    l_t2 := DBMS_UTILITY.GET_TIME;
    DBMS_OUTPUT.PUT_LINE('VOLUME:500:' || rad_pdf_ri.node_count(l_inst) || ':' || (l_t1 - l_t0) || ':' || (l_t2 - l_t1)
                         || ':' || DBMS_LOB.GETLENGTH(l_vol));
    rad_pdf_test_dump('sal_quote_v1_500', l_vol);
    DBMS_LOB.FREETEMPORARY(l_vol);
    rad_pdf_ri.free(l_inst);
  END;
END;
/
