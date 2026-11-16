CREATE OR REPLACE PACKAGE rad_pdf_merge AUTHID DEFINER AS
-- =============================================================================
-- RAD_PDF_MERGE: the data merge of the Word evolution (middleware-docs 96a §5, §6.3; "unione dei dati" of doc 96
-- §14.8). A template RI (rad_pdf_ri) + a print schema + the JSON data of one document -> an INSTANCE: the same nodes,
-- with every tag replaced by its text or image and every region expanded or omitted; sealed, ready for the paginator.
-- No package state: the schema and the data are parameters.
--
--   check_schema    the schema itself (types, paths, nullability of ARRAY/BOOLEAN, containers of [] paths)
--   check_template  at publication: every resolved path of the template exists in the schema, of the right type
--                   (FIELD on TEXT, IMAGE on IMAGE, PAGEBREAK on BOOLEAN, LOOP on ARRAY, SECTION on anything else)
--   check_data      at every print: required present, null only where nullable, types, images in the Oracle form
--   merge           validate (rad_pdf_ri) + the three checks + the expansion, reading ONLY the resolved references
--                   (96a §6.3: no search in the data, no fallback outwards)
--
-- Errors: [PRT_SCHEMA] the schema or the template against it; [PRT_DATA] the data (always with the path);
-- [PDF_BUDGET] a budget of 96a §8 exceeded.
-- =============================================================================

  c_err_data   CONSTANT PLS_INTEGER := -20841;          -- [PRT_DATA]
  c_err_budget CONSTANT PLS_INTEGER := -20842;          -- [PDF_BUDGET]
  c_err_schema CONSTANT PLS_INTEGER := -20843;          -- [PRT_SCHEMA]

  -- the budgets of 96a §8 that the merge enforces
  c_max_json_chars  CONSTANT PLS_INTEGER := 5 * 1024 * 1024;
  c_max_image_bytes CONSTANT PLS_INTEGER := 5 * 1024 * 1024;
  c_max_image_px    CONSTANT PLS_INTEGER := 4000;
  c_max_loop_depth  CONSTANT PLS_INTEGER := 3;
  c_max_nodes       CONSTANT PLS_INTEGER := 20000;

  -- one field of a print schema: the shape of prt_schema_field (96a §5.1)
  TYPE t_field IS RECORD (
    path     VARCHAR2(400),                              -- quote.no | lines | lines[].code
    type     VARCHAR2(7),                                -- TEXT | BOOLEAN | IMAGE | ARRAY | OBJECT
    required rad_pdf_ri.t_flag,
    nullable rad_pdf_ri.t_flag);
  TYPE t_schema IS TABLE OF t_field;

  -- a field; nullable defaults to 96a §5.1: an optional TEXT or IMAGE is nullable, everything else is not
  FUNCTION field(p_path IN VARCHAR2, p_type IN VARCHAR2, p_required IN rad_pdf_ri.t_flag,
                 p_nullable IN rad_pdf_ri.t_flag DEFAULT NULL) RETURN t_field;
  -- a schema written as JSON: {"fields":[{"path":..,"type":..,"required":"Y","nullable":"N"},..]} (tests, fixtures)
  FUNCTION schema_from_json(p_json IN CLOB) RETURN t_schema;

  PROCEDURE check_schema  (p_schema IN t_schema);
  PROCEDURE check_template(p_ri IN rad_pdf_ri.t_ri, p_schema IN t_schema);
  PROCEDURE check_data    (p_data IN CLOB, p_schema IN t_schema);

  -- the instance (rad_pdf_ri.new_instance), sealed; the caller frees it with rad_pdf_ri.free
  FUNCTION merge(p_ri IN rad_pdf_ri.t_ri, p_schema IN t_schema, p_data IN CLOB) RETURN rad_pdf_ri.t_ri;

END rad_pdf_merge;
/
