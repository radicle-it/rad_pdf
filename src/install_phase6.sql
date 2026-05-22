-- install_phase6.sql — compile Phase 6 rad_pdf_canvas + update rad_pdf_ctx.pkb
-- Run after install_phase5.sql.
-- Requires all Phase 1-5 objects already compiled.
-- Note rad_pdf_ctx.pkb is compiled once at the end of the final phase.
--   When Phase 7 is added, move @@rad_pdf_ctx.pkb there and add rad_pdf_layout._close_doc.

PROMPT === Phase 6 rad_pdf_canvas ===

PROMPT --- rad_pdf_canvas spec
@@rad_pdf_canvas.pks
SHOW ERRORS PACKAGE rad_pdf_canvas

PROMPT --- rad_pdf_canvas body
@@rad_pdf_canvas.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_canvas

PROMPT --- rad_pdf_ctx body (adds rad_pdf_canvas._close_doc call)
@@rad_pdf_ctx.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_ctx

PROMPT === Phase 6 install complete ===
