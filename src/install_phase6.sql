-- install_phase6.sql — compile Phase 6 rad_pdf_canvas
-- Run after install_phase5.sql.
-- Requires all Phase 1-5 objects already compiled.
-- rad_pdf_ctx.pkb is compiled at Phase 7 (after rad_pdf_layout and rad_pdf_table exist).

PROMPT === Phase 6 rad_pdf_canvas ===

PROMPT --- rad_pdf_canvas spec
@@rad_pdf_canvas.pks
SHOW ERRORS PACKAGE rad_pdf_canvas

PROMPT --- rad_pdf_canvas body
@@rad_pdf_canvas.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_canvas

PROMPT === Phase 6 install complete ===
