CREATE OR REPLACE PACKAGE rad_pdf_images AUTHID DEFINER IS
/*
  rad_pdf_images — image management for the RAD_PDF suite.
  Oracle 19c+.

  Supported formats: JPEG, PNG, GIF.
  Images are cached per-session by SHA-256 hash (computed once at load time).
  Cache limit is configurable (default 50 MB). Older entries are evicted LRU.

  Session-scoped state (shared across documents):
    g_cache / g_cache_bytes / g_cache_limit : parsed image data (pixels).

  Per-document state (g_doc_state indexed by p_doc):
    used_hash  : image_id → sha256  (which images appear in this document)
    used_id    : sha256 → image_id
    next_id    : next available image_id for the document

  Batch pattern:
    Call set_image_cache_limit() once before the loop.
    Call clear_image_cache() after the loop to release session memory.
    Do NOT call clear_image_cache() inside the loop unless memory is critical.
*/

-- Configure the session-level image cache size limit.
-- Default: 52428800 bytes (50 MB). Call before the batch loop.
  PROCEDURE set_image_cache_limit(p_bytes IN NUMBER DEFAULT 52428800);

-- ---------------------------------------------------------------------------
-- Image loading
-- Returns an image_id scoped to p_doc (used with rad_pdf_canvas.put_image).
-- Loading the same image data twice in the same document returns the same id.
-- ---------------------------------------------------------------------------
  -- Load from a BLOB already in memory.
  FUNCTION  load_image(p_doc      IN rad_pdf_types.t_doc_handle,
                       p_img      IN BLOB)     RETURN PLS_INTEGER;

  -- Load from an Oracle Directory Object.
  -- p_dir must be an Oracle directory name (uppercase letters, digits, $, #, _).
  -- p_filename must not contain path separators or '..'.
  FUNCTION  load_image(p_doc      IN rad_pdf_types.t_doc_handle,
                       p_dir      IN VARCHAR2,
                       p_filename IN VARCHAR2)  RETURN PLS_INTEGER;

  -- Load from an HTTPS URL.
  -- p_url must start with 'https://'. Redirects are validated to remain HTTPS.
  -- Responses > 10 MB are rejected.
  FUNCTION  load_image(p_doc      IN rad_pdf_types.t_doc_handle,
                       p_url      IN VARCHAR2)  RETURN PLS_INTEGER;

-- ---------------------------------------------------------------------------
-- Image metadata
-- ---------------------------------------------------------------------------
  PROCEDURE get_image_dimensions(p_doc      IN  rad_pdf_types.t_doc_handle,
                                 p_image_id IN  PLS_INTEGER,
                                 p_width    OUT NUMBER,
                                 p_height   OUT NUMBER);

-- ---------------------------------------------------------------------------
-- Internal interface (called by rad_pdf_canvas and rad_pdf_serial during finalization)
-- Not for direct use by application code.
-- ---------------------------------------------------------------------------
  -- Write all referenced image PDF objects into p_doc.
  -- Returns a VARCHAR2 PDF fragment listing XObject resources:
  --   '/I1 5 0 R /I2 7 0 R ...'
  -- Returns NULL when no images are referenced in the document.
  FUNCTION  write_image_objects(p_doc IN rad_pdf_types.t_doc_handle) RETURN VARCHAR2;

  -- Release per-document tracking state (keeps the session-level cache).
  -- Called by rad_pdf_ctx.close_doc.
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle);

  -- Release ALL cached image data.
  -- Call after batch processing to reclaim session memory.
  PROCEDURE clear_image_cache;

  -- Accessor: is this image_id valid in p_doc?
  FUNCTION  image_exists(p_doc      IN rad_pdf_types.t_doc_handle,
                         p_image_id IN PLS_INTEGER) RETURN BOOLEAN;

END rad_pdf_images;
/
