-- install_phase13.sql — Phase 13: v1.7.0 features
--   rad_pdf_chart (bar / line / pie vector charts)
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
