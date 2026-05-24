-- install_phase2.sql — compile Phase 2 (schema types + rad_pdf_ctx)
-- Prerequisites: Phase 1 must be installed first (@@install_phase1.sql).

PROMPT === Phase 2 schema-level types ===
@@rad_pdf_img_data.sql
@@rad_pdf_img_decoder.sql
@@rad_pdf_jpeg_decoder.sql
@@rad_pdf_png_decoder.sql
@@rad_pdf_gif_decoder.sql

PROMPT === Phase 2 rad_pdf_ctx ===
@@rad_pdf_ctx.pks

-- Phase 2 stub body: close_doc only frees the handle.
-- Full body (with sub-package close_doc calls) is compiled at Phase 7 (@@rad_pdf_ctx.pkb).
CREATE OR REPLACE PACKAGE BODY rad_pdf_ctx IS

  TYPE t_handle_set   IS TABLE OF BOOLEAN                  INDEX BY PLS_INTEGER;
  TYPE t_doc_info_map IS TABLE OF rad_pdf_types.t_doc_info INDEX BY PLS_INTEGER;

  g_active_docs  t_handle_set;
  g_doc_info     t_doc_info_map;
  g_next_handle  PLS_INTEGER := 1;

  FUNCTION new_doc RETURN rad_pdf_types.t_doc_handle IS
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    l_doc := g_next_handle;
    g_next_handle := g_next_handle + 1;
    g_active_docs(l_doc) := TRUE;
    RETURN l_doc;
  END new_doc;

  FUNCTION is_valid(p_doc IN rad_pdf_types.t_doc_handle) RETURN BOOLEAN IS
  BEGIN
    IF p_doc IS NULL THEN RETURN FALSE; END IF;
    RETURN g_active_docs.EXISTS(p_doc) AND g_active_docs(p_doc);
  END is_valid;

  PROCEDURE assert_valid(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    IF NOT is_valid(p_doc) THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_handle,
        'rad_pdf_ctx: invalid or closed document handle: ' ||
        NVL(TO_CHAR(p_doc), '<null>'), TRUE);
    END IF;
  END assert_valid;

  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    IF NOT is_valid(p_doc) THEN RETURN; END IF;
    -- Sub-package close_doc calls added at Phase 7 (@@rad_pdf_ctx.pkb).
    g_active_docs.DELETE(p_doc);
    IF g_doc_info.EXISTS(p_doc) THEN
      g_doc_info.DELETE(p_doc);
    END IF;
  END close_doc;

  PROCEDURE set_info(p_doc  IN rad_pdf_types.t_doc_handle,
                     p_info IN rad_pdf_types.t_doc_info) IS
  BEGIN
    assert_valid(p_doc);
    g_doc_info(p_doc) := p_info;
  END set_info;

  FUNCTION get_info(p_doc IN rad_pdf_types.t_doc_handle)
    RETURN rad_pdf_types.t_doc_info IS
    l_empty rad_pdf_types.t_doc_info;
  BEGIN
    assert_valid(p_doc);
    IF g_doc_info.EXISTS(p_doc) THEN
      RETURN g_doc_info(p_doc);
    END IF;
    RETURN l_empty;
  END get_info;

END rad_pdf_ctx;
/
SHOW ERRORS PACKAGE BODY rad_pdf_ctx

PROMPT === Phase 2 complete ===
