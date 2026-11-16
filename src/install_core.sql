-- install_core.sql — the importable core of RAD_PDF only (src/import_core.lst; middleware-docs 96a §1b).
-- Working directory src/. Compiled with PLSQL_CCFLAGS='rad_pdf_core:TRUE': rad_pdf_canvas holds no page procedure in a
-- string (E6). The product installs with install.sql; this script is the import's view, checked by
-- tests/import/check_core.py.
SET DEFINE OFF
SET SQLBLANKLINES ON
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
ALTER SESSION SET PLSQL_CCFLAGS = 'rad_pdf_core:TRUE';
@@rad_pdf_types.pks
@@rad_pdf_img_data.sql
@@rad_pdf_img_decoder.sql
@@rad_pdf_jpeg_decoder.sql
@@rad_pdf_png_decoder.sql
@@rad_pdf_gif_decoder.sql
@@rad_pdf_units.pks
@@rad_pdf_codec.pks
@@rad_pdf_styles.pks
@@rad_pdf_ctx.pks
@@rad_pdf_serial.pks
@@rad_pdf_fonts.pks
@@rad_pdf_images.pks
@@rad_pdf_text.pks
@@rad_pdf_canvas.pks
@@rad_pdf_doc.pks
@@rad_pdf_ri.pks
@@rad_pdf_merge.pks
@@rad_pdf_pager.pks
@@rad_pdf_units.pkb
@@rad_pdf_codec.pkb
@@rad_pdf_styles.pkb
@@rad_pdf_serial.pkb
@@rad_pdf_fonts.pkb
@@rad_pdf_images.pkb
@@rad_pdf_text.pkb
@@rad_pdf_canvas.pkb
@@rad_pdf_ctx.pkb
@@rad_pdf_doc.pkb
@@rad_pdf_ri.pkb
@@rad_pdf_merge.pkb
@@rad_pdf_pager.pkb

ALTER SESSION SET PLSQL_CCFLAGS = '';
DECLARE
  l_errors PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_errors FROM user_errors
   WHERE (name = 'RAD_PDF' OR name LIKE 'RAD\_PDF\_%' ESCAPE '\') AND attribute = 'ERROR';
  IF l_errors > 0 THEN
    RAISE_APPLICATION_ERROR(-20800,'RAD_PDF core compilation failed; inspect USER_ERRORS');
  END IF;
END;
/
