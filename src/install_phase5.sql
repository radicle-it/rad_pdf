-- install_phase5.sql — compile Phase 5 (rad_pdf_images) into the target schema.
-- Run as the schema owner from SQL*Plus or SQL Developer.
-- Prerequisites Phase 1-4 must already be compiled.

PROMPT === Phase 5 rad_pdf_images ===

PROMPT --- rad_pdf_images spec
@@rad_pdf_images.pks
SHOW ERRORS PACKAGE rad_pdf_images

PROMPT --- rad_pdf_images body
@@rad_pdf_images.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_images

PROMPT === Phase 5 install complete ===
