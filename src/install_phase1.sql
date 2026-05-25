-- install_phase1.sql — compile Phase 1 (foundation) packages
-- Run from the target schema in SQL*Plus or SQL Developer.
-- All four packages are self-contained; no other RAD_PDF packages needed.
--
-- Prerequisites (run once as SYSDBA or DBA before compiling)
--   GRANT EXECUTE ON SYS.DBMS_CRYPTO TO <your_schema>;
--   GRANT EXECUTE ON SYS.UTL_COMPRESS TO <your_schema>;  -- needed by Phase 3 (rad_pdf_serial)

PROMPT === Phase 1 rad_pdf_types ===
@@rad_pdf_types.pks

PROMPT === Phase 1 rad_pdf_units ===
@@rad_pdf_units.pks
@@rad_pdf_units.pkb

PROMPT === Phase 1 rad_pdf_codec ===
@@rad_pdf_codec.pks
@@rad_pdf_codec.pkb

PROMPT === Phase 1 rad_pdf_styles ===
@@rad_pdf_styles.pks
@@rad_pdf_styles.pkb

PROMPT === Phase 1 complete ===
