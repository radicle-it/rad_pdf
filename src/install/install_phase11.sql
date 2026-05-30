-- install_phase11.sql — UPGRADE script: v1.2.x -> v1.3.0 (auto-width columns)
--
-- USE THIS FILE only when upgrading an existing v1.2.x installation.
-- For a fresh install use install.sql instead (phases 1 and 7 already
-- include the updated rad_pdf_types and rad_pdf_table source).
--
-- Working directory must be src/ when running in SQL*Plus:
--   SQL> @@install/install_phase11.sql

PROMPT ================================================================
PROMPT  Phase 11 — Auto-width columns (v1.3.0)
PROMPT  Recompiles: rad_pdf_types, rad_pdf_table
PROMPT ================================================================

PROMPT -- rad_pdf_types (adds auto_width + max_width to t_column_def)
@@../rad_pdf_types.pks
SHOW ERRORS PACKAGE rad_pdf_types

PROMPT -- rad_pdf_table body (resolve_auto_widths + wiring)
@@../rad_pdf_table.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_table

PROMPT ================================================================
PROMPT  Phase 11 complete.
PROMPT  Run tests/phase12_autowidth.sql to verify.
PROMPT ================================================================
