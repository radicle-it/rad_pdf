-- install_phase12.sql — Phase 12: v1.6.0 features
--   rad_pdf_barcode (QR + Code128/EAN-13/Code39)
--   bookmarks / document outline (rad_pdf_canvas + rad_pdf_layout hook)
--
-- Used by install.sql for a fresh install (runs after phase 9) AND as the
-- first half of the UPGRADE from a v1.5.x installation: run
-- install_phase13.sql immediately after (it compiles the facade, whose
-- source references both rad_pdf_barcode and rad_pdf_chart).
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

PROMPT --- rad_pdf_codec body (pure PL/SQL inflate + flate_encode zlib fix)
@@../rad_pdf_codec.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_codec

PROMPT --- rad_pdf_png_decoder (rejects interlaced PNG with a clear error)
@@../rad_pdf_png_decoder.sql
SHOW ERRORS TYPE BODY rad_pdf_png_decoder

PROMPT --- rad_pdf_images body (interlaced PNG check in parse_png)
@@../rad_pdf_images.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_images

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

-- NOTE (v1.7.0): the facade is NOT compiled here any more — its source now
-- references rad_pdf_chart (Phase 13).  Always run install_phase13.sql
-- after this script; it compiles the facade.

PROMPT === Phase 12 install complete ===
