-- install_phase11.sql — Auto-width columns (v1.3.0)
-- Recompiles rad_pdf_types (new t_column_def fields) and rad_pdf_table
-- (resolve_auto_widths). All other packages depend on rad_pdf_types by spec,
-- so they recompile automatically when invalidated by Oracle.
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
