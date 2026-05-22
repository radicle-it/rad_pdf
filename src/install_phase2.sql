-- install_phase2.sql — compile Phase 2 (schema types + rad_pdf_ctx)
-- Prerequisites: Phase 1 must be installed first (@@install_phase1.sql).

PROMPT === Phase 2 schema-level types ===
@@rad_pdf_img_data.sql
@@rad_pdf_img_decoder.sql
@@rad_pdf_jpeg_decoder.sql
@@rad_pdf_png_decoder.sql
@@rad_pdf_gif_decoder.sql

PROMPT === Phase 2 rad_pdf_ctx ===
@@rad_pdf_ctx.pks
@@rad_pdf_ctx.pkb

PROMPT === Phase 2 complete ===
