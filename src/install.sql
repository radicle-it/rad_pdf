-- install.sql — Full RAD_PDF suite installer.
-- Working directory must be src/ when running in SQL*Plus
--   SQL> @install.sql
-- Requires Oracle 19c+. Run as the schema owner.

PROMPT ================================================================
PROMPT  RAD_PDF v1.3.0 — Full Suite Installer
PROMPT  Oracle 19c+  |  Run as the target schema owner
PROMPT  Working directory src/
PROMPT ================================================================
PROMPT

@@install/install_phase1.sql
PROMPT
@@install/install_phase2.sql
PROMPT
@@install/install_phase3.sql
PROMPT
@@install/install_phase4.sql
PROMPT
@@install/install_phase5.sql
PROMPT
@@install/install_phase6.sql
PROMPT
@@install/install_phase7.sql
PROMPT
@@install/install_phase8.sql
PROMPT
@@install/install_phase9.sql
PROMPT
@@install/install_phase11.sql
PROMPT

PROMPT ================================================================
PROMPT  Install complete.
PROMPT
PROMPT  Run acceptance tests (from repo root)
PROMPT    @tests/phase9_integration.sql    canvas API + core packages
PROMPT    @tests/phase10_template.sql      template engine
PROMPT    @tests/phase12_autowidth.sql     auto-width columns
PROMPT
PROMPT  Canvas API     docs/sample01.sql .. sample10.sql
PROMPT  Template engine docs/sample11.sql, docs/sample12.sql
PROMPT  APEX examples  docs/apex/apex_sample00.sql .. apex_sample07.sql
PROMPT                  docs/apex/apex_template_01.sql .. apex_template_14.sql
PROMPT
PROMPT  Reference docs
PROMPT    docs/README.md            full user guide + API reference
PROMPT    docs/TEMPLATE_GUIDE.md    template engine tag catalogue and patterns
PROMPT    docs/apex/README.md       APEX integration guide
PROMPT ================================================================
