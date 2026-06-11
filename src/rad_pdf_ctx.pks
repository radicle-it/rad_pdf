CREATE OR REPLACE PACKAGE rad_pdf_ctx AUTHID DEFINER IS
/*
  rad_pdf_ctx — document handle allocation and lifecycle coordinator.
  Oracle 19c+.

  This package is the single point responsible for creating and destroying
  document handles. close_doc calls _close_doc on every package that holds
  per-document state, in reverse dependency order (highest level first).

  Packages with per-document state register a _close_doc procedure that is
  called by close_doc in the correct order (defined in the body).
  The order is extended in each phase as new packages are added.
*/

  -- Allocate a new document handle. Returns a value > 0, unique per session.
  FUNCTION  new_doc RETURN rad_pdf_types.t_doc_handle;

  -- Returns TRUE if the handle refers to an active (non-closed) document.
  FUNCTION  is_valid(p_doc IN rad_pdf_types.t_doc_handle) RETURN BOOLEAN;

  -- Raises c_err_handle if the handle is not valid.
  PROCEDURE assert_valid(p_doc IN rad_pdf_types.t_doc_handle);

  -- Release all per-document resources. Idempotent on already-closed handles.
  -- Calls _close_doc on every package with per-document state, then removes the handle.
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);

  -- Document metadata (PDF Info dictionary).
  PROCEDURE set_info(p_doc IN rad_pdf_types.t_doc_handle,
                     p_info IN rad_pdf_types.t_doc_info);
  FUNCTION  get_info(p_doc IN rad_pdf_types.t_doc_handle)
    RETURN rad_pdf_types.t_doc_info;

-- ---------------------------------------------------------------------------
-- Conformance level (v1.7.0).  NULL = plain PDF (default).
-- Currently supported value: 'PDF/A-2B'.  Stored per document; finalize
-- reads it to emit XMP metadata, OutputIntent and enforce font embedding.
-- ---------------------------------------------------------------------------
  PROCEDURE set_conformance(p_doc   IN rad_pdf_types.t_doc_handle,
                            p_level IN VARCHAR2);
  FUNCTION  get_conformance(p_doc IN rad_pdf_types.t_doc_handle)
    RETURN VARCHAR2;

END rad_pdf_ctx;
/
