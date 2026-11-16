-- phase24_merge.sql - the data merge (rad_pdf_merge; middleware-docs 96a §5, §6.3; doc 96 §14.8 "unione dei dati")
-- Run from repo root in SQL*Plus after src/install.sql. The quote and the negative samples of 96a §10 are run by
-- tests/word/quote_ri.py; here, the rules one by one:
--   1. the schema refused when malformed ([PRT_SCHEMA]);
--   2. the template against the schema at publication ([PRT_SCHEMA], loop depth [PDF_BUDGET]);
--   3. the data at every print ([PRT_DATA] with the path);
--   4. the runtime reading of 96a §6.3, its normative examples one by one, regions, page breaks, text control
--      characters, images in the Oracle form;
--   5. the instance: sealed, validated, read back; no tag nor region; budgets; a template altered by hand refused.
-- WHENEVER first: with it after SET SERVEROUTPUT, SQLcl refuses this block client-side (no ORA-, its WHENEVER help
-- printed instead); SQL*Plus accepts either order.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  -- a 1x1 red PNG, as a data-URL
  c_png CONSTANT VARCHAR2(200) := 'data:image/png' || CHR(59) || 'base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVQI12P4z8AAAAMBAQAY3Y2wAAAAAElFTkSuQmCC';
  l_pass PLS_INTEGER := 0;
  l_msg  VARCHAR2(4000);
  f      rad_pdf_ri.t_run_fmt;
  pf     rad_pdf_ri.t_para_fmt;
  cf     rad_pdf_ri.t_cell_fmt;
  bd     rad_pdf_ri.t_borders;
  sch    rad_pdf_merge.t_schema;
  t      rad_pdf_ri.t_ri;
  q      rad_pdf_ri.t_ri;
  b      rad_pdf_ri.t_id;
  p      rad_pdf_ri.t_id;
  x      rad_pdf_ri.t_id;
  tb     rad_pdf_ri.t_id;
  r      rad_pdf_ri.t_id;
  c      rad_pdf_ri.t_id;
  g      rad_pdf_ri.t_id;
  g2     rad_pdf_ri.t_id;
  l_big  CLOB;

  PROCEDURE assert_ok(p_ok BOOLEAN, p_message VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_ok, FALSE) THEN RAISE_APPLICATION_ERROR(-20999, 'FAIL ' || p_message); END IF;
    l_pass := l_pass + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  ' || p_message || CASE WHEN l_msg IS NOT NULL THEN '  <' || l_msg || '>' END);
    l_msg := NULL;
  END;

  FUNCTION fld(p VARCHAR2, ty VARCHAR2, rq VARCHAR2, nl VARCHAR2 DEFAULT NULL) RETURN rad_pdf_merge.t_field IS
  BEGIN
    RETURN rad_pdf_merge.field(p, ty, rq, nl);
  END;

  -- TRUE when the error raised has this code and this text (the reason, not just the code)
  FUNCTION is_err(p_code PLS_INTEGER, p_like VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    l_msg := REGEXP_SUBSTR(SQLERRM, '\[[A-Z_]+\][^' || CHR(10) || ']*');
    RETURN SQLCODE = p_code AND l_msg LIKE p_like;
  END;

  FUNCTION schema_refused(p_s rad_pdf_merge.t_schema, p_like VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    rad_pdf_merge.check_schema(p_s);
    RETURN FALSE;
  EXCEPTION WHEN OTHERS THEN RETURN is_err(rad_pdf_merge.c_err_schema, p_like);
  END;

  FUNCTION template_refused(p_t rad_pdf_ri.t_ri, p_s rad_pdf_merge.t_schema, p_code PLS_INTEGER, p_like VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    rad_pdf_merge.check_template(p_t, p_s);
    RETURN FALSE;
  EXCEPTION WHEN OTHERS THEN RETURN is_err(p_code, p_like);
  END;

  FUNCTION data_refused(p_s rad_pdf_merge.t_schema, p_data CLOB, p_like VARCHAR2,
                        p_code PLS_INTEGER DEFAULT rad_pdf_merge.c_err_data) RETURN BOOLEAN IS
  BEGIN
    rad_pdf_merge.check_data(p_data, p_s);
    RETURN FALSE;
  EXCEPTION WHEN OTHERS THEN RETURN is_err(p_code, p_like);
  END;

  FUNCTION merge_refused(p_t rad_pdf_ri.t_ri, p_s rad_pdf_merge.t_schema, p_data CLOB, p_code PLS_INTEGER,
                         p_like VARCHAR2) RETURN BOOLEAN IS
    lv rad_pdf_ri.t_ri;
  BEGIN
    lv := rad_pdf_merge.merge(p_t, p_s, p_data);
    RETURN FALSE;
  EXCEPTION WHEN OTHERS THEN RETURN is_err(p_code, p_like);
  END;

  -- the body of an instance as a line of text, in document order: | a paragraph, <T> a tab, <BR> a line break, <PB> a
  -- page break, <IMG w x h> an image, [ a table, / a row
  FUNCTION show_from(p_i rad_pdf_ri.t_ri, p_id rad_pdf_ri.t_id) RETURN VARCHAR2 IS
    lv VARCHAR2(32767);
    k rad_pdf_ri.t_num_list := rad_pdf_ri.kids(p_i, p_id);
    n rad_pdf_ri.t_node;
  BEGIN
    FOR j IN 1 .. k.COUNT LOOP
      n := p_i.nodes(k(j));
      lv := lv || CASE n.kind
                  WHEN 'paragraph' THEN '|' WHEN 'run' THEN n.text WHEN 'tab' THEN '<T>' WHEN 'line_break' THEN '<BR>'
                  WHEN 'page_break' THEN '<PB>' WHEN 'table' THEN '[' WHEN 'row' THEN '/'
                  WHEN 'image' THEN '<IMG ' || RTRIM(TO_CHAR(n.width, 'FM9990.999', 'NLS_NUMERIC_CHARACTERS=''.,'''), '.') || 'x'
                                   || RTRIM(TO_CHAR(n.height, 'FM9990.999', 'NLS_NUMERIC_CHARACTERS=''.,'''), '.') || '>'
                  ELSE NULL END
             || show_from(p_i, k(j));
    END LOOP;
    RETURN lv;
  END;

  FUNCTION show(p_i rad_pdf_ri.t_ri) RETURN VARCHAR2 IS
  BEGIN
    RETURN show_from(p_i, rad_pdf_ri.zone(p_i, 'body'));
  END;

  -- a template with a body zone; b = the body
  PROCEDURE start_t IS
  BEGIN
    t := rad_pdf_ri.new_ri;
    x := rad_pdf_ri.section(t, 595.3, 841.9, 'P', 56.7, 56.7, 56.7, 56.7, 36, 36, 'N');
    b := rad_pdf_ri.zone(t, 'body');
  END;

  -- one paragraph holding one tag
  FUNCTION one_tag(p_op VARCHAR2, p_scope VARCHAR2, p_path VARCHAR2) RETURN rad_pdf_ri.t_ri IS
  BEGIN
    start_t;
    p := rad_pdf_ri.paragraph(t, b, pf);
    x := rad_pdf_ri.tag(t, p, p_op, p_scope, p_path, f);
    rad_pdf_ri.seal(t);
    RETURN t;
  END;

  -- a loop over lines in a table (one row of one cell, holding the tags given) after a header row
  FUNCTION loop_t(p_tag1 VARCHAR2, p_scope1 VARCHAR2, p_tag2 VARCHAR2 DEFAULT NULL, p_scope2 VARCHAR2 DEFAULT NULL,
                  p_header BOOLEAN DEFAULT TRUE) RETURN rad_pdf_ri.t_ri IS
  BEGIN
    start_t;
    tb := rad_pdf_ri.table_(t, b, rad_pdf_ri.t_num_list(200), bd);
    IF p_header THEN
      r := rad_pdf_ri.row_(t, tb, 'Y'); c := rad_pdf_ri.cell(t, r, cf); p := rad_pdf_ri.paragraph(t, c, pf);
      x := rad_pdf_ri.run(t, p, 'H', f);
    END IF;
    g := rad_pdf_ri.row_region(t, tb, 'LOOP', NULL, 'lines');
    r := rad_pdf_ri.row_(t, g); c := rad_pdf_ri.cell(t, r, cf); p := rad_pdf_ri.paragraph(t, c, pf);
    x := rad_pdf_ri.run(t, p, '-', f);
    x := rad_pdf_ri.tag(t, p, 'FIELD', p_scope1, p_tag1, f);
    IF p_tag2 IS NOT NULL THEN x := rad_pdf_ri.run(t, p, '+', f); x := rad_pdf_ri.tag(t, p, 'FIELD', p_scope2, p_tag2, f); END IF;
    rad_pdf_ri.seal(t);
    RETURN t;
  END;

  FUNCTION merged(p_t rad_pdf_ri.t_ri, p_s rad_pdf_merge.t_schema, p_data CLOB) RETURN VARCHAR2 IS
    lv rad_pdf_ri.t_ri;
    s VARCHAR2(32767);
  BEGIN
    lv := rad_pdf_merge.merge(p_t, p_s, p_data);
    s := show(lv);
    rad_pdf_ri.free(lv);
    RETURN s;
  END;

BEGIN
  f.font := 'Arial'; f.size_pt := 10;
  bd := rad_pdf_ri.borders_all(rad_pdf_ri.border('SINGLE', 0.5, '999999'));

  -- 1. the schema -------------------------------------------------------------------------
  assert_ok(schema_refused(rad_pdf_merge.t_schema(), '%an empty schema%'), 'schema refused: empty');
  assert_ok(schema_refused(rad_pdf_merge.t_schema(fld('a', 'NUMBER', 'Y')), '%type TEXT, BOOLEAN%'), 'schema refused: a type outside v1');
  assert_ok(schema_refused(rad_pdf_merge.t_schema(fld('lines', 'ARRAY', 'Y', 'Y')), '%never nullable%'), 'schema refused: a nullable ARRAY');
  assert_ok(schema_refused(rad_pdf_merge.t_schema(fld('ok', 'BOOLEAN', 'N', 'Y')), '%never nullable%'), 'schema refused: a nullable BOOLEAN');
  assert_ok(schema_refused(rad_pdf_merge.t_schema(fld('a', 'TEXT', 'Y'), fld('a', 'TEXT', 'N')), '%a twice%'), 'schema refused: a path twice');
  assert_ok(schema_refused(rad_pdf_merge.t_schema(fld('lines[].code', 'TEXT', 'N')), '%lines is not an ARRAY%'),
            'schema refused: an element path without its ARRAY');
  assert_ok(schema_refused(rad_pdf_merge.t_schema(fld('a..b', 'TEXT', 'N')), '%invalid path%'), 'schema refused: a path outside the grammar');
  assert_ok(schema_refused(rad_pdf_merge.t_schema(fld('a', 'TEXT', 'X')), '%Y or N%'), 'schema refused: required not Y/N');
  assert_ok(fld('a', 'TEXT', 'N').nullable = 'Y' AND fld('a', 'TEXT', 'Y').nullable = 'N' AND fld('l', 'ARRAY', 'N').nullable = 'N',
            'nullable by the rule of 96a section 5.1: an optional TEXT yes, a required TEXT and an ARRAY no');
  sch := rad_pdf_merge.schema_from_json('{"fields":[{"path":"a","type":"TEXT","required":"Y"},{"path":"lv","type":"ARRAY","required":"N"}]}');
  assert_ok(sch.COUNT = 2 AND sch(1).nullable = 'N' AND sch(2).type = 'ARRAY', 'a schema read from its JSON form');

  -- 2. the template against the schema -------------------------------------------------------
  sch := rad_pdf_merge.t_schema(fld('quote.no', 'TEXT', 'Y'), fld('lines', 'ARRAY', 'Y'), fld('lines[].code', 'TEXT', 'N'),
                                fld('has_discount', 'BOOLEAN', 'Y'), fld('logo', 'IMAGE', 'N'), fld('brk', 'BOOLEAN', 'N'),
                                fld('customer', 'OBJECT', 'N'), fld('customer.name', 'TEXT', 'N'));
  rad_pdf_merge.check_template(one_tag('FIELD', NULL, 'quote.no'), sch);
  assert_ok(TRUE, 'a FIELD tag on a TEXT of the schema accepted');
  assert_ok(template_refused(one_tag('FIELD', NULL, 'colour'), sch, rad_pdf_merge.c_err_schema, '%unknown path colour%'),
            'template refused: a path unknown to the schema (96a: {colour} in a loop)');
  assert_ok(template_refused(one_tag('FIELD', NULL, 'has_discount'), sch, rad_pdf_merge.c_err_schema, '%is BOOLEAN, the FIELD tag needs TEXT%'),
            'template refused: a FIELD tag on a BOOLEAN');
  assert_ok(template_refused(one_tag('IMAGE', NULL, 'quote.no'), sch, rad_pdf_merge.c_err_schema, '%the IMAGE tag needs IMAGE%'),
            'template refused: an IMAGE tag on a TEXT');
  assert_ok(template_refused(one_tag('PAGEBREAK', NULL, 'quote.no'), sch, rad_pdf_merge.c_err_schema, '%the PAGEBREAK tag needs BOOLEAN%'),
            'template refused: a PAGEBREAK tag on a TEXT');
  start_t; g := rad_pdf_ri.block_region(t, b, 'LOOP', NULL, 'quote.no'); p := rad_pdf_ri.paragraph(t, g, pf); rad_pdf_ri.seal(t);
  assert_ok(template_refused(t, sch, rad_pdf_merge.c_err_schema, '%the LOOP needs ARRAY%'), 'template refused: a LOOP on a TEXT');
  start_t; g := rad_pdf_ri.block_region(t, b, 'SECTION', NULL, 'lines'); p := rad_pdf_ri.paragraph(t, g, pf); rad_pdf_ri.seal(t);
  assert_ok(template_refused(t, sch, rad_pdf_merge.c_err_schema, '%is an ARRAY: a LOOP, not a SECTION%'), 'template refused: a SECTION on an ARRAY');
  rad_pdf_merge.check_template(one_tag('FIELD', NULL, 'lines.0.code'), sch);
  assert_ok(TRUE, 'an indexed path checked on the type of the element (lines.0.code -> lines[].code)');
  DECLARE
    s4 rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('a', 'ARRAY', 'Y'), fld('a[].b', 'ARRAY', 'N'),
                                   fld('a[].b[].c', 'ARRAY', 'N'), fld('a[].b[].c[].d', 'ARRAY', 'N'));
  BEGIN
    start_t;
    g := rad_pdf_ri.block_region(t, b, 'LOOP', NULL, 'a');
    g := rad_pdf_ri.block_region(t, g, 'LOOP', 'a', 'a[].b');
    g := rad_pdf_ri.block_region(t, g, 'LOOP', 'a[].b', 'a[].b[].c');
    g := rad_pdf_ri.block_region(t, g, 'LOOP', 'a[].b[].c', 'a[].b[].c[].d');
    p := rad_pdf_ri.paragraph(t, g, pf);
    rad_pdf_ri.seal(t);
    assert_ok(template_refused(t, s4, rad_pdf_merge.c_err_budget, '%loops nested deeper than 3%'),
              'template refused: loops nested deeper than 3 ([PDF_BUDGET], 96a section 8)');
  END;

  -- 3. the data --------------------------------------------------------------------------------
  assert_ok(data_refused(sch, '{"lines":[],"has_discount":true}', '[PRT_DATA] quote.no: required, missing'),
            'data refused: a required field missing, with its path');
  assert_ok(data_refused(sch, '{"quote":{"no":null},"lines":[],"has_discount":true}', '[PRT_DATA] quote.no: null is not allowed'),
            'data refused: a required non-nullable field null');
  assert_ok(data_refused(sch, '{"quote":{"no":"1"},"lines":null,"has_discount":true}', '[PRT_DATA] lines: null is not allowed'),
            'data refused: lines null (96a: an ARRAY is never nullable)');
  assert_ok(data_refused(sch, '{"quote":{"no":"1"},"lines":[],"has_discount":null}', '[PRT_DATA] has_discount: null is not allowed'),
            'data refused: has_discount null');
  assert_ok(data_refused(sch, '{"quote":{"no":7},"lines":[],"has_discount":true}', '[PRT_DATA] quote.no: a TEXT must be a string'),
            'data refused: a number where a TEXT is');
  assert_ok(data_refused(sch, '{"quote":"Q1","lines":[],"has_discount":true}', '[PRT_DATA] quote: an object is expected%'),
            'data refused: a string where an object holds quote.no');
  assert_ok(data_refused(sch, '{"quote":{"no":"1"},"lines":[{"code":"a"},3],"has_discount":true}', '[PRT_DATA] lines[1]: an element is an object'),
            'data refused: an array element that is not an object');
  assert_ok(data_refused(sch, '{"quote":{"no":"1"},"lines":[{"code":5}],"has_discount":true}', '[PRT_DATA] lines[0].code: a TEXT must be a string'),
            'data refused: an element field of the wrong type, with the index in the path');
  assert_ok(data_refused(sch, '{"quote":{"no":"1"},"lines":[],"has_discount":true,"logo":{"source":"FILE","url":"x"}}',
                         '[PRT_DATA] logo: an IMAGE has source "URL"'), 'data refused: an IMAGE whose source is not URL');
  assert_ok(data_refused(sch, '{"quote":{"no":"1"},"lines":[],"has_discount":true,"logo":{"source":"URL","url":"data:image/gif' || CHR(59) || 'base64,R0lG"}}',
                         '[PRT_DATA] logo: only data:image/png or data:image/jpeg%'), 'data refused: a GIF data-URL');
  assert_ok(data_refused(sch, '{"quote":{"no":"1"},"lines":[],"has_discount":true,"logo":{"source":"URL","url":"' || c_png || '","width":"4pt"}}',
                         '[PRT_DATA] logo.width: a positive size%'), 'data refused: an image width with an unknown unit');
  assert_ok(data_refused(sch, '{"quote":{"no":"1"},"lines":[],"has_discount":true,"logo":{"source":"URL","url":"' || c_png || '","height":"0cm"}}',
                         '[PRT_DATA] logo.height: a positive size%'), 'data refused: an image height of 0');
  assert_ok(data_refused(sch, '[1,2]', '[PRT_DATA] the data is not a JSON object%'), 'data refused: not a JSON object');
  rad_pdf_merge.check_data('{"quote":{"no":"1","extra":{"x":1}},"lines":[{"code":null,"more":[1]}],"has_discount":false,"other":1,"logo":null}', sch);
  assert_ok(TRUE, 'data accepted: extra fields ignored, an optional TEXT and an IMAGE null');
  DBMS_LOB.CREATETEMPORARY(l_big, TRUE);
  DBMS_LOB.APPEND(l_big, '{"quote":{"no":"' || RPAD('x', 30000, 'x'));
  FOR i IN 1 .. 180 LOOP DBMS_LOB.APPEND(l_big, RPAD('x', 30000, 'x')); END LOOP;
  DBMS_LOB.APPEND(l_big, '"},"lines":[],"has_discount":true}');
  assert_ok(data_refused(sch, l_big, '[PDF_BUDGET] data over%', rad_pdf_merge.c_err_budget), 'data refused: over 5 MB ([PDF_BUDGET])');
  DBMS_LOB.FREETEMPORARY(l_big);

  -- 4. the runtime reading (96a section 6.3) -------------------------------------------------------
  DECLARE
    s2 rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('code', 'TEXT', 'Y'), fld('quote.no', 'TEXT', 'Y'),
                                   fld('lines', 'ARRAY', 'Y'), fld('lines[].code', 'TEXT', 'N'));
  BEGIN
    assert_ok(merged(loop_t('lines[].code', 'lines'), s2,
                     '{"code":"ROOT","quote":{"no":"Q"},"lines":[{"code":"A"},{},{"code":null},{"code":"D"}]}') = '[/|H/|-A/|-/|-/|-D',
              '{code} in the loop is lines[].code: a row without code or with code null is empty, never the root''s');
    assert_ok(merged(loop_t('lines[].code', 'lines', 'quote.no', NULL), s2,
                     '{"code":"R","quote":{"no":"Q"},"lines":[{"code":"A","quote":{"no":"X"}}]}') = '[/|H/|-A+Q',
              'a key quote in a row never hides quote.no resolved on the root');
    assert_ok(merged(loop_t('lines[].code', 'lines'), s2, '{"code":"R","quote":{"no":"Q"},"lines":[]}') = '[/|H',
              'lines [] gives no row; the header row stays');
    assert_ok(merged(loop_t('lines[].code', 'lines', p_header => FALSE), s2, '{"code":"R","quote":{"no":"Q"},"lines":[]}') IS NULL,
              'lines [] and no header row: no table at all');
    assert_ok(merged(one_tag('FIELD', NULL, 'lines.1.code'), s2, '{"code":"R","quote":{"no":"Q"},"lines":[{"code":"A"},{"code":"B"}]}') = '|B'
              AND merged(one_tag('FIELD', NULL, 'lines.5.code'), s2, '{"code":"R","quote":{"no":"Q"},"lines":[{"code":"A"}]}') = '|',
              'an index reads its element; out of range it is missing (empty)');
  END;
  DECLARE
    s3 rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('vat', 'TEXT', 'N'), fld('has_discount', 'BOOLEAN', 'Y'),
                                   fld('brk', 'BOOLEAN', 'N'), fld('note', 'TEXT', 'N'));
    FUNCTION sect_t RETURN rad_pdf_ri.t_ri IS
    BEGIN
      start_t;
      p := rad_pdf_ri.paragraph(t, b, pf);
      x := rad_pdf_ri.run(t, p, 'Sconti:', f);
      g := rad_pdf_ri.inline_region(t, p, 'SECTION', NULL, 'has_discount');
      x := rad_pdf_ri.run(t, g, 'si', f);
      g := rad_pdf_ri.block_region(t, b, 'SECTION', NULL, 'has_discount');
      p := rad_pdf_ri.paragraph(t, g, pf);
      x := rad_pdf_ri.run(t, p, 'Sconto applicato', f);
      p := rad_pdf_ri.paragraph(t, b, pf);
      x := rad_pdf_ri.run(t, p, 'IVA:', f);
      x := rad_pdf_ri.tag(t, p, 'FIELD', NULL, 'vat', f);
      rad_pdf_ri.seal(t);
      RETURN t;
    END;
  BEGIN
    assert_ok(merged(sect_t, s3, '{"has_discount":true,"vat":"IT1"}') = '|Sconti:si|Sconto applicato|IVA:IT1',
              'SECTION true: the inline and the block regions kept');
    assert_ok(merged(sect_t, s3, '{"has_discount":false,"vat":null}') = '|Sconti:|IVA:',
              'SECTION false: both omitted (the paragraph of the inline one stays); {vat} null is empty');
    start_t;
    p := rad_pdf_ri.paragraph(t, b, pf);
    x := rad_pdf_ri.run(t, p, 'A', f);
    x := rad_pdf_ri.tag(t, p, 'PAGEBREAK', NULL, 'brk', f);
    x := rad_pdf_ri.run(t, p, 'B', f);
    rad_pdf_ri.seal(t);
    assert_ok(merged(t, s3, '{"has_discount":true,"brk":true}') = '|A<PB>|B'
              AND merged(t, s3, '{"has_discount":true,"brk":false}') = '|AB'
              AND merged(t, s3, '{"has_discount":true}') = '|AB',
              '{?brk}: true breaks the page (the paragraph goes on after it), false or absent nothing');
    assert_ok(merge_refused(t, s3, '{"has_discount":true,"brk":"yes"}', rad_pdf_merge.c_err_data, '[PRT_DATA] brk: a BOOLEAN must be true or false'),
              '{?brk} with "yes" refused (96a normative example)');
    assert_ok(merged(one_tag('FIELD', NULL, 'note'), s3, '{"has_discount":true,"note":"a' || '\t' || 'b' || '\n' || 'c' || '\r\n' || 'd"}')
              = '|a<T>b<BR>c<BR>d', 'a tab and a line break of the data become their nodes (a run holds neither); CR dropped');
  END;
  DECLARE
    s5 rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('lines', 'ARRAY', 'Y'), fld('lines[].code', 'TEXT', 'N'),
                                   fld('lines[].parts', 'ARRAY', 'N'), fld('lines[].parts[].name', 'TEXT', 'N'));
  BEGIN
    start_t;
    g := rad_pdf_ri.block_region(t, b, 'LOOP', NULL, 'lines');
    g2 := rad_pdf_ri.block_region(t, g, 'LOOP', 'lines', 'lines[].parts');
    p := rad_pdf_ri.paragraph(t, g2, pf);
    x := rad_pdf_ri.tag(t, p, 'FIELD', 'lines', 'lines[].code', f);
    x := rad_pdf_ri.run(t, p, '.', f);
    x := rad_pdf_ri.tag(t, p, 'FIELD', 'lines[].parts', 'lines[].parts[].name', f);
    rad_pdf_ri.seal(t);
    assert_ok(merged(t, s5, '{"lines":[{"code":"A","parts":[{"name":"x"},{"name":"y"}]},{"code":"B"},{"code":"C","parts":[{"name":"z"}]}]}')
              = '|A.x|A.y|C.z', 'nested loops: the inner element and the outer one read by their scopes; an absent array repeats nothing');
  END;
  DECLARE
    s6 rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('logo', 'IMAGE', 'N'));
  BEGIN
    assert_ok(merged(one_tag('IMAGE', NULL, 'logo'), s6, '{"logo":{"source":"URL","url":"' || c_png || '","width":"4cm"}}')
              = '|<IMG 113.386x113.386>', 'an IMAGE with its width only: the height in proportion (4 cm = 113.386 pt)');
    assert_ok(merged(one_tag('IMAGE', NULL, 'logo'), s6, '{"logo":{"source":"URL","url":"' || c_png || '","height":"96px"}}')
              = '|<IMG 72x72>', 'an IMAGE with its height only, in px (96 px/in)');
    assert_ok(merged(one_tag('IMAGE', NULL, 'logo'), s6, '{"logo":{"source":"URL","url":"' || c_png || '"}}')
              = '|<IMG 0.75x0.75>', 'an IMAGE with no size: its natural size at 96 dpi');
    assert_ok(merged(one_tag('IMAGE', NULL, 'logo'), s6, '{"logo":null}') = '|' AND merged(one_tag('IMAGE', NULL, 'logo'), s6, '{}') = '|',
              'an IMAGE null or absent: no image');
    assert_ok(merge_refused(one_tag('IMAGE', NULL, 'logo'), s6, '{"logo":{"source":"URL","url":"data:image/png' || CHR(59) || 'base64,AAAAAAAAAAAAAAAAAAAAAAAA"}}',
                            rad_pdf_merge.c_err_data, '[PRT_DATA] logo: the bytes are not a PNG image'),
              'an IMAGE whose bytes are not the declared format refused');
    q := rad_pdf_merge.merge(one_tag('IMAGE', NULL, 'logo'), s6, '{"logo":{"source":"URL","url":"' || c_png || '"}}');
    assert_ok(q.images.COUNT = 1 AND q.images(1).format = 'PNG' AND q.images(1).px_w = 1,
              'the image of the data becomes a resource of the instance');
    rad_pdf_ri.free(q);
  END;
  DECLARE
    s7 rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('ok', 'BOOLEAN', 'Y'));
  BEGIN
    start_t;
    tb := rad_pdf_ri.table_(t, b, rad_pdf_ri.t_num_list(100), bd);
    r := rad_pdf_ri.row_(t, tb); c := rad_pdf_ri.cell(t, r, cf);
    g := rad_pdf_ri.block_region(t, c, 'SECTION', NULL, 'ok');
    p := rad_pdf_ri.paragraph(t, g, pf); x := rad_pdf_ri.run(t, p, 'yes', f);
    rad_pdf_ri.seal(t);
    assert_ok(merged(t, s7, '{"ok":false}') = '[/|' AND merged(t, s7, '{"ok":true}') = '[/|yes',
              'a cell whose blocks are all omitted keeps an empty paragraph (Word)');
  END;

  -- 5. the instance ----------------------------------------------------------------------------------
  DECLARE
    s2 rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('quote.no', 'TEXT', 'Y'), fld('lines', 'ARRAY', 'Y'),
                                   fld('lines[].code', 'TEXT', 'N'));
    j  CLOB;
    t2 rad_pdf_ri.t_ri;
  BEGIN
    q := rad_pdf_merge.merge(loop_t('lines[].code', 'lines', 'quote.no', NULL), s2, '{"quote":{"no":"Q"},"lines":[{"code":"A"}]}');
    rad_pdf_ri.validate(q);
    j := rad_pdf_ri.to_json(q);
    assert_ok(q.sealed = 'Y' AND q.instance = 'Y' AND j LIKE '{"ri_version":1,"instance":"Y",%'
              AND DBMS_LOB.COMPARE(rad_pdf_ri.to_json(rad_pdf_ri.from_json(j)), j) = 0,
              'the instance is sealed, validates, and reads back identical (marked "instance")');
    BEGIN
      q.sealed := 'N';
      p := rad_pdf_ri.paragraph(q, rad_pdf_ri.zone(q, 'body'), pf);
      x := rad_pdf_ri.tag(q, p, 'FIELD', NULL, 'quote.no', f);
      assert_ok(FALSE, 'a tag in an instance');
    EXCEPTION WHEN OTHERS THEN
      assert_ok(is_err(rad_pdf_ri.c_err_ri, '%an instance holds no tag%'), 'an instance refuses a tag (and a region): the merge has resolved them');
    END;
    rad_pdf_ri.free(q);
    q := rad_pdf_merge.merge(one_tag('FIELD', NULL, 'quote.no'), s2, '{"quote":{"no":"Q"},"lines":[]}');
    assert_ok(template_refused(q, s2, rad_pdf_merge.c_err_schema, '%an instance is not a template%'), 'an instance is never merged again');
    rad_pdf_ri.free(q);
    t2 := loop_t('lines[].code', 'lines');
    t2.nodes(rad_pdf_ri.node_count(t2)).ref_path := 'colour';
    assert_ok(merge_refused(t2, s2, '{"quote":{"no":"Q"},"lines":[]}', rad_pdf_ri.c_err_ri, '[PDF_RI]%'),
              'merge validates the template first: a sealed template altered by hand refused with [PDF_RI]');
    DBMS_LOB.CREATETEMPORARY(l_big, TRUE);
    DBMS_LOB.APPEND(l_big, '{"quote":{"no":"Q"},"lines":[');
    FOR i IN 1 .. 5000 LOOP DBMS_LOB.APPEND(l_big, CASE WHEN i > 1 THEN ',' END || '{"code":"' || i || '"}'); END LOOP;
    DBMS_LOB.APPEND(l_big, ']}');
    assert_ok(merge_refused(loop_t('lines[].code', 'lines'), s2, l_big, rad_pdf_merge.c_err_budget, '[PDF_BUDGET] the merged document exceeds 20000 nodes'),
              'the expansion over 20000 nodes refused ([PDF_BUDGET], 96a section 8)');
    DBMS_LOB.FREETEMPORARY(l_big);
  END;

  DBMS_OUTPUT.PUT_LINE('Phase 24 merge: ' || l_pass || ' passed, 0 failed.');
END;
/
