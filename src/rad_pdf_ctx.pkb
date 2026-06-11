CREATE OR REPLACE PACKAGE BODY rad_pdf_ctx IS
/*
  rad_pdf_ctx body.

  close_doc calls close_doc on each package that owns per-document state.
  The call list is extended in each phase:
    Phase 2  (this file): handle + info only
    Phase 3: + rad_pdf_serial.close_doc
    Phase 4: + rad_pdf_fonts.close_doc  (added in this phase)
    Phase 5: + rad_pdf_images.close_doc (added in this phase)
    Phase 6: + rad_pdf_canvas.close_doc
    Phase 7: + rad_pdf_layout.close_doc (called FIRST) + rad_pdf_table.close_doc
*/

  TYPE t_handle_set   IS TABLE OF BOOLEAN              INDEX BY PLS_INTEGER;
  TYPE t_doc_info_map IS TABLE OF rad_pdf_types.t_doc_info INDEX BY PLS_INTEGER;
  TYPE t_conf_map     IS TABLE OF VARCHAR2(10)            INDEX BY PLS_INTEGER;

  g_active_docs  t_handle_set;
  g_doc_info     t_doc_info_map;
  g_conformance t_conf_map;
  g_next_handle  PLS_INTEGER := 1;

-- ---------------------------------------------------------------------------
  FUNCTION new_doc RETURN rad_pdf_types.t_doc_handle IS
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    l_doc := g_next_handle;
    g_next_handle := g_next_handle + 1;
    g_active_docs(l_doc) := TRUE;
    RETURN l_doc;
  END new_doc;

-- ---------------------------------------------------------------------------
  FUNCTION is_valid(p_doc IN rad_pdf_types.t_doc_handle) RETURN BOOLEAN IS
  BEGIN
    IF p_doc IS NULL THEN RETURN FALSE; END IF;
    RETURN g_active_docs.EXISTS(p_doc) AND g_active_docs(p_doc);
  END is_valid;

-- ---------------------------------------------------------------------------
  PROCEDURE assert_valid(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    IF NOT is_valid(p_doc) THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_handle,
        'rad_pdf_ctx: invalid or closed document handle: ' ||
        NVL(TO_CHAR(p_doc), '<null>'), TRUE);
    END IF;
  END assert_valid;

-- ---------------------------------------------------------------------------
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    g_conformance.DELETE(p_doc);
    IF NOT is_valid(p_doc) THEN RETURN; END IF;

    -- Per-package cleanup in reverse dependency order (highest level first).
    -- Each close_doc call is added as the corresponding package is built:
    --
    -- Phase 7 (highest level — called first):
    rad_pdf_layout.close_doc(p_doc);
    rad_pdf_table.close_doc(p_doc);
    -- Phase 6:
    rad_pdf_canvas.close_doc(p_doc);
    -- Phase 5:
    rad_pdf_images.close_doc(p_doc);
    -- Phase 4:
    rad_pdf_fonts.close_doc(p_doc);
    -- Phase 3:
    rad_pdf_serial.close_doc(p_doc);

    -- Remove handle and metadata.
    g_active_docs.DELETE(p_doc);
    IF g_doc_info.EXISTS(p_doc) THEN
      g_doc_info.DELETE(p_doc);
    END IF;
  END close_doc;

-- ---------------------------------------------------------------------------
  PROCEDURE set_conformance(p_doc   IN rad_pdf_types.t_doc_handle,
                            p_level IN VARCHAR2) IS
  BEGIN
    assert_valid(p_doc);
    IF UPPER(p_level) != 'PDF/A-2B' THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_ctx.set_conformance: unsupported level "' || p_level
        || '" - only PDF/A-2B is supported', TRUE);
    END IF;
    g_conformance(p_doc) := 'PDF/A-2B';
  END set_conformance;

-- ---------------------------------------------------------------------------
  FUNCTION get_conformance(p_doc IN rad_pdf_types.t_doc_handle)
    RETURN VARCHAR2 IS
  BEGIN
    IF g_conformance.EXISTS(p_doc) THEN
      RETURN g_conformance(p_doc);
    END IF;
    RETURN NULL;
  END get_conformance;

-- ---------------------------------------------------------------------------
  PROCEDURE set_info(p_doc  IN rad_pdf_types.t_doc_handle,
                     p_info IN rad_pdf_types.t_doc_info) IS
  BEGIN
    assert_valid(p_doc);
    g_doc_info(p_doc) := p_info;
  END set_info;

-- ---------------------------------------------------------------------------
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
