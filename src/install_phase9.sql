-- install_phase9.sql — compile Phase 9 rad_pdf_template (template engine)
-- Run after install_phase8.sql.
-- Requires all Phase 1-8 objects already compiled.

PROMPT === Phase 9 rad_pdf_template ===

PROMPT --- rad_pdf_template spec
@@rad_pdf_template.pks
SHOW ERRORS PACKAGE rad_pdf_template

PROMPT --- rad_pdf_template body
@@rad_pdf_template.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_template

PROMPT === Phase 9 install complete ===
