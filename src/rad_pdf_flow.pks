CREATE OR REPLACE PACKAGE rad_pdf_flow AUTHID DEFINER IS
/*
  rad_pdf_flow — the per-document registry of the flowable layer: the list of flowables and the table definitions.

  Below both rad_pdf_layout (which renders the list) and rad_pdf_table (which registers its definitions and adds its
  flowables): neither calls the other's registry, so the former cycle layout <-> table is gone (middleware-docs 96a
  §1b). It calls nobody but the types and the document context; it is not part of the importable core.
*/

  PROCEDURE add(p_doc IN rad_pdf_types.t_doc_handle, p_flow IN rad_pdf_types.t_flowable);

  -- the list as it is (a copy of the records; their CLOBs stay owned here)
  FUNCTION  list(p_doc IN rad_pdf_types.t_doc_handle) RETURN rad_pdf_types.t_flowable_list;
  FUNCTION  has_flowables(p_doc IN rad_pdf_types.t_doc_handle) RETURN BOOLEAN;

  FUNCTION  register_table(p_doc IN rad_pdf_types.t_doc_handle, p_table_def IN rad_pdf_types.t_table_def) RETURN PLS_INTEGER;
  FUNCTION  get_table_def(p_doc IN rad_pdf_types.t_doc_handle, p_table_ref IN PLS_INTEGER) RETURN rad_pdf_types.t_table_def;

  -- frees the flowables' and the table definitions' CLOBs
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);

END rad_pdf_flow;
/
