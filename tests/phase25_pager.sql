-- phase25_pager.sql - the single paginator of the Word evolution (rad_pdf_pager; doc 96 §11.9 B2+B3, 96a §7.1, §9)
-- Run from repo root in SQL*Plus after src/install.sql AND python3 tests/word/load_fonts.py (the table
-- rad_pdf_test_font: Liberation Sans, the D3 substitute of Arial). The quote against Word's export: tests/word/quote_ri.py.
-- Each rule on a small instance built by code, read back from rad_pdf_pager.layout_dump (y from the top: the baseline):
--   1. lines: Word's single line from the font (hhea), the baseline at the top + the ascender, multiples below;
--   2. tab stops left, right, decimal, the default ones; alignment C R J; indents left, first line, hanging; breaks;
--   3. blocks: max(space_after, space_before), the gap dropped at the top of a page, keep_next chains, page breaks;
--   4. tables: shading, borders, the row = its top border + its tallest cell, header rows repeated, a row never split;
--   5. zones per page (first page different), PAGE / NUMPAGES and the double pass, a tall header pushes the body;
--   6. fonts: the D3 substitutes, the original first, a missing file, fsType refused; images; refusals;
--   7. codex-052: the gap in keep chains, header rows + row as one group, fields and zones measured per page, cell
--      borders on every side, 500 pages, a word of several runs;
--   8. codex-054: the closing border of every portion of a table, PAGE in a continuation, borders by grid segment;
--   9. codex-055: the repeated group counts one closing border (its boundary, accepted and refused).
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  c_png  CONSTANT BLOB := TO_BLOB(HEXTORAW(
    '89504E470D0A1A0A0000000D4948445200000001000000010802000000907753DE0000000C4944415408D763F8CFC000000301010018DD8DB00000000049454E44AE426082'));
  c_left CONSTANT NUMBER := 56.7;
  c_top  CONSTANT NUMBER := 56.7;
  c_asc  CONSTANT NUMBER := 1854 / 2048;                  -- Liberation Sans = Arial (hhea)
  c_line CONSTANT NUMBER := (1854 + 434 + 67) / 2048;
  l_pass PLS_INTEGER := 0;
  l_msg  VARCHAR2(4000);
  fonts  rad_pdf_pager.t_font_files;
  f      rad_pdf_ri.t_run_fmt;
  pf     rad_pdf_ri.t_para_fmt;
  cf     rad_pdf_ri.t_cell_fmt;
  q      rad_pdf_ri.t_ri;
  b      rad_pdf_ri.t_id;
  p      rad_pdf_ri.t_id;
  x      rad_pdf_ri.t_id;
  t      rad_pdf_ri.t_id;
  r      rad_pdf_ri.t_id;
  c      rad_pdf_ri.t_id;
  d      CLOB;
  l_doc  rad_pdf_types.t_doc_handle;
  l_fi   PLS_INTEGER;
  tabs   rad_pdf_ri.t_tab_list;

  PROCEDURE assert_ok(p_ok BOOLEAN, p_message VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_ok, FALSE) THEN RAISE_APPLICATION_ERROR(-20999, 'FAIL ' || p_message); END IF;
    l_pass := l_pass + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  ' || p_message || CASE WHEN l_msg IS NOT NULL THEN '  <' || l_msg || '>' END);
    l_msg := NULL;
  END;

  FUNCTION near(a NUMBER, e NUMBER, p_tol NUMBER DEFAULT 0.02) RETURN BOOLEAN IS
  BEGIN
    RETURN ABS(a - e) <= p_tol;
  END;

  FUNCTION num(p_s VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN TO_NUMBER(p_s, '99999990D99', 'NLS_NUMERIC_CHARACTERS=''.,''');
  END;

  -- the first line of the dump matching p_re (multi-line), its x / y / page
  FUNCTION ln(p_re VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN REGEXP_SUBSTR(d, p_re, 1, 1, 'm');
  END;
  FUNCTION xo(p_line VARCHAR2) RETURN NUMBER IS BEGIN RETURN num(REGEXP_SUBSTR(p_line, '[^ ]+', 1, 3)); END;
  FUNCTION yo(p_line VARCHAR2) RETURN NUMBER IS BEGIN RETURN num(REGEXP_SUBSTR(p_line, '[^ ]+', 1, 4)); END;
  FUNCTION pg(p_line VARCHAR2) RETURN NUMBER IS BEGIN RETURN TO_NUMBER(REGEXP_SUBSTR(p_line, '[^ ]+', 1, 1)); END;
  FUNCTION pages RETURN NUMBER IS BEGIN RETURN TO_NUMBER(REGEXP_SUBSTR(d, '^PAGES ([0-9]+)', 1, 1, 'm', 1)); END;

  -- the width of a text in Liberation Sans regular 10 (measured with the engine, as the paginator does)
  FUNCTION w(p_t VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN rad_pdf_fonts.text_width(p_t, l_fi, 10);
  END;

  -- an instance: A4, margins 56.7, header/footer distance 36, title_page as given; b = the body
  PROCEDURE start_i(p_title VARCHAR2 DEFAULT 'N') IS
  BEGIN
    q := rad_pdf_ri.new_instance;
    x := rad_pdf_ri.section(q, 595.3, 841.9, 'P', c_top, c_top, c_left, c_left, 36, 36, p_title);
    b := rad_pdf_ri.zone(q, 'body');
  END;

  -- a paragraph in the current format pf, holding one run (none when p_text is NULL)
  FUNCTION para(p_in rad_pdf_ri.t_id, p_text VARCHAR2) RETURN rad_pdf_ri.t_id IS
    l rad_pdf_ri.t_id;
  BEGIN
    l := rad_pdf_ri.paragraph(q, p_in, pf);
    IF p_text IS NOT NULL THEN x := rad_pdf_ri.run(q, l, p_text, f); END IF;
    RETURN l;
  END;

  PROCEDURE dump_it IS
  BEGIN
    rad_pdf_ri.seal(q);
    d := rad_pdf_pager.layout_dump(q, fonts);
  END;

  FUNCTION refused(p_code PLS_INTEGER, p_like VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    rad_pdf_ri.seal(q);
    d := rad_pdf_pager.layout_dump(q, fonts);
    RETURN FALSE;
  EXCEPTION WHEN OTHERS THEN
    l_msg := REGEXP_SUBSTR(SQLERRM, '\[[A-Z_]+\][^' || CHR(10) || ']*');
    RETURN SQLCODE = p_code AND l_msg LIKE p_like;
  END;

BEGIN
  SELECT family, variant, bytes BULK COLLECT INTO fonts FROM rad_pdf_test_font ORDER BY family, variant;
  assert_ok(fonts.COUNT = 4, 'the test fonts: Liberation Sans in four variants (tests/word/load_fonts.py)');
  l_doc := rad_pdf_doc.open_doc;                          -- the core only (runs on src/install_core.sql)
  FOR i IN 1 .. fonts.COUNT LOOP
    IF fonts(i).variant = 'R' THEN l_fi := rad_pdf_fonts.load_ttf(l_doc, fonts(i).bytes, p_encoding => 'CID', p_embed => TRUE); END IF;
  END LOOP;
  f.font := 'Arial'; f.size_pt := 10;

  -- 1. lines ------------------------------------------------------------------------------------
  start_i; p := para(b, 'Hello'); p := para(b, 'World'); dump_it;
  assert_ok(pages = 1 AND near(xo(ln('^1 T .* Hello ')), c_left) AND near(yo(ln('^1 T .* Hello ')), c_top + 10 * c_asc),
            'the first baseline at the top margin + the ascender of the font (9.05 pt at 10 pt)');
  assert_ok(near(yo(ln('^1 T .* World ')) - yo(ln('^1 T .* Hello ')), 10 * c_line),
            'a single line = (ascender - descender + line gap) / em = 11.5 pt at 10 pt (Word)');
  start_i; pf.line_mult := 1.15; p := para(b, 'Hello'); p := para(b, 'World'); pf.line_mult := 1; dump_it;
  assert_ok(near(yo(ln('^1 T .* Hello ')), c_top + 10 * c_asc) AND near(yo(ln('^1 T .* World ')) - yo(ln('^1 T .* Hello ')), 1.15 * 10 * c_line),
            'a multiple 1.15: the line is 13.22 pt, the extra BELOW the text (the first baseline unchanged)');

  -- 2. tabs, alignment, indents, breaks --------------------------------------------------------------
  tabs := rad_pdf_ri.t_tab_list(); tabs.EXTEND(3);
  tabs(1).pos := 100; tabs(1).kind := 'L'; tabs(2).pos := 300; tabs(2).kind := 'R'; tabs(3).pos := 450; tabs(3).kind := 'D';
  start_i;
  p := rad_pdf_ri.paragraph(q, b, pf, tabs);
  x := rad_pdf_ri.run(q, p, 'A', f); x := rad_pdf_ri.tab(q, p);
  x := rad_pdf_ri.run(q, p, 'Left', f); x := rad_pdf_ri.tab(q, p);
  x := rad_pdf_ri.run(q, p, 'Right', f); x := rad_pdf_ri.tab(q, p);
  x := rad_pdf_ri.run(q, p, '1.234,56', f);
  p := rad_pdf_ri.paragraph(q, b, pf);
  x := rad_pdf_ri.run(q, p, 'B', f); x := rad_pdf_ri.tab(q, p); x := rad_pdf_ri.run(q, p, 'next', f);
  dump_it;
  assert_ok(near(xo(ln('^1 T .* Left ')), c_left + 100), 'a left tab: the text starts at the stop (100 pt)');
  assert_ok(near(xo(ln('^1 T .* Right ')) + w('Right'), c_left + 300), 'a right tab: the text ends at the stop (300 pt)');
  assert_ok(near(xo(ln('^1 T .* 1\.234,56 ')) + w('1.234'), c_left + 450), 'a decimal tab: the decimal character (,) at the stop (450 pt)');
  assert_ok(near(xo(ln('^1 T .* next ')), c_left + 36), 'no stop: the default stops every 36 pt (720 twips)');
  start_i;
  pf.align := 'C'; p := para(b, 'Centre');
  pf.align := 'R'; p := para(b, 'Right');
  pf.align := 'J'; p := para(b, RPAD('word ', 400, 'word '));
  pf.align := 'L';
  dump_it;
  assert_ok(near(xo(ln('^1 T .* Centre ')), c_left + (481.9 - w('Centre')) / 2), 'centred');
  assert_ok(near(xo(ln('^1 T .* Right ')) + w('Right'), c_left + 481.9), 'right aligned');
  DECLARE
    l_y1 NUMBER := yo(ln('^1 T .* word '));
    l_last VARCHAR2(200);
    l_n  PLS_INTEGER := 0;
  BEGIN
    FOR i IN 1 .. REGEXP_COUNT(d, '^1 T [^ ]+ ' || REPLACE(TO_CHAR(l_y1, 'FM99990.99', 'NLS_NUMERIC_CHARACTERS=''.,'''), '.', '\.') || ' word ', 1, 'm') LOOP
      l_last := REGEXP_SUBSTR(d, '^1 T [^ ]+ ' || REPLACE(TO_CHAR(l_y1, 'FM99990.99', 'NLS_NUMERIC_CHARACTERS=''.,'''), '.', '\.') || ' word ', 1, i, 'm');
      l_n := i;
    END LOOP;
    assert_ok(l_n > 5 AND near(xo(l_last) + w('word'), c_left + 481.9, 0.05), 'justified: the first line''s last word ends at the right margin');
  END;
  start_i;
  pf.ind_left := 20; pf.ind_first := 10; p := para(b, RPAD('aaaa ', 600, 'aaaa '));
  pf.ind_left := 30; pf.ind_first := -30; p := para(b, 'Hanging' || ' ' || RPAD('bbbb ', 600, 'bbbb '));
  pf.ind_left := 0; pf.ind_first := 0; pf.ind_right := 0;
  dump_it;
  assert_ok(near(xo(ln('^1 T .* aaaa ')), c_left + 30)
            AND REGEXP_COUNT(d, '^1 T ' || REPLACE(TO_CHAR(c_left + 20, 'FM99990.99', 'NLS_NUMERIC_CHARACTERS=''.,'''), '.', '\.') || ' [^ ]+ aaaa ', 1, 'm') >= 2,
            'left indent 20 + first line 10: the first line at 30, the next lines at 20');
  assert_ok(near(xo(ln('^1 T .* Hanging ')), c_left) AND REGEXP_COUNT(d, '^1 T ' || REPLACE(TO_CHAR(c_left + 30, 'FM99990.99', 'NLS_NUMERIC_CHARACTERS=''.,'''), '.', '\.') || ' [^ ]+ bbbb ', 1, 'm') >= 2,
            'a hanging indent: the first line at 0, the next lines at 30');
  start_i;
  p := rad_pdf_ri.paragraph(q, b, pf);
  x := rad_pdf_ri.run(q, p, 'one', f); x := rad_pdf_ri.line_break(q, p); x := rad_pdf_ri.run(q, p, 'two', f);
  dump_it;
  assert_ok(near(yo(ln('^1 T .* two ')) - yo(ln('^1 T .* one ')), 10 * c_line) AND near(xo(ln('^1 T .* two ')), c_left),
            'a line break node starts a new line at the left');

  -- 3. blocks -------------------------------------------------------------------------------------------
  start_i;
  pf.space_after := 10; p := para(b, 'First'); pf.space_after := 0;
  pf.space_before := 12; p := para(b, 'Second'); pf.space_before := 0;
  p := rad_pdf_ri.paragraph(q, b, pf);                    -- an empty paragraph: one line
  p := para(b, 'Third');
  dump_it;
  assert_ok(near(yo(ln('^1 T .* Second ')) - yo(ln('^1 T .* First ')), 10 * c_line + 12),
            'between two paragraphs the larger of space_after (10) and space_before (12), not their sum (Word)');
  assert_ok(near(yo(ln('^1 T .* Third ')) - yo(ln('^1 T .* Second ')), 2 * 10 * c_line), 'an empty paragraph takes one line');
  start_i;
  p := para(b, 'Before');
  x := rad_pdf_ri.page_break(q, b);
  pf.space_before := 12; p := para(b, 'After'); pf.space_before := 0;
  dump_it;
  assert_ok(pages = 2 AND pg(ln('^[0-9]+ T .* After ')) = 2 AND near(yo(ln('^2 T .* After ')), c_top + 12 + 10 * c_asc),
            'a page break: page 2; after a MANUAL break the space_before stays');
  start_i;
  FOR i IN 1 .. 62 LOOP p := para(b, 'Filler ' || i); END LOOP;             -- 62 x 11.5 = 713 of 728.5 pt
  pf.space_after := 10; p := para(b, 'Last of page 1'); pf.space_after := 0;
  pf.space_before := 6; p := para(b, 'Top of page 2'); pf.space_before := 0;
  dump_it;
  assert_ok(pg(ln('^[0-9]+ T .* Top ')) = 2 AND near(yo(ln('^2 T .* Top ')), c_top + 10 * c_asc),
            'at the top of a page after an automatic break the gap is dropped (Word: page 3 of the quote)');
  start_i;
  FOR i IN 1 .. 61 LOOP p := para(b, 'Filler ' || i); END LOOP;     -- 27 pt left: Kept 1 + Kept 2 (23) fit, the chain (34.5) does not
  pf.keep_next := 'Y'; p := para(b, 'Kept 1'); p := para(b, 'Kept 2'); pf.keep_next := 'N';
  p := para(b, 'Next 1'); p := para(b, 'Next 2'); p := para(b, 'Next 3');
  dump_it;
  assert_ok(pg(ln('^[0-9]+ T .* Kept ')) = 2 AND pg(ln('^[0-9]+ T [^ ]+ [^ ]+ 61 \[')) = 1,          -- one dump line per word: '61' of Filler 61
            'keep_next: the chain (Kept 1, Kept 2, the first line of Next 1) moves to page 2 when it does not fit');
  start_i;
  pf.keep_next := 'Y';
  FOR i IN 1 .. 70 LOOP p := para(b, 'Chain ' || i); END LOOP;
  pf.keep_next := 'N'; p := para(b, 'End');
  assert_ok(refused(rad_pdf_pager.c_err_layout, '[PDF_LAYOUT] a keep-with-next chain of % pt is taller than the page'),
            'a keep_next chain taller than the page refused (96a section 8), never a loop');

  -- 4. tables -------------------------------------------------------------------------------------------
  start_i;
  t := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(100, 200), rad_pdf_ri.borders_all(rad_pdf_ri.border('SINGLE', 0.5, '999999')));
  r := rad_pdf_ri.row_(q, t, 'Y', 'Y');
  cf.mar_left := 5.4; cf.mar_right := 5.4; cf.shading := 'DCE6F0';
  c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'HeadA'); c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'HeadB');
  cf.shading := NULL;
  FOR i IN 1 .. 80 LOOP
    r := rad_pdf_ri.row_(q, t);
    c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'Row' || i); c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'Text' || i);
  END LOOP;
  dump_it;
  assert_ok(near(xo(ln('^1 T .* HeadA ')), c_left + 5.4) AND near(xo(ln('^1 T .* HeadB ')), c_left + 100 + 5.4),
            'cells at the grid (100 pt) plus the cell margin (5.4 pt)');
  assert_ok(near(yo(ln('^1 T .* HeadA ')), c_top + 0.5 + 10 * c_asc) AND near(yo(ln('^1 T .* Row1 ')) - yo(ln('^1 T .* HeadA ')), 0.5 + 10 * c_line),
            'a row = its top border (0.5) + its tallest cell (Word: 23.72 pt in the quote)');
  assert_ok(ln('^1 F [^ ]+ [^ ]+ 300x[^ ]+ #DCE6F0') IS NULL AND REGEXP_COUNT(d, '^1 F .* #DCE6F0', 1, 'm') = 2 AND REGEXP_COUNT(d, '^1 L ', 1, 'm') > 100,
            'the shading of each header cell and the borders drawn');
  assert_ok(pages = 2 AND ln('^2 T .* HeadA ') IS NOT NULL AND near(yo(ln('^2 T .* HeadA ')), c_top + 0.5 + 10 * c_asc)
            AND yo(ln('^2 T .* Row[0-9]+ ')) > yo(ln('^2 T .* HeadA ')), 'the header row repeated at the top of page 2');
  start_i;
  t := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(300), rad_pdf_ri.borders_all(rad_pdf_ri.border('SINGLE', 0.5, '999999')));
  r := rad_pdf_ri.row_(q, t); c := rad_pdf_ri.cell(q, r, cf); p := rad_pdf_ri.paragraph(q, c, pf);
  FOR i IN 1 .. 70 LOOP x := rad_pdf_ri.run(q, p, 'line ' || i, f); x := rad_pdf_ri.line_break(q, p); END LOOP;
  assert_ok(refused(rad_pdf_pager.c_err_layout, '[PDF_LAYOUT] a table row of % pt is taller than the page (rows are not split in v1)'),
            'a row taller than the page refused (rows are not split in v1)');

  -- 5. zones and fields ----------------------------------------------------------------------------------------
  start_i('Y');
  p := para(rad_pdf_ri.zone(q, 'header_first'), 'FirstHeader');
  p := para(rad_pdf_ri.zone(q, 'header_default'), 'OtherHeader');
  FOR z IN 1 .. 2 LOOP
    pf.align := 'R';
    p := rad_pdf_ri.paragraph(q, rad_pdf_ri.zone(q, CASE z WHEN 1 THEN 'footer_first' ELSE 'footer_default' END), pf);
    x := rad_pdf_ri.run(q, p, 'Pagina ', f); x := rad_pdf_ri.field(q, p, 'PAGE', f);
    x := rad_pdf_ri.run(q, p, ' di ', f); x := rad_pdf_ri.field(q, p, 'NUMPAGES', f);
    pf.align := 'L';
  END LOOP;
  p := para(b, 'BodyA'); x := rad_pdf_ri.page_break(q, b); p := para(b, 'BodyB');
  dump_it;
  assert_ok(ln('^1 T .* FirstHeader ') IS NOT NULL AND ln('^1 T .* OtherHeader ') IS NULL AND ln('^2 T .* OtherHeader ') IS NOT NULL,
            'title_page: the first-page header on page 1, the default one after');
  assert_ok(near(yo(ln('^1 T .* FirstHeader ')), 36 + 10 * c_asc), 'the header starts at its distance from the top (36 pt)');
  assert_ok(ln('^1 T .* 1 \[10\]') IS NOT NULL AND ln('^2 T .* 2 \[10\]') IS NOT NULL AND REGEXP_COUNT(d, '^[12] T .* 2 \[10\]', 1, 'm') = 3,
            'PAGE on each page, NUMPAGES = 2 on both');
  assert_ok(near(yo(ln('^1 T .* Pagina ')), 841.9 - 36 - 10 * c_line + 10 * c_asc), 'the footer ends at its distance from the bottom (36 pt)');
  start_i;
  FOR i IN 1 .. 11 LOOP p := para(b, 'Page ' || i); x := rad_pdf_ri.page_break(q, b); END LOOP;
  p := rad_pdf_ri.paragraph(q, b, pf);
  x := rad_pdf_ri.run(q, p, 'of ', f); x := rad_pdf_ri.field(q, p, 'NUMPAGES', f);
  dump_it;
  assert_ok(pages = 12 AND ln('^12 T .* 12 \[10\]') IS NOT NULL, 'NUMPAGES in the body: 12 after the double pass (two digits)');
  start_i;
  FOR i IN 1 .. 5 LOOP p := para(rad_pdf_ri.zone(q, 'header_default'), 'Headerline' || i); END LOOP;
  p := para(b, 'Pushed');
  dump_it;
  assert_ok(near(yo(ln('^1 T .* Pushed ')), 36 + 5 * 10 * c_line + 10 * c_asc),
            'a header taller than the top margin pushes the body down (36 + 5 lines)');

  -- 6. fonts, images, refusals -------------------------------------------------------------------------------------
  assert_ok(rad_pdf_pager.substitute('Arial') = 'Liberation Sans' AND rad_pdf_pager.substitute('calibri') = 'Carlito'
            AND rad_pdf_pager.substitute('Cambria') = 'Caladea' AND rad_pdf_pager.substitute('Times New Roman') = 'Liberation Serif'
            AND rad_pdf_pager.substitute('Courier New') = 'Liberation Mono' AND rad_pdf_pager.substitute('Verdana') = 'Verdana',
            'the D3 substitutes (96a section 9)');
  start_i; f.font := 'Verdana'; p := para(b, 'x'); f.font := 'Arial';
  assert_ok(refused(rad_pdf_pager.c_err_font, '[PDF_FONT] no font file for Verdana (Verdana) variant R'), 'a font with no file refused');
  DECLARE
    l_bad  rad_pdf_pager.t_font_files := fonts;
    l_os2  PLS_INTEGER;
    l_b    BLOB;
  BEGIN
    FOR i IN 1 .. l_bad.COUNT LOOP
      IF l_bad(i).variant = 'R' THEN
        DBMS_LOB.CREATETEMPORARY(l_b, TRUE);
        DBMS_LOB.COPY(l_b, l_bad(i).bytes, DBMS_LOB.GETLENGTH(l_bad(i).bytes));
        FOR k IN 0 .. TO_NUMBER(RAWTOHEX(DBMS_LOB.SUBSTR(l_b, 2, 5)), 'XXXX') - 1 LOOP
          IF UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_b, 4, 13 + k * 16)) = 'OS/2' THEN
            l_os2 := TO_NUMBER(RAWTOHEX(DBMS_LOB.SUBSTR(l_b, 4, 13 + k * 16 + 8)), 'XXXXXXXX') + 1;
          END IF;
        END LOOP;
        DBMS_LOB.WRITE(l_b, 2, l_os2 + 8, HEXTORAW('0002'));          -- fsType = Restricted License
        l_bad(i).bytes := l_b;
      END IF;
    END LOOP;
    start_i; p := para(b, 'x'); rad_pdf_ri.seal(q);
    BEGIN
      d := rad_pdf_pager.layout_dump(q, l_bad);
      assert_ok(FALSE, 'fsType');
    EXCEPTION WHEN OTHERS THEN
      l_msg := REGEXP_SUBSTR(SQLERRM, '\[[A-Z_]+\][^' || CHR(10) || ']*');
      assert_ok(SQLCODE = rad_pdf_pager.c_err_font AND l_msg LIKE '%fsType forbids embedding', 'a font whose fsType forbids embedding refused');
    END;
    DBMS_LOB.WRITE(l_b, 2, l_os2 + 8, HEXTORAW('0100'));              -- fsType = no subsetting
    FOR i IN 1 .. l_bad.COUNT LOOP IF l_bad(i).variant = 'R' THEN l_bad(i).bytes := l_b; END IF; END LOOP;   -- a copy: assign again
    BEGIN
      d := rad_pdf_pager.layout_dump(q, l_bad);
      assert_ok(FALSE, 'fsType');
    EXCEPTION WHEN OTHERS THEN
      l_msg := REGEXP_SUBSTR(SQLERRM, '\[[A-Z_]+\][^' || CHR(10) || ']*');
      assert_ok(SQLCODE = rad_pdf_pager.c_err_font AND l_msg LIKE '%fsType forbids subsetting (not in v1)', 'a font whose fsType forbids subsetting refused');
    END;
    DBMS_LOB.FREETEMPORARY(l_b);
    l_bad := fonts;
    FOR i IN 1 .. l_bad.COUNT LOOP l_bad(i).family := 'Arial'; END LOOP;             -- an original, uploaded
    start_i; p := para(b, 'Original'); rad_pdf_ri.seal(q);
    d := rad_pdf_pager.layout_dump(q, l_bad);
    assert_ok(ln('^1 T .* Original ') IS NOT NULL, 'the original font (a file named Arial) is used before its substitute');
  END;
  start_i;
  x := rad_pdf_ri.add_image(q, c_png, 'PNG', 1, 1);
  p := rad_pdf_ri.paragraph(q, b, pf);
  x := rad_pdf_ri.run(q, p, 'Logo ', f); x := rad_pdf_ri.image(q, p, 1, 40, 20);
  x := rad_pdf_ri.fixed_box(q, b, 1, 100, 50);
  f.underline := 'Y'; p := para(b, 'Underlined'); f.underline := 'N';
  dump_it;
  assert_ok(ln('^1 I [^ ]+ [^ ]+ 40x20 res 1') IS NOT NULL AND ln('^1 I [^ ]+ [^ ]+ 100x50 res 1') IS NOT NULL,
            'an inline image and a fixed box drawn with their sizes');
  assert_ok(near(yo(ln('^1 I [^ ]+ [^ ]+ 40x20 ')) + 20, yo(ln('^1 T .* Logo '))), 'an inline image stands on the baseline');
  assert_ok(ln('^1 L .* 0.5 #000000') IS NOT NULL, 'an underline drawn under the run (0.05 x size)');
  start_i; p := para(b, 'x'); rad_pdf_ri.seal(q);
  DECLARE l_pdf BLOB;
  BEGIN
    l_pdf := rad_pdf_pager.render(q, fonts);
    assert_ok(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/FontFile2')) > 0 AND DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('LiberationSans')) > 0,
              'render: a PDF with Liberation Sans embedded (FontFile2, subset)');
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;
  q := rad_pdf_ri.new_ri;
  x := rad_pdf_ri.section(q, 595.3, 841.9, 'P', c_top, c_top, c_left, c_left, 36, 36, 'N');
  p := para(rad_pdf_ri.zone(q, 'body'), 'template');
  assert_ok(refused(rad_pdf_pager.c_err_layout, '[PDF_LAYOUT] the paginator draws an instance%'), 'a template (not an instance) refused');

  -- 7. codex-052 ------------------------------------------------------------------------------------------------------------
  -- R1: the leading gap counts in the chain; a first page taller than the others
  start_i;
  FOR i IN 1 .. 61 LOOP p := para(b, 'Filler'); END LOOP;            -- 27 pt left
  pf.keep_next := 'Y'; pf.space_before := 10; p := para(b, 'Kept'); pf.space_before := 0; pf.keep_next := 'N';
  p := para(b, 'Next');
  dump_it;
  assert_ok(pg(ln('^[0-9]+ T .* Kept ')) = 2 AND pg(ln('^[0-9]+ T .* Next ')) = 2,
            'R1: the gap of the first block counts (10 + 11.5 + 11.5 > 27 pt): the chain moves whole, never split');
  start_i('Y');
  FOR i IN 1 .. 30 LOOP p := para(rad_pdf_ri.zone(q, 'header_default'), 'Tall'); END LOOP;   -- page 2: a body of 404 pt
  pf.keep_next := 'Y';
  FOR i IN 1 .. 50 LOOP p := para(b, 'Chain'); END LOOP;              -- 575 pt: fits page 1 (728.5), not page 2
  pf.keep_next := 'N';
  p := para(b, 'End');
  dump_it;
  assert_ok(pages = 1, 'R1: a chain that fits the first page (taller than the others) is not refused');
  -- R2: header rows and a row as one group; the bottom border reserved; nothing beyond the body
  start_i;
  t := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(300), rad_pdf_ri.borders_all(rad_pdf_ri.border('SINGLE', 0.5, '999999')));
  r := rad_pdf_ri.row_(q, t, 'Y'); c := rad_pdf_ri.cell(q, r, cf); p := rad_pdf_ri.paragraph(q, c, pf);
  FOR i IN 1 .. 60 LOOP x := rad_pdf_ri.run(q, p, 'H', f); x := rad_pdf_ri.line_break(q, p); END LOOP;   -- 690 pt
  r := rad_pdf_ri.row_(q, t); c := rad_pdf_ri.cell(q, r, cf); p := rad_pdf_ri.paragraph(q, c, pf);
  FOR i IN 1 .. 4 LOOP x := rad_pdf_ri.run(q, p, 'R', f); x := rad_pdf_ri.line_break(q, p); END LOOP;   -- 58 pt
  assert_ok(refused(rad_pdf_pager.c_err_layout, '[PDF_LAYOUT] % taller than the page%'),
            'R2: the header row and the first row together taller than an empty page refused');
  start_i;
  FOR i IN 1 .. 60 LOOP p := para(b, 'Filler'); END LOOP;            -- 38.5 pt left: the header rows (24) fit, with the row (47.5) not
  t := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(300), rad_pdf_ri.borders_all(rad_pdf_ri.border('SINGLE', 0.5, '999999')));
  FOR h IN 1 .. 2 LOOP
    r := rad_pdf_ri.row_(q, t, 'Y'); c := rad_pdf_ri.cell(q, r, cf); p := para(c, CASE h WHEN 1 THEN 'HeadOne' ELSE 'HeadTwo' END);
  END LOOP;
  FOR i IN 1 .. 120 LOOP
    r := rad_pdf_ri.row_(q, t); c := rad_pdf_ri.cell(q, r, cf); p := rad_pdf_ri.paragraph(q, c, pf);
    x := rad_pdf_ri.run(q, p, 'Body', f); x := rad_pdf_ri.line_break(q, p); x := rad_pdf_ri.run(q, p, 'Body', f);
  END LOOP;
  dump_it;
  assert_ok(pg(ln('^[0-9]+ T .* HeadOne ')) = 2 AND pg(ln('^[0-9]+ T .* HeadTwo ')) = 2,
            'R2: two header rows that fit without their first row move with it (never left alone at a page bottom)');
  DECLARE
    l_bad PLS_INTEGER := 0;
    l_line VARCHAR2(4000);
  BEGIN
    FOR i IN 1 .. REGEXP_COUNT(d, '^[0-9]+ [TL] ', 1, 'm') LOOP
      l_line := REGEXP_SUBSTR(d, '^[0-9]+ [TL] [^' || CHR(10) || ']*', 1, i, 'm');
      IF yo(l_line) > 841.9 - c_top + 0.01 OR (l_line LIKE '% L %' AND num(REGEXP_SUBSTR(l_line, '[^ ]+', 1, 6)) > 841.9 - c_top + 0.01) THEN
        l_bad := l_bad + 1;
      END IF;
    END LOOP;
    l_msg := 'beyond the body: ' || l_bad || ', pages ' || pages || ', header rows on ' || REGEXP_COUNT(d, '^[0-9]+ T .* HeadTwo ', 1, 'm');
    assert_ok(l_bad = 0 AND REGEXP_COUNT(d, '^[0-9]+ T .* HeadTwo ', 1, 'm') = pages - 1,       -- page 1: the fillers only
              'R2: every page of the table repeats both header rows; no text nor border beyond the body (the bottom border reserved)');
  END;
  -- R3: fields measured on their page; a zone that grows with the page number
  start_i;
  pf.align := 'R'; p := rad_pdf_ri.paragraph(q, b, pf); x := rad_pdf_ri.field(q, p, 'PAGE', f);
  pf.align := 'C'; p := rad_pdf_ri.paragraph(q, b, pf); x := rad_pdf_ri.field(q, p, 'PAGE', f); pf.align := 'L';
  FOR i IN 1 .. 11 LOOP x := rad_pdf_ri.page_break(q, b); p := para(b, 'More'); END LOOP;
  dump_it;
  assert_ok(pages = 12 AND near(xo(ln('^1 T [^ ]+ [^ ]+ 1 \[')) + w('1'), c_left + 481.9),
            'R3: PAGE right aligned on page 1 of 12: placed as "1", not as "12"');
  assert_ok(near(xo(REGEXP_SUBSTR(d, '^1 T [^ ]+ [^ ]+ 1 \[[^' || CHR(10) || ']*', 1, 2, 'm')), c_left + (481.9 - w('1')) / 2),
            'R3: PAGE centred on page 1 of 12');
  start_i;
  pf.ind_right := 481.9 - w('Pagina 9') - 0.5;
  p := rad_pdf_ri.paragraph(q, rad_pdf_ri.zone(q, 'header_default'), pf);
  x := rad_pdf_ri.run(q, p, 'Pagina ', f); x := rad_pdf_ri.field(q, p, 'PAGE', f);
  pf.ind_right := 0;
  p := para(b, 'Top');
  FOR i IN 1 .. 10 LOOP x := rad_pdf_ri.page_break(q, b); p := para(b, 'Top'); END LOOP;
  dump_it;
  assert_ok(near(yo(ln('^9 T .* Top ')), c_top + 10 * c_asc) AND near(yo(ln('^10 T .* Top ')), 36 + 2 * 10 * c_line + 10 * c_asc),
            'R3: a header that wraps from page 10 ("Pagina 10" on two lines) pushes the body of that page, measured per page');
  DECLARE
    l_s VARCHAR2(4000);
  BEGIN
    WHILE w(l_s || 'i') + w(' 9') <= 481.9 LOOP l_s := l_s || 'i'; END LOOP;      -- "iii..i 9" fits, "iii..i 12" does not
    start_i;
    p := rad_pdf_ri.paragraph(q, b, pf);
    x := rad_pdf_ri.run(q, p, l_s || ' ', f); x := rad_pdf_ri.field(q, p, 'NUMPAGES', f);
    FOR i IN 1 .. 11 LOOP x := rad_pdf_ri.page_break(q, b); p := para(b, 'More'); END LOOP;
    dump_it;
    assert_ok(yo(ln('^1 T [^ ]+ [^ ]+ 12 \[')) > yo(ln('^1 T .* i+ \[')),
              'R3: NUMPAGES measured with the final count: "12" wraps to the next line where "9" would have fit');
  END;
  -- R4: the borders of the cells win on every side
  start_i;
  t := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(100, 200), cf.borders);                 -- a table without borders
  r := rad_pdf_ri.row_(q, t);
  cf.borders.rgt := rad_pdf_ri.border('SINGLE', 1.5, 'FF0000'); cf.borders.top := rad_pdf_ri.border('SINGLE', 3, '0000FF');
  c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'Left');
  cf.borders := NULL; cf.borders.bottom := rad_pdf_ri.border('SINGLE', 2, '00FF00');
  c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'Right');
  cf.borders := NULL;
  dump_it;
  assert_ok(ln('^1 L 156\.7 [^ ]+ 156\.7 [^ ]+ 1\.5 #FF0000') IS NOT NULL, 'R4: the right border of the left cell drawn on the inner divider');
  assert_ok(ln('^1 L 156\.7 [^ ]+ 356\.7 [^ ]+ 2 #00FF00') IS NOT NULL AND ln('^1 L 56\.7 7[0-9.]+ 156\.7 ') IS NULL,          -- no bottom under the left cell
            'R4: the bottom of the last row from the cells (the right one only: the table has none)');
  assert_ok(ln('^1 L 56\.7 [^ ]+ 156\.7 [^ ]+ 3 #0000FF') IS NOT NULL AND near(yo(ln('^1 T .* Left ')), c_top + 3 + 10 * c_asc),
            'R4: a cell top of 3 pt drawn and counted in the row height');
  start_i;
  t := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(100, 200), rad_pdf_ri.borders_all(rad_pdf_ri.border('SINGLE', 0.5, '999999')));
  r := rad_pdf_ri.row_(q, t);
  cf.borders.rgt := rad_pdf_ri.border('NONE'); c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'A');
  cf.borders := NULL; cf.borders.lft := rad_pdf_ri.border('NONE'); c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'B');
  cf.borders := NULL;
  dump_it;
  assert_ok(ln('^1 L 156\.7 [^ ]+ 156\.7 ') IS NULL AND ln('^1 L 56\.7 [^ ]+ 56\.7 ') IS NOT NULL,
            'R4: NONE set by both cells removes the inner divider of a bordered table; the outer edges stay');
  -- R5: 500 pages
  start_i;
  FOR i IN 1 .. 499 LOOP x := rad_pdf_ri.page_break(q, b); END LOOP;
  p := para(b, 'Last');
  dump_it;
  assert_ok(pages = 500, 'R5: 500 pages accepted');
  start_i;
  FOR i IN 1 .. 500 LOOP x := rad_pdf_ri.page_break(q, b); END LOOP;
  assert_ok(refused(rad_pdf_pager.c_err_budget, '[PDF_BUDGET] the document exceeds 500 pages'), 'R5: 501 pages by manual breaks refused');
  start_i;
  pf.space_after := 720;                                              -- 11.5 + 720 + 11.5 > 728.5: one paragraph a page
  FOR i IN 1 .. 501 LOOP p := para(b, 'Page'); END LOOP;
  pf.space_after := 0;
  assert_ok(refused(rad_pdf_pager.c_err_budget, '[PDF_BUDGET] the document exceeds 500 pages'), 'R5: 501 pages by automatic breaks refused');
  start_i; p := para(b, 'After'); dump_it;
  assert_ok(pages = 1 AND ln('^1 T .* After ') IS NOT NULL, 'R5: a valid layout in the same session after the refusals');
  -- R6: a word of several runs moves whole
  DECLARE
    l_s VARCHAR2(4000);
    fb  rad_pdf_ri.t_run_fmt := f;
  BEGIN
    WHILE w(l_s) + w(' Hello') <= 481.9 LOOP l_s := l_s || 'i'; END LOOP;          -- "Hello" does not fit, "Hel" does
    start_i;
    p := rad_pdf_ri.paragraph(q, b, pf);
    x := rad_pdf_ri.run(q, p, l_s || ' Hel', f); x := rad_pdf_ri.run(q, p, 'lo', f);
    p := rad_pdf_ri.paragraph(q, b, pf);
    x := rad_pdf_ri.run(q, p, l_s || ' Hello', f);
    fb.bold := 'Y';
    p := rad_pdf_ri.paragraph(q, b, pf);
    x := rad_pdf_ri.run(q, p, l_s || ' Hel', f); x := rad_pdf_ri.run(q, p, 'lo', fb);
    dump_it;
    assert_ok(near(xo(ln('^1 T .* Hel ')), c_left) AND near(xo(ln('^1 T .* lo ')), c_left + w('Hel'))
              AND near(yo(ln('^1 T .* lo ')), yo(ln('^1 T .* Hel '))),
              'R6: "Hel"+"lo" in two runs moves whole to the next line, as one word');
    assert_ok(near(xo(ln('^1 T .* Hello ')), c_left) AND near(yo(ln('^1 T .* Hello ')) - yo(ln('^1 T .* Hel ')), 2 * 10 * c_line),
              'R6: the same as the single run "Hello"');
    assert_ok(near(yo(REGEXP_SUBSTR(d, '^1 T [^ ]+ [^ ]+ lo [^' || CHR(10) || ']*', 1, 2, 'm')),
                   yo(REGEXP_SUBSTR(d, '^1 T [^ ]+ [^ ]+ Hel [^' || CHR(10) || ']*', 1, 2, 'm'))),
              'R6: and with a bold second half');
  END;

  -- 8. codex-054 ------------------------------------------------------------------------------------------------------------
  -- R2: the closing border of every portion of a table reserved: thick borders, the table shifted 0.5 pt at a time over a
  -- whole row, with and without repeated header rows: no line reaches beyond the body (its extent, not its centre line)
  DECLARE
    l_worst NUMBER := 0;
    l_line  VARCHAR2(4000);
    l_ext   NUMBER;
  BEGIN
    FOR hdr IN 0 .. 1 LOOP
      FOR k IN 0 .. 27 LOOP
        start_i;
        pf.space_before := k * 0.5; p := para(b, 'Shift'); pf.space_before := 0;
        FOR i IN 1 .. 55 LOOP p := para(b, 'Filler'); END LOOP;
        t := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(300), rad_pdf_ri.borders_all(rad_pdf_ri.border('SINGLE', 2, '000000')));
        IF hdr = 1 THEN r := rad_pdf_ri.row_(q, t, 'Y'); c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'Head'); END IF;
        FOR i IN 1 .. 12 LOOP r := rad_pdf_ri.row_(q, t); c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'Row'); END LOOP;
        dump_it;
        FOR i IN 1 .. REGEXP_COUNT(d, '^[0-9]+ L ', 1, 'm') LOOP
          l_line := REGEXP_SUBSTR(d, '^[0-9]+ L [^' || CHR(10) || ']*', 1, i, 'm');
          l_ext := GREATEST(yo(l_line), num(REGEXP_SUBSTR(l_line, '[^ ]+', 1, 6)))
                   + CASE WHEN yo(l_line) = num(REGEXP_SUBSTR(l_line, '[^ ]+', 1, 6)) THEN num(REGEXP_SUBSTR(l_line, '[^ ]+', 1, 7)) / 2 ELSE 0 END;
          l_worst := GREATEST(l_worst, l_ext - (841.9 - c_top));
        END LOOP;
      END LOOP;
    END LOOP;
    l_msg := 'the worst extent beyond the body: ' || ROUND(l_worst, 3) || ' pt';
    assert_ok(l_worst <= 0.001, 'R2: 56 layouts (shifted by 0.5 pt, with and without header rows): no border beyond the body');
  END;
  -- R3: PAGE in the continuation of a paragraph split from page 9 to page 10
  FOR v IN 1 .. 2 LOOP
    start_i;
    FOR i IN 1 .. 8 LOOP x := rad_pdf_ri.page_break(q, b); END LOOP;
    FOR i IN 1 .. 62 LOOP p := para(b, 'Filler'); END LOOP;              -- 15.5 pt left on page 9: one line
    pf.align := CASE v WHEN 1 THEN 'R' ELSE 'C' END;
    p := rad_pdf_ri.paragraph(q, b, pf);
    x := rad_pdf_ri.run(q, p, 'Start', f); x := rad_pdf_ri.line_break(q, p);
    x := rad_pdf_ri.run(q, p, 'Pagina ', f); x := rad_pdf_ri.field(q, p, 'PAGE', f);
    pf.align := 'L';
    dump_it;
    assert_ok(pg(ln('^[0-9]+ T .* Start ')) = 9 AND ln('^10 T [^ ]+ [^ ]+ 10 \[') IS NOT NULL
              AND CASE v WHEN 1 THEN near(xo(ln('^10 T [^ ]+ [^ ]+ 10 \[')) + w('10'), c_left + 481.9)
                         ELSE near(xo(ln('^10 T .* Pagina ')), c_left + (481.9 - w('Pagina 10')) / 2) END,
              'R3: PAGE in the continuation on page 10 measured as "10" (' || CASE v WHEN 1 THEN 'right aligned' ELSE 'centred' END || ')');
  END LOOP;
  DECLARE
    l_s VARCHAR2(4000);
  BEGIN
    WHILE w(l_s || 'i') + w(' 9') <= 481.9 LOOP l_s := l_s || 'i'; END LOOP;   -- "ii..i 9" fits, "ii..i 10" does not
    start_i;
    FOR i IN 1 .. 8 LOOP x := rad_pdf_ri.page_break(q, b); END LOOP;
    FOR i IN 1 .. 62 LOOP p := para(b, 'Filler'); END LOOP;
    p := rad_pdf_ri.paragraph(q, b, pf);
    x := rad_pdf_ri.run(q, p, 'Start', f); x := rad_pdf_ri.line_break(q, p);
    x := rad_pdf_ri.run(q, p, l_s || ' ', f); x := rad_pdf_ri.field(q, p, 'PAGE', f);
    dump_it;
    assert_ok(yo(ln('^10 T [^ ]+ [^ ]+ 10 \[')) > yo(ln('^10 T .* i+ \[')),
              'R3: near a wrap, the continuation''s "10" goes to its own line where "9" would have fit');
  END;
  -- R4: the borders of rows whose spans differ, segment by segment
  FOR v IN 1 .. 3 LOOP
    start_i;
    t := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(100, 200), cf.borders);              -- a table without borders
    r := rad_pdf_ri.row_(q, t);
    IF v = 2 THEN cf.borders.bottom := rad_pdf_ri.border('SINGLE', 2, '0000FF'); END IF;
    c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'A');
    cf.borders := NULL;
    IF v IN (1, 3) THEN cf.borders.bottom := rad_pdf_ri.border('SINGLE', 2, '00FF00'); END IF;
    c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'B');
    cf.borders := NULL;
    r := rad_pdf_ri.row_(q, t);
    IF v = 3 THEN cf.borders.top := rad_pdf_ri.border('SINGLE', 1, 'FF0000'); END IF;
    cf.grid_span := 2; c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'Span'); cf.grid_span := 1;
    cf.borders := NULL;
    dump_it;
    IF v = 1 THEN
      assert_ok(ln('^1 L 156\.7 [^ ]+ 356\.7 [^ ]+ 2 #00FF00') IS NOT NULL AND ln('^1 L 56\.7 [^ ]+ 156\.7 [^ ]+ [^ ]+ #') IS NULL,
                'R4: the bottom of the upper right cell drawn over the right segment only, on a row whose cell spans both');
    ELSIF v = 2 THEN
      assert_ok(ln('^1 L 56\.7 [^ ]+ 156\.7 [^ ]+ 2 #0000FF') IS NOT NULL AND ln('^1 L 156\.7 [^ ]+ 356\.7 [^ ]+ [^ ]+ #') IS NULL,
                'R4: the inverse: the upper left cell''s bottom not stretched over the right segment');
    ELSE
      assert_ok(ln('^1 L 56\.7 [^ ]+ 156\.7 [^ ]+ 1 #FF0000') IS NOT NULL AND ln('^1 L 156\.7 [^ ]+ 356\.7 [^ ]+ 2 #00FF00') IS NOT NULL
                AND near(yo(ln('^1 T .* Span ')) - yo(ln('^1 T .* A ')), 10 * c_line + 2),
                'R4: an explicit top (1 red) against an upper bottom (2 green): each segment resolved, the row as high as its widest');
    END IF;
  END LOOP;

  -- 9. codex-055: the repeated group (header rows + a row) counts ONE closing border
  FOR v IN 1 .. 2 LOOP
    start_i;
    t := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(300), rad_pdf_ri.borders_all(rad_pdf_ri.border('SINGLE', 2, '000000')));
    r := rad_pdf_ri.row_(q, t, 'Y'); c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'Head');                -- 13.499 pt
    r := rad_pdf_ri.row_(q, t); c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'Short');
    cf.mar_top := 698.501953125 + CASE v WHEN 1 THEN 0 ELSE 2 END;                                       -- 712.001 pt (+2)
    r := rad_pdf_ri.row_(q, t); c := rad_pdf_ri.cell(q, r, cf); p := para(c, 'Tall');
    cf.mar_top := 0;
    IF v = 1 THEN
      dump_it;
      assert_ok(pages = 2 AND pg(ln('^[0-9]+ T .* Tall ')) = 2 AND ln('^2 T .* Head ') IS NOT NULL,
                'R2: header + a row + one closing border = 727.5 pt on a body of 728.5: accepted (codex-055 boundary)');
    ELSE
      assert_ok(refused(rad_pdf_pager.c_err_layout, '[PDF_LAYOUT] the header rows and a table row of 729.5 pt are taller than the page'),
                'R2: the same 2 pt taller (729.5 pt): refused');
    END IF;
  END LOOP;

  rad_pdf_doc.close_doc(l_doc);
  DBMS_OUTPUT.PUT_LINE('Phase 25 pager: ' || l_pass || ' passed, 0 failed.');
END;
/
