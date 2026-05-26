-- phase1_foundation.sql - acceptance tests for Phase 1
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  l_ok   PLS_INTEGER := 0;
  l_fail PLS_INTEGER := 0;

  PROCEDURE ok(p_label IN VARCHAR2, p_cond IN BOOLEAN) IS
  BEGIN
    IF p_cond THEN
      DBMS_OUTPUT.PUT_LINE('PASS  ' || p_label); l_ok := l_ok + 1;
    ELSE
      DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_label); l_fail := l_fail + 1;
    END IF;
  END;

  PROCEDURE ok(p_label IN VARCHAR2, p_got IN VARCHAR2, p_exp IN VARCHAR2) IS
  BEGIN
    ok(p_label, NVL(p_got,'<null>') = NVL(p_exp,'<null>'));
  END;

  PROCEDURE ok(p_label IN VARCHAR2, p_got IN NUMBER, p_exp IN NUMBER) IS
  BEGIN
    ok(p_label, p_got = p_exp);
  END;

BEGIN
  -- =========================================================================
  -- rad_pdf_codec
  -- =========================================================================
  ok('fmt 2dp',       rad_pdf_codec.fmt(3.14159, 2),   '3.14');
  ok('fmt 0',         rad_pdf_codec.fmt(0),             '0');
  ok('fmt negative',  rad_pdf_codec.fmt(-1.5),          '-1.5');

  ok('rgb_to_pdf red',    rad_pdf_codec.rgb_to_pdf('ff0000'), '1 0 0');
  ok('rgb_to_pdf orange', rad_pdf_codec.rgb_to_pdf('ff8000'), '1 0.502 0');
  ok('rgb_to_pdf black',  rad_pdf_codec.rgb_to_pdf('000000'), '0 0 0');
  ok('rgb_to_pdf white',  rad_pdf_codec.rgb_to_pdf('ffffff'), '1 1 1');

  ok('escape backslash', rad_pdf_codec.escape_pdf_str('a\b'),     'a\\b');
  ok('escape parens',    rad_pdf_codec.escape_pdf_str('a(b)c'),   'a\(b\)c');
  ok('escape combined',  rad_pdf_codec.escape_pdf_str('a(b)c\d'), 'a\(b\)c\\d');
  ok('escape null',      rad_pdf_codec.escape_pdf_str(NULL) IS NULL);

  DECLARE l_b BLOB; BEGIN
    DBMS_LOB.CREATETEMPORARY(l_b, TRUE);
    ok('adler32 empty', rad_pdf_codec.adler32(l_b), '00000001');
    DBMS_LOB.FREETEMPORARY(l_b);
  END;

  DECLARE l_b BLOB; l_h VARCHAR2(64); BEGIN
    DBMS_LOB.CREATETEMPORARY(l_b, TRUE);
    DBMS_LOB.APPEND(l_b, UTL_RAW.CAST_TO_RAW('hello'));
    l_h := rad_pdf_codec.sha256_hex(l_b);
    ok('sha256 length', LENGTH(l_h) = 64);
    ok('sha256 value',  l_h,
       '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
    DBMS_LOB.FREETEMPORARY(l_b);
  END;

  DECLARE l_src BLOB; l_comp BLOB; BEGIN
    DBMS_LOB.CREATETEMPORARY(l_src, TRUE);
    DBMS_LOB.APPEND(l_src, UTL_RAW.CAST_TO_RAW(RPAD('A', 100, 'A')));
    l_comp := rad_pdf_codec.flate_encode(l_src);
    ok('flate not null',       DBMS_LOB.GETLENGTH(l_comp) > 0);
    ok('flate no zlib header', UTL_RAW.SUBSTR(DBMS_LOB.SUBSTR(l_comp, 2, 1), 1, 1)
                               != HEXTORAW('78'));
    DBMS_LOB.FREETEMPORARY(l_src);
    DBMS_LOB.FREETEMPORARY(l_comp);
  END;

  -- =========================================================================
  -- rad_pdf_styles
  -- =========================================================================
  DECLARE l_s rad_pdf_types.t_cell_format; BEGIN
    l_s := rad_pdf_styles.get('default');
    ok('default font_size',  l_s.font_size,  10);
    ok('default font_color', l_s.font_color, '000000');
    ok('default back_color', l_s.back_color, 'ffffff');
  END;

  DECLARE l_s rad_pdf_types.t_cell_format; BEGIN
    l_s := rad_pdf_styles.get('h1');
    ok('h1 font_size',  l_s.font_size,  18);
    ok('h1 font_style', l_s.font_style, 'B');
  END;

  DECLARE l_s rad_pdf_types.t_cell_format; BEGIN
    rad_pdf_styles.define('test_style', p_font_size => 14, p_align_h => 'R');
    l_s := rad_pdf_styles.get('test_style');
    ok('custom font_size',  l_s.font_size,  14);
    ok('custom align_h',    l_s.align_h,    'R');
    ok('custom font_name',  l_s.font_name,  'Helvetica');
    rad_pdf_styles.drop_style('test_style');
    ok('drop_style removes', NOT rad_pdf_styles.exists_style('test_style'));
  END;

  DECLARE l_s rad_pdf_types.t_cell_format; BEGIN
    l_s := rad_pdf_styles.get('nonexistent_xyz');
    ok('fallback font_size', l_s.font_size, 10);
  END;

  DECLARE l_cs rad_pdf_types.t_color_scheme; BEGIN
    l_cs := rad_pdf_styles.default_scheme;
    ok('scheme header_paper', l_cs.header_paper, '003366');
    ok('scheme header_ink',   l_cs.header_ink,   'ffffff');
    ok('scheme odd_paper',    l_cs.odd_paper,     'd0d0d0');
  END;

  -- =========================================================================
  -- rad_pdf_units
  -- =========================================================================
  ok('25.4mm = 72pt', ROUND(rad_pdf_units.to_pt(25.4, 'mm'), 3) = 72);
  ok('1in = 72pt',    rad_pdf_units.to_pt(1, 'in') = 72);
  ok('1pica = 12pt',  rad_pdf_units.to_pt(1, 'pica') = 12);
  ok('from_pt mm',    ROUND(rad_pdf_units.from_pt(72, 'mm'), 3) = 25.4);

  DECLARE l_t rad_pdf_types.t_page_template; BEGIN
    l_t := rad_pdf_units.default_page_template;
    ok('template format_name null', l_t.page_format_name IS NULL);
    ok('template page_width null',  l_t.page_width       IS NULL);
    ok('template margin_top null',  l_t.margin_top       IS NULL);
    ok('template n_columns',        l_t.n_columns = 1);
  END;

  DECLARE l_pf rad_pdf_types.t_page_format; BEGIN
    l_pf := rad_pdf_units.page_format('A4');
    ok('A4 width',  ROUND(l_pf.width,  3) = 595.276);
    ok('A4 height', ROUND(l_pf.height, 3) = 841.890);
  END;

  -- =========================================================================
  -- rad_pdf_types: t_page_template NULL scalars
  -- =========================================================================
  DECLARE l_t rad_pdf_types.t_page_template; BEGIN
    ok('t_page_template format null',  l_t.page_format_name IS NULL);
    ok('t_page_template margin null',  l_t.margin_left      IS NULL);
  END;

  -- =========================================================================
  -- Summary
  -- =========================================================================
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('Phase 1: ' || l_ok || ' passed, ' || l_fail || ' failed.');
  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Phase 1 FAILED: ' || l_fail || ' failure(s)');
  END IF;
END;
/
