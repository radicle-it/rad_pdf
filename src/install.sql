-- install.sql — Full RAD_PDF suite installer.
-- Working directory must be src/ when running in SQL*Plus
--   SQL> @install.sql
-- Requires Oracle 19c+. Run as the schema owner.

PROMPT ================================================================
PROMPT  RAD_PDF — Full Suite Installer
PROMPT  Oracle 19c+  |  Run as the target schema owner
PROMPT  Working directory src/
PROMPT ================================================================
PROMPT

@@install_phase1.sql
PROMPT
@@install_phase2.sql
PROMPT
@@install_phase3.sql
PROMPT
@@install_phase4.sql
PROMPT
@@install_phase5.sql
PROMPT
@@install_phase6.sql
PROMPT
@@install_phase7.sql
PROMPT
@@install_phase8.sql
PROMPT

PROMPT ================================================================
PROMPT  Install complete.
PROMPT
PROMPT  Run acceptance tests (from repo root)
PROMPT    @tests/phase1_foundation.sql
PROMPT    @tests/phase2_ctx_decoders.sql
PROMPT    @tests/phase3_serial.sql
PROMPT    @tests/phase4_fonts.sql
PROMPT    @tests/phase5_images.sql
PROMPT    @tests/phase6_canvas.sql
PROMPT    @tests/phase7_layout.sql
PROMPT    @tests/phase8_pdf.sql
PROMPT    @tests/phase9_integration.sql
PROMPT
PROMPT  Public API entry point rad_pdf package (rad_pdf.pks / rad_pdf.pkb)
PROMPT  See docs/sample01.sql .. sample05.sql for usage examples.
PROMPT ================================================================
