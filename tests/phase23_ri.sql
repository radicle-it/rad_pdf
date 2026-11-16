-- phase23_ri.sql - the intermediate representation of a template (rad_pdf_ri; middleware-docs 96a §1b.1, step B1)
-- Run from repo root in SQL*Plus after src/install.sql.
--   1. an RI built by code with EVERY node kind, sealed; reading (kids, node_count, fonts);
--   2. the three placements of the regions accepted (inline_region in a paragraph, block_region in a zone and in a
--      cell, row_region in a table) and every incompatible placement refused with [PDF_RI];
--   3. the invariants at seal refused with [PDF_RI]: grid spans, header rows, empty containers, scopes no loop opens;
--      a sealed RI is immutable;
--   4. serialization: to_json → from_json → to_json identical, image bytes included; a text breaking an invariant, a
--      wrong ri_version or an image whose hash does not match its bytes refused;
--   5. two RIs built interleaved stay independent (a value, not package state).
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
  -- a 1x1 red PNG
  c_png CONSTANT BLOB := TO_BLOB(HEXTORAW(
    '89504E470D0A1A0A0000000D4948445200000001000000010802000000907753DE0000000C4944415408D763F8CFC000000301010018DD8DB00000000049454E44AE426082'));
  l_pass PLS_INTEGER := 0;
  ri     rad_pdf_ri.t_ri;
  ri2    rad_pdf_ri.t_ri;
  r3     rad_pdf_ri.t_ri;
  f      rad_pdf_ri.t_run_fmt;
  fb     rad_pdf_ri.t_run_fmt;
  pf     rad_pdf_ri.t_para_fmt;
  cf     rad_pdf_ri.t_cell_fmt;
  bd     rad_pdf_ri.t_borders;
  tabs   rad_pdf_ri.t_tab_list := rad_pdf_ri.t_tab_list();
  l_sec  rad_pdf_ri.t_id;
  body   rad_pdf_ri.t_id;
  p      rad_pdf_ri.t_id;
  t      rad_pdf_ri.t_id;
  r      rad_pdf_ri.t_id;
  c      rad_pdf_ri.t_id;
  rr     rad_pdf_ri.t_id;
  br     rad_pdf_ri.t_id;
  ir     rad_pdf_ri.t_id;
  img    rad_pdf_ri.t_id;
  x      rad_pdf_ri.t_id;
  j1     CLOB;
  j2     CLOB;
  fr     rad_pdf_ri.t_font_reqs;
  l_msg  VARCHAR2(4000);

  PROCEDURE assert_ok(p_ok BOOLEAN, p_message VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_ok, FALSE) THEN RAISE_APPLICATION_ERROR(-20999, 'FAIL ' || p_message); END IF;
    l_pass := l_pass + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  ' || p_message || CASE WHEN l_msg IS NOT NULL THEN '  <' || l_msg || '>' END);
    l_msg := NULL;
  END;

  -- a document with its section; the body zone
  FUNCTION base(p_ri OUT rad_pdf_ri.t_ri) RETURN rad_pdf_ri.t_id IS
    l_s rad_pdf_ri.t_id;
  BEGIN
    p_ri := rad_pdf_ri.new_ri;
    l_s := rad_pdf_ri.section(p_ri, 595.3, 841.9, 'P', 56.7, 70.9, 56.7, 56.7, 35.4, 35.4, 'Y');
    RETURN rad_pdf_ri.zone(p_ri, 'body');
  END;

  FUNCTION one_cell RETURN rad_pdf_ri.t_cell_fmt IS
    l rad_pdf_ri.t_cell_fmt;
  BEGIN
    RETURN l;
  END;

  -- the refusal cases: each on its own fresh RI; TRUE when [PDF_RI] was raised
  FUNCTION refused(p_case IN PLS_INTEGER) RETURN BOOLEAN IS
    q   rad_pdf_ri.t_ri;
    b   rad_pdf_ri.t_id;
    pp  rad_pdf_ri.t_id;
    tt  rad_pdf_ri.t_id;
    rw  rad_pdf_ri.t_id;
    cc  rad_pdf_ri.t_id;
    rg  rad_pdf_ri.t_id;
    y   rad_pdf_ri.t_id;
    g2  rad_pdf_ri.t_num_list := rad_pdf_ri.t_num_list(100, 200);
    cf2 rad_pdf_ri.t_cell_fmt;
  BEGIN
    b := base(q);
    CASE p_case
      -- placements
      WHEN 1  THEN y := rad_pdf_ri.inline_region(q, b, 'SECTION', NULL, 'has_discount');          -- inline_region in a zone
      WHEN 2  THEN pp := rad_pdf_ri.paragraph(q, b, pf);
                   y := rad_pdf_ri.block_region(q, pp, 'SECTION', NULL, 'has_discount');         -- block_region in a paragraph
      WHEN 3  THEN y := rad_pdf_ri.row_region(q, b, 'LOOP', NULL, 'lines');                      -- row_region in a zone
      WHEN 4  THEN tt := rad_pdf_ri.table_(q, b, g2, bd);
                   rg := rad_pdf_ri.row_region(q, tt, 'LOOP', NULL, 'lines');
                   y := rad_pdf_ri.row_region(q, rg, 'LOOP', 'lines', 'lines[].sub');            -- row_region in a row_region
      WHEN 5  THEN y := rad_pdf_ri.row_(q, b);                                                   -- row in a zone
      WHEN 6  THEN tt := rad_pdf_ri.table_(q, b, g2, bd);
                   y := rad_pdf_ri.cell(q, tt, cf2);                                              -- cell in a table
      WHEN 7  THEN y := rad_pdf_ri.run(q, b, 'x', f);                                            -- run in a zone
      WHEN 8  THEN pp := rad_pdf_ri.paragraph(q, b, pf);
                   y := rad_pdf_ri.paragraph(q, pp, pf);                                          -- paragraph in a paragraph
      WHEN 9  THEN tt := rad_pdf_ri.table_(q, b, g2, bd); rw := rad_pdf_ri.row_(q, tt);
                   cc := rad_pdf_ri.cell(q, rw, cf2);
                   y := rad_pdf_ri.table_(q, cc, g2, bd);                                         -- nested table
      WHEN 10 THEN tt := rad_pdf_ri.table_(q, b, g2, bd);
                   rg := rad_pdf_ri.row_region(q, tt, 'LOOP', NULL, 'lines');
                   rw := rad_pdf_ri.row_(q, rg); y := rad_pdf_ri.row_(q, rg);                     -- two rows in a row_region
      WHEN 11 THEN tt := rad_pdf_ri.table_(q, b, g2, bd);
                   rg := rad_pdf_ri.row_region(q, tt, 'LOOP', NULL, 'lines');
                   y := rad_pdf_ri.row_(q, rg, 'Y');                                              -- a header row in a row_region
      WHEN 12 THEN pp := rad_pdf_ri.paragraph(q, b, pf); y := rad_pdf_ri.field(q, pp, 'DATE', f); -- a field not PAGE/NUMPAGES
      WHEN 13 THEN pp := rad_pdf_ri.paragraph(q, b, pf);
                   y := rad_pdf_ri.tag(q, pp, 'EXPR', NULL, 'quote.no', f);                      -- a tag op outside v1
      WHEN 14 THEN y := rad_pdf_ri.block_region(q, b, 'REPEAT', NULL, 'lines');                  -- a region kind outside v1
      WHEN 15 THEN pp := rad_pdf_ri.paragraph(q, b, pf);
                   y := rad_pdf_ri.tag(q, pp, 'FIELD', 'lines', 'quote.no', f);                  -- a path outside its scope
      WHEN 16 THEN pp := rad_pdf_ri.paragraph(q, b, pf);
                   y := rad_pdf_ri.tag(q, pp, 'FIELD', NULL, 'quote..no', f);                    -- a path outside the grammar
      WHEN 17 THEN pp := rad_pdf_ri.paragraph(q, b, pf); y := rad_pdf_ri.run(q, pp, 'a' || CHR(9) || 'b', f);  -- a tab inside a run
      WHEN 18 THEN pp := rad_pdf_ri.paragraph(q, b, pf); y := rad_pdf_ri.image(q, pp, 7, 10, 10);  -- an image with no resource
      WHEN 19 THEN y := rad_pdf_ri.section(q, 595, 842, 'P', 1, 1, 1, 1, 1, 1, 'N');             -- a second section
      WHEN 20 THEN tt := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(100, 0), bd);             -- a column of width 0
      -- invariants at seal
      WHEN 21 THEN tt := rad_pdf_ri.table_(q, b, g2, bd); rw := rad_pdf_ri.row_(q, tt);
                   cc := rad_pdf_ri.cell(q, rw, cf2); pp := rad_pdf_ri.paragraph(q, cc, pf);
                   rad_pdf_ri.seal(q);                                                           -- spans 1 of 2 columns
      WHEN 22 THEN tt := rad_pdf_ri.table_(q, b, g2, bd);
                   rg := rad_pdf_ri.row_region(q, tt, 'LOOP', NULL, 'lines');
                   rw := rad_pdf_ri.row_(q, rg); cf2.grid_span := 1;
                   cc := rad_pdf_ri.cell(q, rw, cf2); pp := rad_pdf_ri.paragraph(q, cc, pf);
                   rad_pdf_ri.seal(q);                                                           -- the row of a row_region too
      WHEN 23 THEN tt := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(100), bd);
                   rw := rad_pdf_ri.row_(q, tt); cc := rad_pdf_ri.cell(q, rw, cf2); pp := rad_pdf_ri.paragraph(q, cc, pf);
                   rw := rad_pdf_ri.row_(q, tt, 'Y'); cc := rad_pdf_ri.cell(q, rw, cf2); pp := rad_pdf_ri.paragraph(q, cc, pf);
                   rad_pdf_ri.seal(q);                                                           -- a header row after a body row
      WHEN 24 THEN tt := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(100), bd);
                   rg := rad_pdf_ri.row_region(q, tt, 'LOOP', NULL, 'lines');
                   rad_pdf_ri.seal(q);                                                           -- an empty row_region
      WHEN 25 THEN tt := rad_pdf_ri.table_(q, b, rad_pdf_ri.t_num_list(100), bd);
                   rw := rad_pdf_ri.row_(q, tt); cc := rad_pdf_ri.cell(q, rw, cf2);
                   rad_pdf_ri.seal(q);                                                           -- an empty cell
      WHEN 26 THEN pp := rad_pdf_ri.paragraph(q, b, pf);
                   y := rad_pdf_ri.tag(q, pp, 'FIELD', 'lines', 'lines[].code', f);
                   rad_pdf_ri.seal(q);                                                           -- a scope no loop opens
      WHEN 27 THEN rg := rad_pdf_ri.block_region(q, b, 'SECTION', NULL, 'lines');
                   pp := rad_pdf_ri.paragraph(q, rg, pf);
                   y := rad_pdf_ri.tag(q, pp, 'FIELD', 'lines', 'lines[].code', f);
                   rad_pdf_ri.seal(q);                                                           -- a SECTION opens no scope
      WHEN 28 THEN pp := rad_pdf_ri.paragraph(q, b, pf); rad_pdf_ri.seal(q);
                   y := rad_pdf_ri.run(q, pp, 'late', f);                                         -- a sealed RI is immutable
      WHEN 29 THEN rad_pdf_ri.seal(q); rad_pdf_ri.seal(q);                                       -- sealed twice
      WHEN 30 THEN j1 := rad_pdf_ri.to_json(q);                                                  -- an unsealed RI is not serialized
      WHEN 31 THEN y := rad_pdf_ri.table_(q, b, g2, bd); rad_pdf_ri.seal(q);                     -- a table with no row
      WHEN 32 THEN pp := rad_pdf_ri.paragraph(q, b, pf);
                   y := rad_pdf_ri.inline_region(q, pp, 'SECTION', NULL, 'has_discount');
                   rad_pdf_ri.seal(q);                                                           -- an empty inline_region
      WHEN 33 THEN tt := rad_pdf_ri.table_(q, b, g2, bd); rw := rad_pdf_ri.row_(q, tt);
                   cc := rad_pdf_ri.cell(q, rw, cf2); pp := rad_pdf_ri.paragraph(q, cc, pf);
                   y := rad_pdf_ri.tag(q, pp, 'PAGEBREAK', NULL, 'page_break', f);              -- a PAGEBREAK tag in a cell
      WHEN 34 THEN y := rad_pdf_ri.page_break(q, rad_pdf_ri.zone(q, 'footer_default'));         -- a page break in a footer
      WHEN 35 THEN pp := rad_pdf_ri.paragraph(q, rad_pdf_ri.zone(q, 'header_first'), pf);
                   y := rad_pdf_ri.tag(q, pp, 'PAGEBREAK', NULL, 'page_break', f);              -- a PAGEBREAK tag in a header
      WHEN 36 THEN rad_pdf_ri.free(q); pp := rad_pdf_ri.paragraph(q, b, pf);                    -- an RI after free
    END CASE;
    RETURN FALSE;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_ri.c_err_ri AND SQLERRM LIKE '%[PDF_RI]%' THEN
        l_msg := REGEXP_SUBSTR(SQLERRM, '\[PDF_RI\][^' || CHR(10) || ']*'); RETURN TRUE;
      END IF;
      RAISE;
  END refused;

  FUNCTION json_refused(p_json IN CLOB) RETURN BOOLEAN IS
    q rad_pdf_ri.t_ri;
  BEGIN
    q := rad_pdf_ri.from_json(p_json);
    RETURN FALSE;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_ri.c_err_ri THEN
        l_msg := REGEXP_SUBSTR(SQLERRM, '\[PDF_RI\][^' || CHR(10) || ']*'); RETURN TRUE;
      END IF;
      RAISE;
  END json_refused;

BEGIN
  f.font := 'Arial'; f.size_pt := 10;
  fb := f; fb.bold := 'Y';
  bd := rad_pdf_ri.borders_all(rad_pdf_ri.border('SINGLE', 0.5, '808080'));
  tabs.EXTEND(2);
  tabs(1).pos := 300; tabs(1).kind := 'R';
  tabs(2).pos := 450; tabs(2).kind := 'D';

  -- 1. every node kind --------------------------------------------------------
  body := base(ri);
  img := rad_pdf_ri.add_image(ri, c_png, 'PNG', 1, 1);
  -- header first page: an image and a tag; footer default: Page {PAGE} of {NUMPAGES}
  p := rad_pdf_ri.paragraph(ri, rad_pdf_ri.zone(ri, 'header_first'), pf);
  x := rad_pdf_ri.image(ri, p, img, 40, 20);
  x := rad_pdf_ri.tag(ri, p, 'FIELD', NULL, 'company.name', fb);
  p := rad_pdf_ri.paragraph(ri, rad_pdf_ri.zone(ri, 'footer_default'), pf);
  x := rad_pdf_ri.run(ri, p, 'Pagina ', f);
  x := rad_pdf_ri.field(ri, p, 'PAGE', f);
  x := rad_pdf_ri.run(ri, p, ' di ', f);
  x := rad_pdf_ri.field(ri, p, 'NUMPAGES', f);
  -- body: a paragraph with tab stops, a tab, a line break, an inline_region
  pf.align := 'J'; pf.space_after := 6;
  p := rad_pdf_ri.paragraph(ri, body, pf, tabs);
  x := rad_pdf_ri.tag(ri, p, 'FIELD', NULL, 'quote.no', fb);
  x := rad_pdf_ri.tab(ri, p);
  x := rad_pdf_ri.run(ri, p, 'Totale', f);
  x := rad_pdf_ri.line_break(ri, p);
  ir := rad_pdf_ri.inline_region(ri, p, 'SECTION', NULL, 'has_discount');
  x := rad_pdf_ri.run(ri, ir, 'Sconto applicato', f);
  pf.align := 'L'; pf.space_after := 0;
  -- a block_region in the body
  br := rad_pdf_ri.block_region(ri, body, 'SECTION', NULL, 'has_discount');
  p := rad_pdf_ri.paragraph(ri, br, pf);
  x := rad_pdf_ri.run(ri, p, 'Gli importi sono scontati.', f);
  -- a table: header row, row_region with one row whose cells hold tags of the loop; a cell with a block_region
  t := rad_pdf_ri.table_(ri, body, rad_pdf_ri.t_num_list(120, 240, 120), bd);
  r := rad_pdf_ri.row_(ri, t, 'Y', 'Y');
  cf := one_cell; cf.shading := 'D9D9D9'; cf.mar_left := 5.4; cf.mar_right := 5.4;
  c := rad_pdf_ri.cell(ri, r, cf); p := rad_pdf_ri.paragraph(ri, c, pf); x := rad_pdf_ri.run(ri, p, 'Codice', fb);
  cf.grid_span := 2;
  c := rad_pdf_ri.cell(ri, r, cf); p := rad_pdf_ri.paragraph(ri, c, pf); x := rad_pdf_ri.run(ri, p, 'Descrizione e importo', fb);
  rr := rad_pdf_ri.row_region(ri, t, 'LOOP', NULL, 'lines');
  r := rad_pdf_ri.row_(ri, rr, 'N', 'Y');
  cf := one_cell;
  c := rad_pdf_ri.cell(ri, r, cf); p := rad_pdf_ri.paragraph(ri, c, pf);
  x := rad_pdf_ri.tag(ri, p, 'FIELD', 'lines', 'lines[].code', f);
  c := rad_pdf_ri.cell(ri, r, cf); p := rad_pdf_ri.paragraph(ri, c, pf);
  x := rad_pdf_ri.tag(ri, p, 'FIELD', 'lines', 'lines[].description', f);
  x := rad_pdf_ri.tag(ri, p, 'FIELD', NULL, 'quote.no', f);            -- inherited from the root inside the loop
  c := rad_pdf_ri.cell(ri, r, cf);
  br := rad_pdf_ri.block_region(ri, c, 'SECTION', 'lines', 'lines[].discount');
  p := rad_pdf_ri.paragraph(ri, br, pf);
  x := rad_pdf_ri.tag(ri, p, 'FIELD', 'lines', 'lines[].amount', f);
  -- a page break, a fixed box, a page-break tag
  x := rad_pdf_ri.page_break(ri, body);
  x := rad_pdf_ri.fixed_box(ri, body, img, 100, 50, 'Y');
  p := rad_pdf_ri.paragraph(ri, body, pf);
  x := rad_pdf_ri.tag(ri, p, 'PAGEBREAK', NULL, 'page_break', f);
  x := rad_pdf_ri.tag(ri, p, 'IMAGE', NULL, 'company.logo', f);
  rad_pdf_ri.seal(ri);
  assert_ok(ri.sealed = 'Y' AND rad_pdf_ri.node_count(ri) > 40, 'an RI with every node kind is sealed (' || rad_pdf_ri.node_count(ri) || ' nodes)');
  assert_ok(rad_pdf_ri.kids(ri, ri.section_id).COUNT = 5, 'the section holds its five zones');
  assert_ok(rad_pdf_ri.kids(ri, t).COUNT = 2, 'the table holds its header row and its row_region');
  assert_ok(rad_pdf_ri.kids(ri, rr).COUNT = 1, 'the row_region holds exactly one row');
  fr := rad_pdf_ri.fonts(ri);
  assert_ok(fr.COUNT = 1 AND fr(1).name = 'Arial' AND fr(1).variants = 'RB', 'the fonts the template asks for: Arial, regular and bold');

  -- 2. placements ---------------------------------------------------------------
  assert_ok(ri.nodes(ir).parent IS NOT NULL AND ri.nodes(ri.nodes(ir).parent).kind = 'paragraph', 'inline_region placed in a paragraph');
  assert_ok(ri.nodes(br).kind = 'block_region' AND ri.nodes(ri.nodes(br).parent).kind = 'cell', 'block_region placed in a cell');
  assert_ok(ri.nodes(rr).kind = 'row_region' AND ri.nodes(ri.nodes(rr).parent).kind = 'table', 'row_region placed in a table');
  assert_ok(refused(1),  'refused: an inline_region in a zone');
  assert_ok(refused(2),  'refused: a block_region in a paragraph');
  assert_ok(refused(3),  'refused: a row_region in a zone');
  assert_ok(refused(4),  'refused: a row_region in a row_region');
  assert_ok(refused(5),  'refused: a row in a zone');
  assert_ok(refused(6),  'refused: a cell in a table');
  assert_ok(refused(7),  'refused: a run in a zone');
  assert_ok(refused(8),  'refused: a paragraph in a paragraph');
  assert_ok(refused(9),  'refused: a table in a cell (no nested tables in v1)');
  assert_ok(refused(10), 'refused: a second row in a row_region');
  assert_ok(refused(11), 'refused: a header row in a row_region');
  assert_ok(refused(12), 'refused: a field other than PAGE/NUMPAGES');
  assert_ok(refused(13), 'refused: a tag op outside v1');
  assert_ok(refused(14), 'refused: a region kind outside v1');
  assert_ok(refused(15), 'refused: a resolved path outside its scope');
  assert_ok(refused(16), 'refused: a path outside the grammar');
  assert_ok(refused(17), 'refused: a tab inside a run (tabs and breaks are nodes)');
  assert_ok(refused(18), 'refused: an image without its resource');
  assert_ok(refused(19), 'refused: a second section');
  assert_ok(refused(20), 'refused: a grid column of width 0');

  -- 3. invariants at seal ---------------------------------------------------------
  assert_ok(refused(21), 'refused at seal: a row whose grid spans do not sum to the columns');
  assert_ok(refused(22), 'refused at seal: the same for the row of a row_region');
  assert_ok(refused(23), 'refused at seal: a header row after a body row');
  assert_ok(refused(24), 'refused at seal: an empty row_region');
  assert_ok(refused(25), 'refused at seal: an empty cell');
  assert_ok(refused(26), 'refused at seal: a tag in a scope no loop opens');
  assert_ok(refused(27), 'refused at seal: a SECTION region opens no scope');
  assert_ok(refused(28), 'refused: a builder call on a sealed RI');
  assert_ok(refused(29), 'refused: sealing twice');
  assert_ok(refused(30), 'refused: serializing an unsealed RI');
  assert_ok(refused(31), 'refused at seal: a table with no row');
  assert_ok(refused(32), 'refused at seal: an empty inline_region');
  assert_ok(refused(33), 'refused: a PAGEBREAK tag in a cell');
  assert_ok(refused(34), 'refused: a page break in a footer');
  assert_ok(refused(35), 'refused: a PAGEBREAK tag in a header');
  assert_ok(refused(36), 'refused: a builder call on a freed RI');

  -- 4. serialization ------------------------------------------------------------
  j1 := rad_pdf_ri.to_json(ri);
  ri2 := rad_pdf_ri.from_json(j1);
  j2 := rad_pdf_ri.to_json(ri2);
  assert_ok(DBMS_LOB.COMPARE(j1, j2) = 0, 'to_json → from_json → to_json identical (' || DBMS_LOB.GETLENGTH(j1) || ' chars)');
  assert_ok(rad_pdf_ri.node_count(ri2) = rad_pdf_ri.node_count(ri) AND ri2.sealed = 'Y', 'the RI read back is sealed, with the same nodes');
  assert_ok(DBMS_LOB.COMPARE(ri2.images(1).bytes, c_png) = 0, 'the image bytes survive the round trip');
  assert_ok(json_refused(REPLACE(j1, '"grid_span":2', '"grid_span":3')), 'from_json refuses a text whose grid spans break the invariant');
  assert_ok(json_refused(REPLACE(j1, '"ri_version":1', '"ri_version":2')), 'from_json refuses another ri_version');
  assert_ok(json_refused(REGEXP_REPLACE(j1, '"sha256":"[0-9a-f]{8}', '"sha256":"00000000')), 'from_json refuses an image whose hash does not match its bytes');
  assert_ok(json_refused(REPLACE(j1, '"kind":"row_region"', '"kind":"block_region"')), 'from_json refuses a region in the wrong container');
  assert_ok(json_refused('not json'), 'from_json refuses a text that is not JSON');
  assert_ok(json_refused(REPLACE(j1, '"kind":"zone","name":"footer_default"', '"kind":"zone","name":"body"')),
            'from_json refuses a zone given twice');
  assert_ok(json_refused(REPLACE(j1, '"children":[{"kind":"zone","name":"body"', '"children":[7,{"kind":"zone","name":"body"')),
            'from_json refuses a child that is not an object, with [PDF_RI]');
  assert_ok(json_refused(REPLACE(j1, '"grid":[120,240,120]', '"grid":"wide"')),
            'from_json refuses a value of the wrong JSON type, with [PDF_RI]');

  -- 5. two RIs interleaved --------------------------------------------------------
  body := base(r3);
  p := rad_pdf_ri.paragraph(r3, body, pf);
  x := rad_pdf_ri.run(r3, p, 'R3', f);
  rad_pdf_ri.seal(r3);
  assert_ok(rad_pdf_ri.node_count(r3) = 9 AND DBMS_LOB.COMPARE(rad_pdf_ri.to_json(ri), j1) = 0,
            'two RIs built interleaved stay independent');
  rad_pdf_ri.free(ri2);
  assert_ok(ri2.ri_version IS NULL AND ri2.images.COUNT = 0, 'free releases the image copies and empties the RI');

  DBMS_OUTPUT.PUT_LINE('Phase 23 RI: ' || l_pass || ' passed, 0 failed.');
END;
/
