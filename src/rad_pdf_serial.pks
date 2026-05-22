CREATE OR REPLACE PACKAGE rad_pdf_serial AUTHID DEFINER IS
/*
  rad_pdf_serial — low-level PDF binary writer, one state-record per document handle.
  Internal package: do NOT grant EXECUTE to application users.
*/

-- ---------------------------------------------------------------------------
-- Document lifecycle
-- ---------------------------------------------------------------------------
  PROCEDURE init_doc  (p_doc IN rad_pdf_types.t_doc_handle);
  PROCEDURE close_doc (p_doc IN rad_pdf_types.t_doc_handle);

-- ---------------------------------------------------------------------------
-- Low-level document writes (main document BLOB: header, objects, xref, trailer)
-- ---------------------------------------------------------------------------
  PROCEDURE doc_write    (p_doc IN rad_pdf_types.t_doc_handle, p_txt IN VARCHAR2);
  PROCEDURE doc_write_raw(p_doc IN rad_pdf_types.t_doc_handle, p_raw IN BLOB);

  FUNCTION  begin_obj(p_doc         IN rad_pdf_types.t_doc_handle,
                      p_inline_dict IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;
  PROCEDURE end_obj  (p_doc IN rad_pdf_types.t_doc_handle);

  FUNCTION  write_stream_obj(
    p_doc      IN     rad_pdf_types.t_doc_handle,
    p_data     IN OUT NOCOPY BLOB,
    p_extra    IN     VARCHAR2 DEFAULT NULL,
    p_compress IN     BOOLEAN  DEFAULT TRUE) RETURN NUMBER;

-- ---------------------------------------------------------------------------
-- Page management
-- ---------------------------------------------------------------------------
  PROCEDURE new_page    (p_doc IN rad_pdf_types.t_doc_handle);
  PROCEDURE goto_page   (p_doc IN rad_pdf_types.t_doc_handle,
                         p_page_nr IN PLS_INTEGER);
  FUNCTION  page_count  (p_doc IN rad_pdf_types.t_doc_handle) RETURN PLS_INTEGER;
  FUNCTION  current_page(p_doc IN rad_pdf_types.t_doc_handle) RETURN PLS_INTEGER;

  PROCEDURE page_write    (p_doc IN rad_pdf_types.t_doc_handle, p_txt IN VARCHAR2);
  PROCEDURE page_write_raw(p_doc IN rad_pdf_types.t_doc_handle, p_raw IN RAW);
  PROCEDURE page_flush    (p_doc IN rad_pdf_types.t_doc_handle);
  FUNCTION  get_page_blob (p_doc     IN rad_pdf_types.t_doc_handle,
                           p_page_nr IN PLS_INTEGER) RETURN BLOB;

-- ---------------------------------------------------------------------------
-- Finalization
-- ---------------------------------------------------------------------------
  PROCEDURE finish_doc(
    p_doc           IN rad_pdf_types.t_doc_handle,
    p_catalogue_obj IN NUMBER,
    p_info_obj      IN NUMBER,
    p_total_pages   IN NUMBER);

  FUNCTION  get_doc_copy(p_doc IN rad_pdf_types.t_doc_handle) RETURN BLOB;

END rad_pdf_serial;
/
