-- install_phase8.sql — compile Phase 8 rad_pdf (public facade)
-- Run after install_phase7.sql.
-- Requires all Phase 1-7 objects already compiled.

PROMPT === Phase 8 rad_pdf facade ===

PROMPT --- rad_pdf spec
@@../rad_pdf.pks
SHOW ERRORS PACKAGE rad_pdf

PROMPT --- rad_pdf body
@@../rad_pdf.pkb
SHOW ERRORS PACKAGE BODY rad_pdf

PROMPT === Phase 8 install complete ===
