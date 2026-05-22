-- install_phase3.sql — compile Phase 3 rad_pdf_serial
-- Run after install_phase2.sql.
-- Requires all Phase 1 + Phase 2 objects already compiled.
-- Note rad_pdf_ctx.pkb is compiled once at the end of the final phase.

PROMPT === Phase 3 rad_pdf_serial ===

PROMPT --- rad_pdf_serial spec
@@rad_pdf_serial.pks
SHOW ERRORS PACKAGE rad_pdf_serial

PROMPT --- rad_pdf_serial body
@@rad_pdf_serial.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_serial

PROMPT === Phase 3 complete ===
