CREATE OR REPLACE PACKAGE BODY rad_pdf_flow IS

  TYPE t_table_def_map IS TABLE OF rad_pdf_types.t_table_def INDEX BY PLS_INTEGER;
  TYPE t_state IS RECORD (
    flowables     rad_pdf_types.t_flowable_list,
    table_defs    t_table_def_map,
    next_table_id PLS_INTEGER := 1);
  TYPE t_state_map IS TABLE OF t_state INDEX BY PLS_INTEGER;
  g_state t_state_map;

  PROCEDURE ensure_state(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_s t_state;
  BEGIN
    IF NOT g_state.EXISTS(p_doc) THEN g_state(p_doc) := l_s; END IF;
  END ensure_state;

  PROCEDURE add(p_doc IN rad_pdf_types.t_doc_handle, p_flow IN rad_pdf_types.t_flowable) IS
    l_idx PLS_INTEGER;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    IF g_state(p_doc).flowables.COUNT = 0 THEN
      l_idx := 1;
    ELSE
      l_idx := g_state(p_doc).flowables.LAST + 1;
    END IF;
    g_state(p_doc).flowables(l_idx) := p_flow;
  END add;

  FUNCTION list(p_doc IN rad_pdf_types.t_doc_handle) RETURN rad_pdf_types.t_flowable_list IS
    l_empty rad_pdf_types.t_flowable_list;
  BEGIN
    IF NOT g_state.EXISTS(p_doc) THEN RETURN l_empty; END IF;
    RETURN g_state(p_doc).flowables;
  END list;

  FUNCTION has_flowables(p_doc IN rad_pdf_types.t_doc_handle) RETURN BOOLEAN IS
  BEGIN
    IF NOT g_state.EXISTS(p_doc) THEN RETURN FALSE; END IF;
    RETURN g_state(p_doc).flowables.COUNT > 0;
  END has_flowables;

  FUNCTION register_table(p_doc IN rad_pdf_types.t_doc_handle, p_table_def IN rad_pdf_types.t_table_def) RETURN PLS_INTEGER IS
    l_id PLS_INTEGER;
  BEGIN
    rad_pdf_ctx.assert_valid(p_doc);
    ensure_state(p_doc);
    l_id := g_state(p_doc).next_table_id;
    g_state(p_doc).table_defs(l_id) := p_table_def;
    g_state(p_doc).next_table_id := l_id + 1;
    RETURN l_id;
  END register_table;

  FUNCTION get_table_def(p_doc IN rad_pdf_types.t_doc_handle, p_table_ref IN PLS_INTEGER) RETURN rad_pdf_types.t_table_def IS
    l_empty rad_pdf_types.t_table_def;
  BEGIN
    IF g_state.EXISTS(p_doc) AND g_state(p_doc).table_defs.EXISTS(p_table_ref) THEN
      RETURN g_state(p_doc).table_defs(p_table_ref);
    END IF;
    RETURN l_empty;
  END get_table_def;

  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_idx  PLS_INTEGER;
  BEGIN
    IF NOT g_state.EXISTS(p_doc) THEN RETURN; END IF;
    l_idx := g_state(p_doc).flowables.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      IF DBMS_LOB.ISTEMPORARY(g_state(p_doc).flowables(l_idx).text) = 1 THEN
        DBMS_LOB.FREETEMPORARY(g_state(p_doc).flowables(l_idx).text);
      END IF;
      l_idx := g_state(p_doc).flowables.NEXT(l_idx);
    END LOOP;
    l_idx := g_state(p_doc).table_defs.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      IF DBMS_LOB.ISTEMPORARY(g_state(p_doc).table_defs(l_idx).query_clob) = 1 THEN
        DBMS_LOB.FREETEMPORARY(g_state(p_doc).table_defs(l_idx).query_clob);
      END IF;
      l_idx := g_state(p_doc).table_defs.NEXT(l_idx);
    END LOOP;
    g_state.DELETE(p_doc);
  END close_doc;

END rad_pdf_flow;
/
