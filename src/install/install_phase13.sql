-- install_phase13.sql — Phase 13: v1.7.0 features
--   rad_pdf_chart (bar / line / pie vector charts)
--   <qrcode> template tag (QRCODE flowable in rad_pdf_layout)
--   PDF/A-2b conformance (set_conformance; XMP + OutputIntent + /ID)
--   TTF parser fixes (1-based offsets, dependency-ordered tables)
--
-- Used by install.sql for a fresh install (runs after phase 12, BEFORE
-- phase 8 — the facade references rad_pdf_chart) AND as the UPGRADE
-- script for an existing v1.6.0 installation.
--
-- Working directory must be src/ when running in SQL*Plus:
--   SQL> @@install/install_phase13.sql

PROMPT === Phase 13 v1.7.0 (charts) ===

PROMPT --- rad_pdf_types (adds t_text_list, t_rgb_list)
@@../rad_pdf_types.pks
SHOW ERRORS PACKAGE rad_pdf_types

PROMPT --- rad_pdf_codec (adds srgb_icc, xml_escape)
@@../rad_pdf_codec.pks
SHOW ERRORS PACKAGE rad_pdf_codec
@@../rad_pdf_codec.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_codec

PROMPT --- rad_pdf_serial body (trailer /ID + PDF/A stream framing)
@@../rad_pdf_serial.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_serial

PROMPT --- rad_pdf_ctx (adds set_conformance / get_conformance)
@@../rad_pdf_ctx.pks
SHOW ERRORS PACKAGE rad_pdf_ctx
@@../rad_pdf_ctx.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_ctx

PROMPT --- rad_pdf_fonts (adds assert_all_embedded; TTF parser fixes)
@@../rad_pdf_fonts.pks
SHOW ERRORS PACKAGE rad_pdf_fonts
@@../rad_pdf_fonts.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_fonts

PROMPT --- rad_pdf_layout spec (adds qrcode flowable constructor) — spec-first
@@../rad_pdf_layout.pks
SHOW ERRORS PACKAGE rad_pdf_layout

PROMPT --- rad_pdf_table spec (recompiled: circular dependency with layout)
@@../rad_pdf_table.pks
SHOW ERRORS PACKAGE rad_pdf_table

PROMPT --- rad_pdf_layout body (QRCODE flowable measure + render)
@@../rad_pdf_layout.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_layout

PROMPT --- rad_pdf_table body (recompiled: circular dependency with layout)
@@../rad_pdf_table.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_table

PROMPT --- rad_pdf_template body (adds <qrcode> tag)
SET DEFINE OFF
@@../rad_pdf_template.pkb
SET DEFINE ON
SHOW ERRORS PACKAGE BODY rad_pdf_template

PROMPT --- rad_pdf_ctx body (revalidate after t_flowable change)
ALTER PACKAGE rad_pdf_ctx COMPILE BODY;

PROMPT --- rad_pdf_chart spec
@@../rad_pdf_chart.pks
SHOW ERRORS PACKAGE rad_pdf_chart

PROMPT --- rad_pdf_chart body
@@../rad_pdf_chart.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_chart

PROMPT --- rad_pdf spec (adds bar_chart, line_chart, pie_chart)
@@../rad_pdf.pks
SHOW ERRORS PACKAGE rad_pdf

PROMPT --- rad_pdf body
@@../rad_pdf.pkb
SHOW ERRORS PACKAGE BODY rad_pdf

PROMPT === Phase 13 install complete ===
