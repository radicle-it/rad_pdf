-- install_phase4.sql — compile Phase 4 rad_pdf_fonts
-- Run after install_phase3.sql.
-- Requires all Phase 1 + Phase 2 + Phase 3 objects already compiled.
-- Note rad_pdf_ctx.pkb is compiled once at the end of the final phase.

PROMPT === Phase 4 rad_pdf_fonts ===

PROMPT --- rad_pdf_fonts spec
@@rad_pdf_fonts.pks
SHOW ERRORS PACKAGE rad_pdf_fonts

PROMPT --- rad_pdf_fonts body
@@rad_pdf_fonts.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_fonts

PROMPT === Phase 4 complete ===
