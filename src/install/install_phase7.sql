-- install_phase7.sql — compile Phase 7 rad_pdf_layout + rad_pdf_table + rad_pdf_ctx.pkb
-- Run after install_phase6.sql.
-- Compile order (circular body dependency)
--   rad_pdf_layout.pks → rad_pdf_table.pks → rad_pdf_layout.pkb → rad_pdf_table.pkb → rad_pdf_ctx.pkb
-- Also recompiles rad_pdf_canvas with measure_wrapped extension.

PROMPT === Phase 7 rad_pdf_layout + rad_pdf_table ===

PROMPT --- rad_pdf_canvas spec (adds measure_wrapped)
@@../rad_pdf_canvas.pks
SHOW ERRORS PACKAGE rad_pdf_canvas

PROMPT --- rad_pdf_canvas body (adds measure_wrapped)
@@../rad_pdf_canvas.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_canvas

PROMPT --- rad_pdf_layout spec
@@../rad_pdf_layout.pks
SHOW ERRORS PACKAGE rad_pdf_layout

PROMPT --- rad_pdf_table spec
@@../rad_pdf_table.pks
SHOW ERRORS PACKAGE rad_pdf_table

PROMPT --- rad_pdf_layout body
@@../rad_pdf_layout.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_layout

PROMPT --- rad_pdf_table body
@@../rad_pdf_table.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_table

PROMPT --- rad_pdf_ctx body (adds rad_pdf_layout.close_doc + rad_pdf_table.close_doc)
@@../rad_pdf_ctx.pkb
SHOW ERRORS PACKAGE BODY rad_pdf_ctx

PROMPT === Phase 7 install complete ===
