-- install.sql — Full RAD_PDF suite installer.
-- Working directory must be src/ when running in SQL*Plus
--   SQL> @install.sql
-- Requires Oracle 19c+. Run as the schema owner.

PROMPT ================================================================
PROMPT  RAD_PDF v1.6.0-dev — Full Suite Installer
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
-- Phases 9 (template) and 12 (barcode) compile BEFORE phase 8: the facade
-- body references rad_pdf_template and rad_pdf_barcode, so on a fresh schema
-- those specs must exist first.  Phase 12 also recompiles the facade (it
-- doubles as the v1.5.x -> v1.6.0 upgrade script); phase 8 then recompiles
-- it a final time — harmless and keeps the phase scripts self-contained.
@@install/install_phase9.sql
PROMPT
@@install/install_phase12.sql
PROMPT
@@install/install_phase8.sql
PROMPT

PROMPT ================================================================
PROMPT  Install complete.
PROMPT
PROMPT  Run acceptance tests (from repo root)
PROMPT    @tests/phase9_integration.sql    canvas API + core packages
PROMPT    @tests/phase10_template.sql      template engine
PROMPT    @tests/phase11_watermark.sql     watermark (v1.4.0)
PROMPT    @tests/phase12_autowidth.sql     auto-width columns
PROMPT    @tests/phase12_canvas_ext.sql    line-dash + justification (v1.5.0)
PROMPT    @tests/phase13_barcode.sql       QR code (v1.6.0)
PROMPT
PROMPT  Canvas API     docs/sample01.sql .. sample10.sql
PROMPT  Template engine docs/sample11.sql, docs/sample12.sql
PROMPT  APEX examples  docs/apex/apex_sample00.sql .. apex_sample08.sql
PROMPT                  docs/apex/apex_template_01.sql .. apex_template_14.sql
PROMPT
PROMPT  Reference docs
PROMPT    docs/README.md            full user guide + API reference
PROMPT    docs/TEMPLATE_GUIDE.md    template engine tag catalogue and patterns
PROMPT    docs/apex/README.md       APEX integration guide
PROMPT ================================================================
