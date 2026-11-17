-- phase24_merge.sql - the data merge (rad_pdf_merge; middleware-docs 96a §5, §6.3; doc 96 §14.8 "unione dei dati")
-- Run from repo root in SQL*Plus after src/install.sql. The quote and the negative samples of 96a §10 are run by
-- tests/word/quote_ri.py; here, the rules one by one:
--   1. the schema refused when malformed ([PRT_SCHEMA]);
--   2. the template against the schema at publication ([PRT_SCHEMA], loop depth [PDF_BUDGET]);
--   3. the data at every print ([PRT_DATA] with the path);
--   4. the runtime reading of 96a §6.3, its normative examples one by one, regions, page breaks, text control
--      characters, images in the Oracle form;
--   5. the instance: sealed, validated, read back; no tag nor region; budgets; a template altered by hand refused;
--   6. codex-048: loop depth by structure, loop bindings restored, cumulative LOB and node budgets, the JSON limit in
--      bytes, temporaries released on image failures (V$TEMPORARY_LOBS), one IMAGE validation with the concrete path;
--   7. codex-049: every temporary reserved before it is allocated (url, bytes, pixels, copy), the decoders' structure
--      (IDAT, IEND), long IMAGE members, a long FIELD over budget leaking nothing;
--   8. codex-050: every CLOB read from the data reserved before (FIELD text, SECTION string, IMAGE members, at 2 bytes
--      per character), an empty IDAT stream.
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
    t2.nodes(rad_pdf_ri.node_count(t2)).bind_path := 'colour';
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

  -- 6. codex-048: depth by structure, loop bindings, budgets, bytes, LOB release, the IMAGE boundary ----------------
  DECLARE
    s8 rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('a', 'ARRAY', 'Y'), fld('b', 'ARRAY', 'Y'), fld('c', 'ARRAY', 'Y'),
                                   fld('d', 'ARRAY', 'Y'), fld('a[].code', 'TEXT', 'N'));
  BEGIN
    start_t;
    g := rad_pdf_ri.block_region(t, b, 'LOOP', NULL, 'a');
    g := rad_pdf_ri.block_region(t, g, 'LOOP', NULL, 'b');
    g := rad_pdf_ri.block_region(t, g, 'LOOP', NULL, 'c');
    g2 := rad_pdf_ri.block_region(t, g, 'LOOP', NULL, 'd');
    p := rad_pdf_ri.paragraph(t, g2, pf);
    rad_pdf_ri.seal(t);
    assert_ok(template_refused(t, s8, rad_pdf_merge.c_err_budget, '%loops nested deeper than 3%'),
              'R1: four nested LOOPs over four independent root arrays refused (depth by structure, not by [])');
    start_t;
    g := rad_pdf_ri.block_region(t, b, 'LOOP', NULL, 'a');
    g := rad_pdf_ri.block_region(t, g, 'LOOP', NULL, 'b');
    g := rad_pdf_ri.block_region(t, g, 'LOOP', NULL, 'c');
    p := rad_pdf_ri.paragraph(t, g, pf);
    x := rad_pdf_ri.run(t, p, '.', f);
    rad_pdf_ri.seal(t);
    rad_pdf_merge.check_template(t, s8);
    assert_ok(merged(t, s8, '{"a":[{},{}],"b":[{}],"c":[{},{},{}],"d":[]}') = '|.|.|.|.|.|.', 'R1: depth 3 accepted (2 x 1 x 3 paragraphs)');
    -- R2: a LOOP reopening the path of the loop around it; the outer element read again after the inner loop
    start_t;
    g := rad_pdf_ri.block_region(t, b, 'LOOP', NULL, 'a');
    g2 := rad_pdf_ri.block_region(t, g, 'LOOP', NULL, 'a');
    p := rad_pdf_ri.paragraph(t, g2, pf);
    x := rad_pdf_ri.tag(t, p, 'FIELD', 'a', 'a[].code', f);
    p := rad_pdf_ri.paragraph(t, g, pf);
    x := rad_pdf_ri.run(t, p, '>', f);
    x := rad_pdf_ri.tag(t, p, 'FIELD', 'a', 'a[].code', f);
    rad_pdf_ri.seal(t);
    assert_ok(merged(t, s8, '{"a":[{"code":"A"},{"code":"B"}],"b":[],"c":[],"d":[]}') = '|A|B|>A|A|B|>B',
              'R2: an inner LOOP on the same path hides the outer element and gives it back when it ends');
  END;
  DECLARE
    s9 rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('note', 'TEXT', 'N'), fld('lines', 'ARRAY', 'Y'),
                                   fld('lines[].logo', 'IMAGE', 'N'), fld('logo', 'IMAGE', 'N'), fld('unused', 'IMAGE', 'N'));
    l_t  CLOB;
    l_u  CLOB;
    l_b  BLOB;
    l_n0 NUMBER;
    l_png BLOB;
    l_raw RAW(32767);

    FUNCTION tmp_lobs RETURN NUMBER IS
      n NUMBER;
    BEGIN
      EXECUTE IMMEDIATE 'SELECT cache_lobs + nocache_lobs + abstract_lobs FROM v$temporary_lobs WHERE sid = SYS_CONTEXT(''USERENV'', ''SID'')' INTO n;
      RETURN n;
    END;

    -- a PNG of p_w x 1 pixels (RGB, black): signature, IHDR, IDAT (zlib), IEND; the CRCs are not read by the decoder
    FUNCTION png(p_w PLS_INTEGER) RETURN BLOB IS
      l_raw_rows BLOB;
      l_z  BLOB;
      l_out BLOB;
      FUNCTION u32(n NUMBER) RETURN RAW IS BEGIN RETURN HEXTORAW(LPAD(TRIM(TO_CHAR(n, 'XXXXXXXX')), 8, '0')); END;
    BEGIN
      DBMS_LOB.CREATETEMPORARY(l_raw_rows, TRUE);
      DBMS_LOB.WRITEAPPEND(l_raw_rows, 1, HEXTORAW('00'));
      FOR i IN 1 .. CEIL(p_w * 3 / 1000) LOOP
        DBMS_LOB.WRITEAPPEND(l_raw_rows, LEAST(1000, p_w * 3 - (i - 1) * 1000), UTL_RAW.COPIES(HEXTORAW('00'), LEAST(1000, p_w * 3 - (i - 1) * 1000)));
      END LOOP;
      l_z := rad_pdf_codec.flate_encode(l_raw_rows);
      DBMS_LOB.CREATETEMPORARY(l_out, TRUE);
      DBMS_LOB.APPEND(l_out, TO_BLOB(HEXTORAW('89504E470D0A1A0A') || u32(13) || UTL_RAW.CAST_TO_RAW('IHDR') || u32(p_w) || u32(1)
                                     || HEXTORAW('0802000000') || u32(0) || u32(DBMS_LOB.GETLENGTH(l_z)) || UTL_RAW.CAST_TO_RAW('IDAT')));
      DBMS_LOB.APPEND(l_out, l_z);
      DBMS_LOB.APPEND(l_out, TO_BLOB(u32(0) || u32(0) || UTL_RAW.CAST_TO_RAW('IEND') || u32(0)));
      DBMS_LOB.FREETEMPORARY(l_raw_rows);
      DBMS_LOB.FREETEMPORARY(l_z);
      RETURN l_out;
    END;

    FUNCTION url_of(p_png BLOB) RETURN CLOB IS
      l_b64 CLOB := rad_pdf_codec.base64_encode(p_png);
      l_u   CLOB;
    BEGIN
      DBMS_LOB.CREATETEMPORARY(l_u, TRUE);
      DBMS_LOB.APPEND(l_u, 'data:image/png' || CHR(59) || 'base64,');
      DBMS_LOB.APPEND(l_u, l_b64);
      DBMS_LOB.FREETEMPORARY(l_b64);
      RETURN l_u;
    END;
  BEGIN
    -- R3: one image repeated by a loop is one resource; the template's images count in the LOB budget
    DBMS_LOB.CREATETEMPORARY(l_t, TRUE);
    DBMS_LOB.APPEND(l_t, '{"lines":[');
    FOR i IN 1 .. 65 LOOP
      DBMS_LOB.APPEND(l_t, CASE WHEN i > 1 THEN ',' END || '{"logo":{"source":"URL","url":"' || c_png || '"}}');
    END LOOP;
    DBMS_LOB.APPEND(l_t, ']}');
    start_t;
    tb := rad_pdf_ri.table_(t, b, rad_pdf_ri.t_num_list(100), bd);
    g := rad_pdf_ri.row_region(t, tb, 'LOOP', NULL, 'lines');
    r := rad_pdf_ri.row_(t, g); c := rad_pdf_ri.cell(t, r, cf); p := rad_pdf_ri.paragraph(t, c, pf);
    x := rad_pdf_ri.tag(t, p, 'IMAGE', 'lines', 'lines[].logo', f);
    rad_pdf_ri.seal(t);
    q := rad_pdf_merge.merge(t, s9, l_t);
    assert_ok(q.images.COUNT = 1 AND REGEXP_COUNT(show(q), '<IMG') = 65,
              'R3: one image repeated 65 times by a loop: 65 image nodes, ONE resource');
    rad_pdf_ri.free(q);
    DBMS_LOB.FREETEMPORARY(l_t);
    DBMS_LOB.CREATETEMPORARY(l_b, TRUE);
    l_raw := UTL_RAW.COPIES(HEXTORAW('00'), 32000);
    FOR i IN 1 .. 1050 LOOP DBMS_LOB.WRITEAPPEND(l_b, 32000, l_raw); END LOOP;       -- 33.6 MB
    start_t;
    x := rad_pdf_ri.add_image(t, l_b, 'PNG', 1, 1);
    x := rad_pdf_ri.add_image(t, l_b, 'PNG', 1, 1);
    p := rad_pdf_ri.paragraph(t, b, pf);
    x := rad_pdf_ri.run(t, p, '.', f);
    rad_pdf_ri.seal(t);
    DBMS_LOB.FREETEMPORARY(l_b);
    assert_ok(merge_refused(t, s9, '{"lines":[]}', rad_pdf_merge.c_err_budget, '[PDF_BUDGET] template image 2: its copy in the document would exceed the 67108864 bytes of temporary LOBs'),
              'R3: the cumulative LOB budget (64 MB): two template images of 33.6 MB refused before the second copy');
    rad_pdf_ri.free(t);
    DBMS_LOB.CREATETEMPORARY(l_t, TRUE);
    DBMS_LOB.APPEND(l_t, '{"lines":[],"note":"');
    FOR i IN 1 .. 30 LOOP DBMS_LOB.APPEND(l_t, RPAD('\t', 2000, '\t')); END LOOP;     -- 30000 tabs
    DBMS_LOB.APPEND(l_t, '"}');
    assert_ok(merge_refused(one_tag('FIELD', NULL, 'note'), s9, l_t, rad_pdf_merge.c_err_budget, '[PDF_BUDGET] the merged document exceeds 20000 nodes'),
              'R3: one FIELD of 30000 tabs refused at the node budget, inside the text');
    DBMS_LOB.FREETEMPORARY(l_t);
    -- R4: the JSON limit in bytes
    DBMS_LOB.CREATETEMPORARY(l_t, TRUE);
    DBMS_LOB.APPEND(l_t, '{"lines":[],"note":"');
    FOR i IN 1 .. 200 LOOP DBMS_LOB.APPEND(l_t, RPAD(UNISTR('\00E8'), 15000, UNISTR('\00E8'))); END LOOP;
    DBMS_LOB.APPEND(l_t, '"}');
    assert_ok(DBMS_LOB.GETLENGTH(l_t) < rad_pdf_merge.c_max_json_bytes
              AND data_refused(s9, l_t, '[PDF_BUDGET] data over 5242880 bytes', rad_pdf_merge.c_err_budget),
              'R4: 3,000,000 characters of 2 bytes (6 MB) refused although under 5 MB in characters');
    DBMS_LOB.FREETEMPORARY(l_t);
    DBMS_LOB.CREATETEMPORARY(l_t, TRUE);
    DBMS_LOB.APPEND(l_t, '{"lines":[],"note":"');
    FOR i IN 1 .. 174 LOOP DBMS_LOB.APPEND(l_t, RPAD('x', 30000, 'x')); END LOOP;
    DBMS_LOB.APPEND(l_t, RPAD('x', 5242880 - 174 * 30000 - 20 - 2, 'x') || '"}');
    rad_pdf_merge.check_data(l_t, s9);
    DBMS_LOB.APPEND(l_t, ' ');
    assert_ok(data_refused(s9, l_t, '[PDF_BUDGET] data over 5242880 bytes', rad_pdf_merge.c_err_budget),
              'R4: exactly 5242880 bytes accepted, one byte more refused');
    DBMS_LOB.FREETEMPORARY(l_t);
    -- R6: the IMAGE boundary, every value checked with its concrete path, used by the template or not
    assert_ok(data_refused(s9, '{"lines":[],"logo":{"source":"","url":"' || c_png || '"}}', '[PRT_DATA] logo.source: empty'),
              'R6: an IMAGE with source "" refused');
    assert_ok(data_refused(s9, '{"lines":[],"unused":{"source":"URL","url":"data:image/png' || CHR(59) || 'base64,AAAAAAAAAAAAAAAAAAAAAAAA"}}',
                           '[PRT_DATA] unused: the bytes are not a PNG image'),
              'R6: an IMAGE of the schema that no tag uses is still decoded: bytes not PNG refused');
    assert_ok(data_refused(s9, '{"lines":[],"logo":{"source":"URL","url":"data:image/png' || CHR(59) || 'base64,iVBO@@@@"}}',
                           '[PRT_DATA] logo: the url is not valid base64%'), 'R6: malformed base64 refused as [PRT_DATA], no raw ORA');
    assert_ok(data_refused(s9, '{"lines":[{"logo":{"source":"URL","url":"' || c_png || '"}},{"logo":{"source":"URL","url":"data:image/png'
                           || CHR(59) || 'base64,AAAAAAAAAAAAAAAAAAAAAAAA"}}]}', '[PRT_DATA] lines[1].logo: the bytes are not a PNG image'),
              'R6: a wrong image in a loop element named with its index (lines[1].logo)');
    -- R5: the temporaries released on every image failure, then a valid print in the same session
    l_png := png(4001);
    l_u := url_of(l_png);
    DBMS_LOB.CREATETEMPORARY(l_t, TRUE);
    DBMS_LOB.APPEND(l_t, '{"lines":[],"logo":{"source":"URL","url":"');
    DBMS_LOB.APPEND(l_t, l_u);
    DBMS_LOB.APPEND(l_t, '"}}');
    DBMS_LOB.FREETEMPORARY(l_u);
    DBMS_LOB.FREETEMPORARY(l_png);
    -- warm-up, then ten rounds: a leak would grow the session's temporary LOBs by at least one per failure
    FOR k IN 0 .. 10 LOOP
      IF k = 1 THEN l_n0 := tmp_lobs; END IF;
      IF k > 0 THEN l_pass := l_pass - 3; END IF;      -- the three checks count once
      assert_ok(merge_refused(one_tag('IMAGE', NULL, 'logo'), s9, l_t, rad_pdf_merge.c_err_budget, '[PDF_BUDGET] logo: an image over 4000x4000 pixels'),
                'R5: an image of 4001 pixels refused ([PDF_BUDGET])');
      assert_ok(merge_refused(one_tag('IMAGE', NULL, 'logo'), s9, '{"lines":[],"logo":{"source":"URL","url":"data:image/png' || CHR(59)
                              || 'base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"}}', rad_pdf_merge.c_err_data, '[PRT_DATA] logo: not a valid PNG image%'),
                'R5: a truncated PNG refused ([PRT_DATA])');
      assert_ok(merge_refused(one_tag('IMAGE', NULL, 'logo'), s9, '{"lines":[],"logo":{"source":"URL","url":"data:image/png' || CHR(59)
                              || 'base64,iVBO@@@@"}}', rad_pdf_merge.c_err_data, '[PRT_DATA] logo: the url is not valid base64%'),
                'R5: malformed base64 refused in merge');
    END LOOP;
    assert_ok(tmp_lobs <= l_n0, 'R5: ten rounds of the three failures leave no temporary LOB (' || tmp_lobs || ' <= ' || l_n0 || ')');
    q := rad_pdf_merge.merge(one_tag('IMAGE', NULL, 'logo'), s9, '{"lines":[],"logo":{"source":"URL","url":"' || c_png || '"}}');
    assert_ok(q.images.COUNT = 1 AND show(q) = '|<IMG 0.75x0.75>', 'R5: a valid print in the same session after the failures');
    rad_pdf_ri.free(q);
    assert_ok(tmp_lobs <= l_n0, 'R5: and nothing left after it once freed');
    DBMS_LOB.FREETEMPORARY(l_t);
  END;

  -- 7. codex-049: every temporary reserved before it exists; the decoders' structure; long IMAGE members --------------
  DECLARE
    s10  rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('logo', 'IMAGE', 'N'), fld('note', 'TEXT', 'N'),
                                    fld('unused', 'IMAGE', 'N'));
    c_cap CONSTANT NUMBER := rad_pdf_merge.c_max_lob_bytes;
    l_png  BLOB;
    l_u    CLOB;
    l_d    CLOB;
    l_t    CLOB;
    l_fill BLOB;
    l_raw  RAW(32767) := UTL_RAW.COPIES(HEXTORAW('00'), 32000);
    l_url_n NUMBER;
    l_est  NUMBER;
    l_bytes_n NUMBER;
    l_n0   NUMBER;

    FUNCTION tmp_lobs RETURN NUMBER IS
      n NUMBER;
    BEGIN
      EXECUTE IMMEDIATE 'SELECT cache_lobs + nocache_lobs + abstract_lobs FROM v$temporary_lobs WHERE sid = SYS_CONTEXT(''USERENV'', ''SID'')' INTO n;
      RETURN n;
    END;

    -- a template holding an image resource of p_n bytes (its content is never decoded: template images are resources
    -- of a sealed RI), p_extra as a second resource when given, and one IMAGE tag on logo
    FUNCTION tpl_with(p_n NUMBER, p_extra BLOB DEFAULT NULL) RETURN rad_pdf_ri.t_ri IS
      l_r rad_pdf_ri.t_ri;
      l_b BLOB;
    BEGIN
      DBMS_LOB.CREATETEMPORARY(l_b, TRUE);
      WHILE DBMS_LOB.GETLENGTH(l_b) + 32000 <= p_n LOOP DBMS_LOB.WRITEAPPEND(l_b, 32000, l_raw); END LOOP;
      IF p_n - NVL(DBMS_LOB.GETLENGTH(l_b), 0) > 0 THEN
        DBMS_LOB.WRITEAPPEND(l_b, p_n - DBMS_LOB.GETLENGTH(l_b), UTL_RAW.SUBSTR(l_raw, 1, p_n - DBMS_LOB.GETLENGTH(l_b)));
      END IF;
      l_r := rad_pdf_ri.new_ri;
      x := rad_pdf_ri.section(l_r, 595.3, 841.9, 'P', 56.7, 56.7, 56.7, 56.7, 36, 36, 'N');
      x := rad_pdf_ri.add_image(l_r, l_b, 'PNG', 1, 1);
      DBMS_LOB.FREETEMPORARY(l_b);
      IF p_extra IS NOT NULL THEN x := rad_pdf_ri.add_image(l_r, p_extra, 'PNG', 1, 1); END IF;
      p := rad_pdf_ri.paragraph(l_r, rad_pdf_ri.zone(l_r, 'body'), pf);
      x := rad_pdf_ri.tag(l_r, p, 'IMAGE', NULL, 'logo', f);
      rad_pdf_ri.seal(l_r);
      RETURN l_r;
    END;
  BEGIN
    -- the data: a data-URL of a valid 1x1 PNG
    DBMS_LOB.CREATETEMPORARY(l_d, TRUE);
    DBMS_LOB.APPEND(l_d, '{"logo":{"source":"URL","url":"' || c_png || '"}}');
    l_url_n := LENGTH(c_png);
    l_est := CEIL((l_url_n - 22) * 3 / 4);
    l_png := rad_pdf_codec.base64_decode(TO_CLOB(c_png), 23);
    l_bytes_n := DBMS_LOB.GETLENGTH(l_png);
    -- (a) the same bytes already a resource of the template: the url is still reserved, with no new resource
    t := tpl_with(c_cap - l_bytes_n - l_url_n + 1, l_png);   -- the template: the same PNG + a filler
    assert_ok(merge_refused(t, s10, l_d, rad_pdf_merge.c_err_budget, '[PDF_BUDGET] logo%would exceed%'),
              'R3: the reads of an image whose bytes the template already holds are reserved too (refused 1 byte over)');
    rad_pdf_ri.free(t);
    -- (b) a peak while decoding: the url and its bytes fit, the decoder's output does not
    t := tpl_with(c_cap - 2 * l_url_n - l_est - l_bytes_n + 1);     -- the url as a CLOB: 2 bytes per character
    assert_ok(merge_refused(t, s10, l_d, rad_pdf_merge.c_err_budget, '[PDF_BUDGET] logo: its pixels would exceed%'),
              'R3: a peak during decoding refused before the decoder allocates');
    rad_pdf_ri.free(t);
    -- (c) the boundary: everything held at once fits exactly -> accepted
    t := tpl_with(c_cap - 2 * l_url_n - l_est - l_bytes_n);
    q := rad_pdf_merge.merge(t, s10, l_d);
    assert_ok(q.images.COUNT = 2, 'R3: at the boundary (the url, the bytes and the pixels held together = 64 MB) accepted');
    rad_pdf_ri.free(q);
    rad_pdf_ri.free(t);
    DBMS_LOB.FREETEMPORARY(l_png);
    DBMS_LOB.FREETEMPORARY(l_d);
    -- R6: the decoders' structure, for an IMAGE no tag uses too
    assert_ok(data_refused(s10, '{"unused":{"source":"URL","url":"data:image/png' || CHR(59) || 'base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1Pe"}}',
                           '[PRT_DATA] unused: not a valid PNG image%no IDAT%'),
              'R6: a PNG of signature and IHDR only (codex-049 fixture) refused: no IDAT');
    l_png := TO_BLOB(HEXTORAW('89504E470D0A1A0A0000000D4948445200000001000000010802000000907753DE0000000C4944415408D763F8CFC000000301010018DD8DB0'));
    l_u := rad_pdf_codec.base64_encode(l_png);
    DBMS_LOB.CREATETEMPORARY(l_t, TRUE);
    DBMS_LOB.APPEND(l_t, '{"unused":{"source":"URL","url":"data:image/png' || CHR(59) || 'base64,');
    DBMS_LOB.APPEND(l_t, l_u);
    DBMS_LOB.APPEND(l_t, '"}}');
    assert_ok(data_refused(s10, l_t, '[PRT_DATA] unused: not a valid PNG image%no IEND%'),
              'R6: a PNG with IDAT but without IEND refused');
    assert_ok(merge_refused(one_tag('IMAGE', NULL, 'logo'), s10, REPLACE(l_t, '"unused"', '"logo"'), rad_pdf_merge.c_err_data,
                            '[PRT_DATA] logo: not a valid PNG image%no IEND%'), 'R6: and in merge');
    DBMS_LOB.FREETEMPORARY(l_t); DBMS_LOB.FREETEMPORARY(l_u); DBMS_LOB.FREETEMPORARY(l_png);
    assert_ok(data_refused(s10, '{"logo":{"source":"' || RPAD('U', 4001, 'U') || '","url":"' || c_png || '"}}',
                           '[PRT_DATA] logo.source: too long (4001 characters)'), 'R6: a source of 4001 characters refused with its path, no ORA-06502');
    assert_ok(data_refused(s10, '{"logo":{"source":"URL","url":"' || c_png || '","width":"' || RPAD('9', 4001, '9') || 'cm"}}',
                           '[PRT_DATA] logo.width: too long (4003 characters)'), 'R6: a width of 4003 characters refused');
    -- P3: a long FIELD over the node budget, ten times: no temporary LOB left
    DBMS_LOB.CREATETEMPORARY(l_t, TRUE);
    DBMS_LOB.APPEND(l_t, '{"note":"');
    FOR i IN 1 .. 30 LOOP DBMS_LOB.APPEND(l_t, RPAD('\t', 2000, '\t')); END LOOP;
    DBMS_LOB.APPEND(l_t, '"}');
    FOR k IN 0 .. 10 LOOP
      IF k = 1 THEN l_n0 := tmp_lobs; END IF;
      IF k > 0 THEN l_pass := l_pass - 1; END IF;
      assert_ok(merge_refused(one_tag('FIELD', NULL, 'note'), s10, l_t, rad_pdf_merge.c_err_budget, '[PDF_BUDGET] the merged document exceeds 20000 nodes'),
                'P3: a FIELD of 30000 tabs refused at the node budget');
    END LOOP;
    assert_ok(tmp_lobs <= l_n0, 'P3: ten such refusals leave no temporary LOB (' || tmp_lobs || ' <= ' || l_n0 || ')');
    DBMS_LOB.FREETEMPORARY(l_t);
  END;

  -- 8. codex-050: every CLOB read from the data reserved before (FIELD text, SECTION string, IMAGE members); an empty
  --    IDAT stream ----------------------------------------------------------------------------------------------------------
  DECLARE
    s11  rad_pdf_merge.t_schema := rad_pdf_merge.t_schema(fld('note', 'TEXT', 'N'), fld('logo', 'IMAGE', 'N'),
                                    fld('unused', 'IMAGE', 'N'));
    c_cap CONSTANT NUMBER := rad_pdf_merge.c_max_lob_bytes;
    l_raw RAW(32767) := UTL_RAW.COPIES(HEXTORAW('00'), 32000);
    l_d   VARCHAR2(32767);
    l_jb  NUMBER;
    l_n0  NUMBER;

    FUNCTION tmp_lobs RETURN NUMBER IS
      n NUMBER;
    BEGIN
      EXECUTE IMMEDIATE 'SELECT cache_lobs + nocache_lobs + abstract_lobs FROM v$temporary_lobs WHERE sid = SYS_CONTEXT(''USERENV'', ''SID'')' INTO n;
      RETURN n;
    END;

    -- a template whose image resource has p_n bytes and whose body reads note: a FIELD (p_kind F), a SECTION on the
    -- string (S), or an IMAGE tag on logo (I)
    FUNCTION tpl(p_n NUMBER, p_kind CHAR) RETURN rad_pdf_ri.t_ri IS
      l_r rad_pdf_ri.t_ri;
      l_b BLOB;
      g3  rad_pdf_ri.t_id;
    BEGIN
      DBMS_LOB.CREATETEMPORARY(l_b, TRUE);
      WHILE DBMS_LOB.GETLENGTH(l_b) + 32000 <= p_n LOOP DBMS_LOB.WRITEAPPEND(l_b, 32000, l_raw); END LOOP;
      IF p_n - DBMS_LOB.GETLENGTH(l_b) > 0 THEN
        DBMS_LOB.WRITEAPPEND(l_b, p_n - DBMS_LOB.GETLENGTH(l_b), UTL_RAW.SUBSTR(l_raw, 1, p_n - DBMS_LOB.GETLENGTH(l_b)));
      END IF;
      l_r := rad_pdf_ri.new_ri;
      x := rad_pdf_ri.section(l_r, 595.3, 841.9, 'P', 56.7, 56.7, 56.7, 56.7, 36, 36, 'N');
      x := rad_pdf_ri.add_image(l_r, l_b, 'PNG', 1, 1);
      DBMS_LOB.FREETEMPORARY(l_b);
      IF p_kind = 'S' THEN
        g3 := rad_pdf_ri.block_region(l_r, rad_pdf_ri.zone(l_r, 'body'), 'SECTION', NULL, 'note');
        p := rad_pdf_ri.paragraph(l_r, g3, pf); x := rad_pdf_ri.run(l_r, p, 'shown', f);
      ELSE
        p := rad_pdf_ri.paragraph(l_r, rad_pdf_ri.zone(l_r, 'body'), pf);
        x := rad_pdf_ri.tag(l_r, p, CASE p_kind WHEN 'F' THEN 'FIELD' ELSE 'IMAGE' END, NULL, CASE p_kind WHEN 'F' THEN 'note' ELSE 'logo' END, f);
      END IF;
      rad_pdf_ri.seal(l_r);
      RETURN l_r;
    END;
  BEGIN
    l_d := '{"note":"' || RPAD('n', 1000, 'n') || '"}';
    l_jb := LENGTHB(l_d);
    -- the reservation of a text read is the data's size as a bound, at 2 bytes per character (a CLOB in UCS-2)
    t := tpl(c_cap - 2 * l_jb + 1, 'F');
    assert_ok(merge_refused(t, s11, l_d, rad_pdf_merge.c_err_budget, '[PDF_BUDGET] note: its text would exceed%'),
              'R3: a FIELD of 1000 characters near the cap refused BEFORE its CLOB is read (codex-050)');
    rad_pdf_ri.free(t);
    t := tpl(c_cap - 2 * l_jb, 'F');
    q := rad_pdf_merge.merge(t, s11, l_d);
    assert_ok(show(q) = '|' || RPAD('n', 1000, 'n'), 'R3: the same FIELD with room for its bound accepted (the boundary)');
    rad_pdf_ri.free(q); rad_pdf_ri.free(t);
    t := tpl(c_cap - 2 * l_jb + 1, 'S');
    assert_ok(merge_refused(t, s11, l_d, rad_pdf_merge.c_err_budget, '[PDF_BUDGET] note: its text would exceed%'),
              'R3: a SECTION on a string reads it through the same reservation');
    rad_pdf_ri.free(t);
    l_d := '{"logo":{"source":"' || RPAD('U', 4001, 'U') || '","url":"' || c_png || '"}}';
    l_jb := LENGTHB(l_d);
    t := tpl(c_cap - 2 * l_jb + 1, 'I');
    assert_ok(merge_refused(t, s11, l_d, rad_pdf_merge.c_err_budget, '[PDF_BUDGET] logo.source: its text would exceed%'),
              'R3: a long IMAGE member near the cap refused before its CLOB is read');
    rad_pdf_ri.free(t);
    t := tpl(c_cap - 2 * l_jb, 'I');
    assert_ok(merge_refused(t, s11, l_d, rad_pdf_merge.c_err_data, '[PRT_DATA] logo.source: too long (4001 characters)'),
              'R3: with room for its bound, the same member refused as data (too long), with its path');
    rad_pdf_ri.free(t);
    -- the template built once (a record returned by a function copies its LOBs: the test's own temporaries), then only
    -- the merge measured: a warm-up, then five refusals
    l_d := '{"note":"' || RPAD('n', 1000, 'n') || '"}';
    t := tpl(c_cap - 2 * LENGTHB(l_d) + 1, 'F');
    FOR k IN 0 .. 5 LOOP
      IF k = 1 THEN l_n0 := tmp_lobs; END IF;
      IF merge_refused(t, s11, l_d, rad_pdf_merge.c_err_budget, '[PDF_BUDGET] note: its text would exceed%') THEN NULL; END IF;
    END LOOP;
    rad_pdf_ri.free(t);
    assert_ok(tmp_lobs <= l_n0, 'R3: five refusals of a text read leave no temporary LOB (' || tmp_lobs || ' <= ' || l_n0 || ')');
    -- R6: an image stream made of empty IDAT chunks
    assert_ok(data_refused(s11, '{"unused":{"source":"URL","url":"data:image/png' || CHR(59)
                           || 'base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAElEQVQ1rwYeAAAAAElFTkSuQmCC"}}',
                           '[PRT_DATA] unused: not a valid PNG image%IDAT data is empty%'),
              'R6: a PNG whose only IDAT is empty refused (codex-050 fixture), for an IMAGE no tag uses');
    q := rad_pdf_merge.merge(one_tag('IMAGE', NULL, 'logo'), s11, '{"logo":{"source":"URL","url":"data:image/png' || CHR(59) || 'base64,'
           || TRANSLATE(UTL_RAW.CAST_TO_VARCHAR2(UTL_ENCODE.BASE64_ENCODE(HEXTORAW(
              '89504E470D0A1A0A0000000D4948445200000001000000010802000000907753DE' || '0000000049444154' || '35AF061E'
              || '0000000C4944415408D763F8CFC000000301010018DD8DB00000000049454E44AE426082'))), 'x' || CHR(13) || CHR(10), 'x') || '"}}');
    assert_ok(q.images.COUNT = 1, 'R6: an empty IDAT followed by the data accepted (the standard allows empty chunks)');
    rad_pdf_ri.free(q);
  END;

  DBMS_OUTPUT.PUT_LINE('Phase 24 merge: ' || l_pass || ' passed, 0 failed.');
END;
/
