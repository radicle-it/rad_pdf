-- install.sql — Full RAD_PDF suite installer.
-- Working directory must be src/ when running in SQL*Plus
--   SQL> @install.sql
-- Requires Oracle 19c+. Run as the schema owner.

PROMPT ================================================================
PROMPT  RAD_PDF v1.7.0 — Full Suite Installer
PROMPT  Oracle 19c+  |  Run as the target schema owner
PROMPT  Working directory src/
PROMPT ================================================================
PROMPT

SET DEFINE OFF
SET SQLBLANKLINES ON
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

@@rad_pdf_types.pks
@@rad_pdf_img_data.sql
@@rad_pdf_img_decoder.sql
@@rad_pdf_jpeg_decoder.sql
@@rad_pdf_png_decoder.sql
@@rad_pdf_gif_decoder.sql

-- Declare every interface before compiling implementations.
@@rad_pdf_units.pks
@@rad_pdf_codec.pks
@@rad_pdf_styles.pks
@@rad_pdf_ctx.pks
@@rad_pdf_serial.pks
@@rad_pdf_fonts.pks
@@rad_pdf_images.pks
@@rad_pdf_text.pks
@@rad_pdf_canvas.pks
@@rad_pdf_swiss.pks
@@rad_pdf_layout.pks
@@rad_pdf_table.pks
@@rad_pdf_template.pks
@@rad_pdf_doc.pks
@@rad_pdf_barcode.pks
@@rad_pdf_chart.pks
@@rad_pdf.pks
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
@@rad_pdf_layout.pkb
@@rad_pdf_table.pkb
@@rad_pdf_template.pkb
@@rad_pdf_barcode.pkb
@@rad_pdf_swiss.pkb
@@rad_pdf_chart.pkb
@@rad_pdf_ctx.pkb
@@rad_pdf_doc.pkb
@@rad_pdf.pkb
@@rad_pdf_ri.pkb
@@rad_pdf_merge.pkb
@@rad_pdf_pager.pkb

DECLARE
  l_errors PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_errors FROM user_errors
   WHERE (name = 'RAD_PDF' OR name LIKE 'RAD\_PDF\_%' ESCAPE '\') AND attribute = 'ERROR';
  IF l_errors > 0 THEN
    RAISE_APPLICATION_ERROR(-20800,'RAD_PDF compilation failed; inspect USER_ERRORS');
  END IF;
END;
/

PROMPT ================================================================
PROMPT  Install complete.
PROMPT
PROMPT  Run acceptance tests (from repo root)
PROMPT    @tests/phase9_integration.sql    canvas API + core packages
PROMPT    @tests/phase10_template.sql      template engine
PROMPT    @tests/phase11_watermark.sql     watermark (v1.4.0)
PROMPT    @tests/phase12_autowidth.sql     auto-width columns
PROMPT    @tests/phase12_canvas_ext.sql    line-dash + justification (v1.5.0)
PROMPT    @tests/phase13_barcode.sql       QR + 1D barcodes (v1.6.0)
PROMPT    @tests/phase14_bookmark.sql      bookmarks / outline (v1.6.0)
PROMPT    @tests/phase15_png.sql           PNG alpha / flate (v1.6.0)
PROMPT    @tests/phase16_chart.sql         bar / line / pie charts (v1.7.0)
PROMPT    @tests/phase17_pdfa.sql          PDF/A-2b conformance (v1.7.0)
PROMPT
PROMPT    @tests/phase18_robustness.sql      content / pagination / lifetime regressions
PROMPT    @tests/phase19_fonts_unicode.sql   cmap / Unicode / embedded-font regressions
PROMPT    @tests/phase20_text_pipeline.sql   prepared text / buffering / ownership
PROMPT    @tests/phase21_swiss_qr_bill.sql   Swiss payload / validation / layout
PROMPT
PROMPT  Canvas API     docs/sample01.sql .. sample10.sql
PROMPT  Template engine docs/sample11.sql, docs/sample12.sql
PROMPT  APEX examples  docs/apex/apex_sample00.sql .. apex_sample08.sql
PROMPT                  docs/apex/apex_template_01.sql .. apex_template_14.sql
PROMPT
PROMPT  Reference docs
PROMPT    docs/README.md            full user guide + API reference
PROMPT    docs/TEMPLATE_GUIDE.md    template engine tag catalogue and patterns
PROMPT    docs/apex/README.md       APEX integration guide
PROMPT ================================================================
