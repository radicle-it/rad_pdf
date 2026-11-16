-- phase22_doc_isolation.sql - documents of one session do not see each other (doc 96 E1, codex-034)
-- Run from repo root in SQL*Plus after src/install.sql.
--   1. a PRELOADED CID font used by two interleaved documents: each subset and ToUnicode map holds only the glyphs of
--      its document, and the second document survives the close of the first (A2);
--   2. derived template styles: two interleaved documents, a caller style named like the old derived names before
--      the derivation, a reserved name refused, the base redefined after a derivation, the documents closed in reverse
--      order; the caller's styles survive and the derived ones are dropped (A3, codex-034 R3);
--   3. close_doc of an unknown or closed handle is a no-op;
--   4. a closer that fails (fault injection: rad_pdf_doc body compiled with PLSQL_CCFLAGS='rad_pdf_test:TRUE' for this
--      part only, then compiled again without): the first error is reported with its package within 2048 bytes, the
--      later closers still run, the handle is invalid, another open document and a new one are not affected.
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
  l_font BLOB := TO_BLOB(HEXTORAW(
'00010000000A0080000300204F532F32458464A00000012800000060636D617003F9226C0000019C00000052676C7966ACBC3FAD00000204000000A8'
    ||'686561642F6F1D16000000AC0000003668686561051601F6000000E400000024686D74780258000000000188000000126C6F636100C0009C000001F0'
    ||'000000126D617870000A000500000108000000206E616D65EB442BC3000002AC00000108706F73741A16E46C000003B40000003D0001000000010000'
    ||'3F20AB8C5F0F3CF5000103E800000000E7016CBD00000000E7016CBD00320000022602BC000000030002000000000000000100000320FF3800000258'
    ||'0000006401F4000100000000000000000000000000000001000100000008000300010000000000020000000000000000000000000000000000030258'
    ||'0190000500040000000000000000000000000000000000000000000000000000000000000000000000830000000200000000000000003F3F3F3F0000'
    ||'002020AC0320FF380000032000C800000000000000000000000000000020000002580000000000000000000000000000000000000000000100030001'
    ||'0000000C000400460000000C0008000200040020004300E8039120ACFFFF00000020004100E8039120ACFFFFFFE10000FF1EFC76DF5900010000000A'
    ||'000000000000000000020004000300000000000C000C001800240030003C004800540000000100320000022602BC0002000033131332FAFA02BCFD44'
    ||'000100320000022602BC0002000033131332FAFA02BCFD44000100320000022602BC0002000033131332FAFA02BCFD44000100320000022602BC0002'
    ||'000033131332FAFA02BCFD44000100320000022602BC0002000033131332FAFA02BCFD44000100320000022602BC0002000033131332FAFA02BCFD44'
    ||'000100320000022602BC0002000033131332FAFA02BCFD440000000A007E0001000000000001000D000000010000000000020007000D000100000000'
    ||'0003000F00140001000000000004000D00000001000000000006000B00230003000104090001001A002E0003000104090002000E0048000300010409'
    ||'0003001E00560003000104090004001A002E000300010409000600160074524144205465737420466F6E74526567756C617252414420546573742046'
    ||'6F6E74203152414454657374466F6E740052004100440020005400650073007400200046006F006E00740052006500670075006C0061007200520041'
    ||'00440020005400650073007400200046006F006E00740020003100520041004400540065007300740046006F006E0074000200000000000000000000'
    ||'0000000000000000000000000000000000000000000800000003002400260025010200710103044575726F05416C706861000000'));
  l_a     rad_pdf_types.t_doc_handle;
  l_b     rad_pdf_types.t_doc_handle;
  l_idx   PLS_INTEGER;
  l_pdf_a BLOB;
  l_pdf_b BLOB;
  l_probe VARCHAR2(100);
  l_n0    PLS_INTEGER;
  l_fmt   rad_pdf_types.t_cell_format;
  l_raised BOOLEAN;
  l_pass  PLS_INTEGER := 0;

  PROCEDURE assert_ok(p_ok BOOLEAN, p_message VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_ok, FALSE) THEN RAISE_APPLICATION_ERROR(-20999, 'FAIL ' || p_message); END IF;
    l_pass := l_pass + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  ' || p_message);
  END;
  FUNCTION has(p_pdf BLOB, p_text VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN DBMS_LOB.INSTR(p_pdf, UTL_RAW.CAST_TO_RAW(p_text)) > 0;
  END;
BEGIN
  rad_pdf_styles.load_defaults;

  -- 1. a preloaded CID font, two interleaved documents
  l_idx := rad_pdf_fonts.preload_ttf(l_font, p_encoding => 'CID', p_embed => TRUE);
  l_a := rad_pdf.new_document(p_compress_pages => FALSE);
  l_b := rad_pdf.new_document(p_compress_pages => FALSE);
  rad_pdf_canvas.set_font(l_a, l_idx, 12);
  rad_pdf_canvas.write_text(l_a, 'AB', 50, 700);
  rad_pdf_canvas.set_font(l_b, l_idx, 12);
  rad_pdf_canvas.write_text(l_b, UNISTR('C\20AC'), 50, 700);
  l_pdf_a := rad_pdf.finalize(l_a);
  assert_ok(has(l_pdf_a, '<0002> <0041>'), 'CID: document A maps its glyph A');
  assert_ok(NOT has(l_pdf_a, '<0005> <20AC>'), 'CID: document A has no glyph of document B (euro)');
  l_pdf_b := rad_pdf.finalize(l_b);
  assert_ok(has(l_pdf_b, '<0005> <20AC>'), 'CID: document B, finalized after A was closed, maps its euro');
  assert_ok(NOT has(l_pdf_b, '<0002> <0041>'), 'CID: document B has no glyph of document A');
  assert_ok(rad_pdf_fonts.font_exists(l_idx), 'CID: the preloaded font survives both documents');
  DBMS_LOB.FREETEMPORARY(l_pdf_a);
  DBMS_LOB.FREETEMPORARY(l_pdf_b);

  -- 2. derived template styles
  l_probe := rad_pdf_styles.define_derived(rad_pdf_styles.get('body'));   -- the counter before the documents
  l_n0 := TO_NUMBER(SUBSTR(l_probe, 2));
  rad_pdf_styles.drop_style(l_probe);
  l_a := rad_pdf.new_document(p_compress_pages => FALSE);
  l_b := rad_pdf.new_document(p_compress_pages => FALSE);
  -- a caller style with the name the derivation used before codex-034 R3, defined BEFORE the derivation
  rad_pdf_styles.define('inline_' || l_a || '_1', p_font_color => '00FF00');
  rad_pdf_template.render(l_a, '<p><b>BOLD_A</b></p>');
  rad_pdf_template.render(l_b, '<p><i>ITALIC_B</i></p>');
  assert_ok(rad_pdf_styles.exists_style('#' || (l_n0 + 1)) AND rad_pdf_styles.exists_style('#' || (l_n0 + 2)),
            'styles: the two derivations are in the reserved namespace');
  assert_ok(rad_pdf_styles.get('inline_' || l_a || '_1').font_color = '00FF00',
            'styles: the caller style is not overwritten by a derivation');
  l_raised := FALSE;
  BEGIN
    rad_pdf_styles.define('#' || (l_n0 + 1), p_font_color => '0000FF');
  EXCEPTION WHEN OTHERS THEN
    l_raised := SQLCODE = rad_pdf_types.c_err_validation;
  END;
  assert_ok(l_raised, 'styles: a caller cannot define a reserved name (a later definition cannot overwrite)');
  assert_ok(rad_pdf_styles.get('#' || (l_n0 + 1)).font_style = 'B', 'styles: the derived style is unchanged');
  -- the base redefined after a derivation: the next derivation follows the new base
  rad_pdf_styles.define('body', p_font_color => 'FF0000');
  rad_pdf_template.render(l_b, '<p><i>ITALIC_B2</i></p>');
  -- closed in reverse order: B first
  l_pdf_b := rad_pdf.finalize(l_b);
  assert_ok(has(l_pdf_b, '1 0 0 rg'), 'styles: the derivation after the redefinition takes the new base colour');
  assert_ok(has(l_pdf_b, 'Helvetica-Oblique'), 'styles: document B renders its italic');
  assert_ok(NOT rad_pdf_styles.exists_style('#' || (l_n0 + 2)), 'styles: B''s derived style dropped at its close');
  assert_ok(rad_pdf_styles.exists_style('#' || (l_n0 + 1)), 'styles: A''s derived style survives B''s close');
  l_pdf_a := rad_pdf.finalize(l_a);
  assert_ok(has(l_pdf_a, 'Helvetica-Bold'), 'styles: document A renders its bold after B was closed');
  assert_ok(NOT rad_pdf_styles.exists_style('#' || (l_n0 + 1)), 'styles: A''s derived style dropped at its close');
  assert_ok(rad_pdf_styles.get('inline_' || l_a || '_1').font_color = '00FF00',
            'styles: the caller style survives both closes');
  DBMS_LOB.FREETEMPORARY(l_pdf_a);
  DBMS_LOB.FREETEMPORARY(l_pdf_b);

  -- 3. close_doc of a closed or unknown handle
  rad_pdf_doc.close_doc(l_a);
  rad_pdf_doc.close_doc(-1);
  assert_ok(NOT rad_pdf_ctx.is_valid(l_a), 'close_doc of a closed or unknown handle is a no-op');

  rad_pdf_styles.clear_all;
  DBMS_OUTPUT.PUT_LINE('Phase 22: ' || l_pass || ' passed, 0 failed.');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_a); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN rad_pdf.close_document(l_b); EXCEPTION WHEN OTHERS THEN NULL; END;
  rad_pdf_styles.clear_all;
  RAISE;
END;
/

-- 4. a closer that fails
ALTER PACKAGE rad_pdf_doc COMPILE BODY PLSQL_CCFLAGS = 'rad_pdf_test:TRUE';
VARIABLE fault_result VARCHAR2(4000)
DECLARE
  l_a    rad_pdf_types.t_doc_handle;
  l_b    rad_pdf_types.t_doc_handle;
  l_c    rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_err  VARCHAR2(4000);
  l_code PLS_INTEGER;
  l_pass PLS_INTEGER := 0;
  e_fail EXCEPTION;

  PROCEDURE assert_ok(p_ok BOOLEAN, p_message VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_ok, FALSE) THEN :fault_result := 'FAIL ' || p_message; RAISE e_fail; END IF;
    l_pass := l_pass + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  ' || p_message);
  END;
BEGIN
  :fault_result := 'not run';
  l_a := rad_pdf.new_document(p_compress_pages => FALSE);
  rad_pdf.write(l_a, 'TEXT_A');
  l_b := rad_pdf.new_document(p_compress_pages => FALSE);
  rad_pdf.write(l_b, 'TEXT_B');
  rad_pdf_layout.render(l_a);
  assert_ok(rad_pdf_serial.page_count(l_a) = 1, 'fault: document A has its page before the close');
  DBMS_APPLICATION_INFO.SET_CLIENT_INFO('rad_pdf_fault=rad_pdf_layout');
  BEGIN
    rad_pdf_doc.close_doc(l_a);
  EXCEPTION WHEN OTHERS THEN
    l_code := SQLCODE;
    l_err  := DBMS_UTILITY.FORMAT_ERROR_STACK;   -- the whole message (SQLERRM stops at 512 bytes)
  END;
  DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL);
  assert_ok(l_code = rad_pdf_types.c_err_internal, 'fault: close_doc raises c_err_internal');
  assert_ok(INSTR(l_err, 'Document cleanup: rad_pdf_layout: ORA-20990: injected fault in rad_pdf_layout') > 0,
            'fault: the message names the failing package, its code and its message');
  assert_ok(LENGTHB(l_err) > 1500 AND LENGTHB(l_err) <= 2048 + LENGTHB('ORA-20800: ') + 1,
            'fault: the long multibyte message is carried, within 2048 bytes (' || LENGTHB(l_err) || ')');
  assert_ok(NOT rad_pdf_ctx.is_valid(l_a), 'fault: the handle is invalid after the failed close');
  assert_ok(rad_pdf_serial.page_count(l_a) = 0, 'fault: the closers after the failing one ran (serial state gone)');
  rad_pdf_doc.close_doc(l_a);
  assert_ok(TRUE, 'fault: a second close of the handle is a no-op');
  l_pdf := rad_pdf.finalize(l_b);
  assert_ok(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('TEXT_B')) > 0
            AND DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('TEXT_A')) = 0,
            'fault: the other open document finalizes with its own content only');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  l_c := rad_pdf.new_document(p_compress_pages => FALSE);
  rad_pdf.write(l_c, 'TEXT_C');
  l_pdf := rad_pdf.finalize(l_c);
  assert_ok(l_c > l_a AND DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('TEXT_C')) > 0
            AND DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('TEXT_A')) = 0,
            'fault: a new document gets a new handle and none of the leftover state');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  :fault_result := 'OK ' || l_pass;
EXCEPTION
  WHEN e_fail THEN
    DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL);
  WHEN OTHERS THEN
    DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL);
    :fault_result := 'FAIL ' || SQLERRM;
END;
/
ALTER PACKAGE rad_pdf_doc COMPILE BODY PLSQL_CCFLAGS = '';
BEGIN
  IF :fault_result NOT LIKE 'OK%' THEN RAISE_APPLICATION_ERROR(-20999, :fault_result); END IF;
  DBMS_OUTPUT.PUT_LINE('Phase 22 fault injection: ' || SUBSTR(:fault_result, 4) || ' passed, 0 failed.');
END;
/
