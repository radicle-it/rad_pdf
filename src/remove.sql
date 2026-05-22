-- remove.sql — Drop all RAD_PDF objects from the current schema.
-- Working directory must be src/ when running in SQL*Plus
--   SQL> @remove.sql
--
-- Objects are dropped in reverse dependency order:
--   packages high → low, then TYPE subtypes before base types.
-- Errors on already-absent objects are suppressed (IF EXISTS).

PROMPT ================================================================
PROMPT  RAD_PDF — Remove
PROMPT  Drops all packages and schema-level types from the current schema.
PROMPT ================================================================
PROMPT

-- -----------------------------------------------------------------------
-- Phase 8 — public facade
-- -----------------------------------------------------------------------
PROMPT --- dropping package rad_pdf
DROP PACKAGE rad_pdf;

-- -----------------------------------------------------------------------
-- Phase 7 — layout engine + table renderer
-- -----------------------------------------------------------------------
PROMPT --- dropping package rad_pdf_table
DROP PACKAGE rad_pdf_table;

PROMPT --- dropping package rad_pdf_layout
DROP PACKAGE rad_pdf_layout;

-- -----------------------------------------------------------------------
-- Phase 6 — canvas drawing primitives
-- -----------------------------------------------------------------------
PROMPT --- dropping package rad_pdf_canvas
DROP PACKAGE rad_pdf_canvas;

-- -----------------------------------------------------------------------
-- Phase 5 — image loader
-- -----------------------------------------------------------------------
PROMPT --- dropping package rad_pdf_images
DROP PACKAGE rad_pdf_images;

-- -----------------------------------------------------------------------
-- Phase 4 — font loader
-- -----------------------------------------------------------------------
PROMPT --- dropping package rad_pdf_fonts
DROP PACKAGE rad_pdf_fonts;

-- -----------------------------------------------------------------------
-- Phase 3 — low-level PDF serialiser
-- -----------------------------------------------------------------------
PROMPT --- dropping package rad_pdf_serial
DROP PACKAGE rad_pdf_serial;

-- -----------------------------------------------------------------------
-- Phase 2 — context / handle manager
-- -----------------------------------------------------------------------
PROMPT --- dropping package rad_pdf_ctx
DROP PACKAGE rad_pdf_ctx;

-- -----------------------------------------------------------------------
-- Phase 2 — schema-level object types (subtypes before base type)
-- -----------------------------------------------------------------------
PROMPT --- dropping image decoder types
DROP TYPE rad_pdf_jpeg_decoder FORCE;
DROP TYPE rad_pdf_png_decoder  FORCE;
DROP TYPE rad_pdf_gif_decoder  FORCE;
DROP TYPE rad_pdf_img_decoder  FORCE;
DROP TYPE rad_pdf_img_data     FORCE;

-- -----------------------------------------------------------------------
-- Phase 1 — foundation packages (no inter-dependencies; any order)
-- -----------------------------------------------------------------------
PROMPT --- dropping foundation packages
DROP PACKAGE rad_pdf_styles;
DROP PACKAGE rad_pdf_codec;
DROP PACKAGE rad_pdf_units;
DROP PACKAGE rad_pdf_types;

PROMPT
PROMPT ================================================================
PROMPT  RAD_PDF removed.
PROMPT ================================================================
