-- install_phase12.sql — Phase 12: rad_pdf_barcode (QR code, v1.6.0)
--
-- Used by install.sql for a fresh install (runs after phase 9) AND as an
-- UPGRADE script for an existing v1.5.x installation: rad_pdf_barcode only
-- depends on rad_pdf_types, rad_pdf_units, rad_pdf_ctx and rad_pdf_canvas,
-- all present since v1.5.0.
--
-- Working directory must be src/ when running in SQL*Plus:
--   SQL> @@install/install_phase12.sql

PROMPT === Phase 12 rad_pdf_barcode (QR code) ===

PROMPT --- rad_pdf_types (adds c_err_barcode)
@@../rad_pdf_types.pks
SHOW ERRORS PACKAGE rad_pdf_types

PROMPT --- rad_pdf_barcode spec
@@../rad_pdf_barcode.pks
SHOW ERRORS PACKAGE rad_pdf_barcode

PROMPT --- rad_pdf_barcode body
@@../rad_pdf_barcode.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_barcode

PROMPT --- rad_pdf spec (adds qrcode shortcut)
@@../rad_pdf.pks
SHOW ERRORS PACKAGE rad_pdf

PROMPT --- rad_pdf body
@@../rad_pdf.pkb
SHOW ERRORS PACKAGE BODY rad_pdf

PROMPT === Phase 12 install complete ===
