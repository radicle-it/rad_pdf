-- install_phase10.sql — UPGRADE script: v1.3.x -> v1.4.0 (watermark)
--
-- USE THIS FILE only when upgrading an existing v1.3.x installation.
-- For a fresh install use install.sql instead (phases 6 and 8 already
-- include the updated rad_pdf_canvas and rad_pdf source).
--
-- Working directory must be src/ when running in SQL*Plus:
--   SQL> @@install/install_phase10.sql

PROMPT ================================================================
PROMPT  Phase 10 - Watermark (v1.4.0)
PROMPT  Recompiles: rad_pdf_types, rad_pdf_canvas (spec + body),
PROMPT              rad_pdf (spec + body)
PROMPT ================================================================

PROMPT -- rad_pdf_types (bumps c_version to 1.4.0)
@@../rad_pdf_types.pks
SHOW ERRORS PACKAGE rad_pdf_types

PROMPT -- rad_pdf_canvas spec (adds set_watermark, set_watermark_image, clear_watermark)
@@../rad_pdf_canvas.pks
SHOW ERRORS PACKAGE rad_pdf_canvas

PROMPT -- rad_pdf_canvas body (g_watermarks state + implementation + write_page_objects)
@@../rad_pdf_canvas.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_canvas

PROMPT -- rad_pdf spec (adds three public procedure specs)
@@../rad_pdf.pks
SHOW ERRORS PACKAGE rad_pdf

PROMPT -- rad_pdf body (thin wrappers delegating to rad_pdf_canvas)
@@../rad_pdf.pkb
SHOW ERRORS PACKAGE BODY rad_pdf

PROMPT ================================================================
PROMPT  Phase 10 complete.
PROMPT  Run tests/phase11_watermark.sql to verify.
PROMPT ================================================================
