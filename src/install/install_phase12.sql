-- install_phase12.sql — Phase 12: v1.6.0 features
--   rad_pdf_barcode (QR + Code128/EAN-13/Code39)
--   bookmarks / document outline (rad_pdf_canvas + rad_pdf_layout hook)
--
-- Used by install.sql for a fresh install (runs after phase 9, BEFORE
-- phase 8 — the facade body references rad_pdf_template and
-- rad_pdf_barcode) AND as the complete UPGRADE script for an existing
-- v1.5.x installation.
--
-- Upgrade note: recompiling rad_pdf_types (t_flowable gains the bookmark
-- field) invalidates dependents not recompiled here (serial, fonts, images,
-- template, ...); Oracle revalidates them automatically on first use since
-- their source is unchanged.
--
-- Working directory must be src/ when running in SQL*Plus:
--   SQL> @@install/install_phase12.sql

PROMPT === Phase 12 v1.6.0 (barcode + bookmarks) ===

PROMPT --- rad_pdf_types (adds c_err_barcode + t_flowable.bookmark)
@@../rad_pdf_types.pks
SHOW ERRORS PACKAGE rad_pdf_types

PROMPT --- rad_pdf_canvas spec (adds add_bookmark, write_outline_objects)
@@../rad_pdf_canvas.pks
SHOW ERRORS PACKAGE rad_pdf_canvas

PROMPT --- rad_pdf_canvas body (bookmark state + outline tree writer)
@@../rad_pdf_canvas.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_canvas

PROMPT --- rad_pdf_layout spec (heading gains p_bookmark) — spec-first with table
@@../rad_pdf_layout.pks
SHOW ERRORS PACKAGE rad_pdf_layout

PROMPT --- rad_pdf_table spec (recompiled: circular dependency with layout)
@@../rad_pdf_table.pks
SHOW ERRORS PACKAGE rad_pdf_table

PROMPT --- rad_pdf_layout body (bookmark hook in the heading render pass)
@@../rad_pdf_layout.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_layout

PROMPT --- rad_pdf_table body (recompiled: circular dependency with layout)
@@../rad_pdf_table.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_table

PROMPT --- rad_pdf_barcode spec
@@../rad_pdf_barcode.pks
SHOW ERRORS PACKAGE rad_pdf_barcode

PROMPT --- rad_pdf_barcode body
@@../rad_pdf_barcode.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_barcode

PROMPT --- rad_pdf spec (adds qrcode, barcode, add_bookmark, heading p_bookmark)
@@../rad_pdf.pks
SHOW ERRORS PACKAGE rad_pdf

PROMPT --- rad_pdf body
@@../rad_pdf.pkb
SHOW ERRORS PACKAGE BODY rad_pdf

PROMPT === Phase 12 install complete ===
