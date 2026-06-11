CREATE OR REPLACE PACKAGE BODY rad_pdf_serial IS
/*
  rad_pdf_serial body — handle-based refactor of src/new/pdf_writer.pkb.
  Each document handle owns an independent t_serial_state record.
*/

  c_nl CONSTANT VARCHAR2(2) := CHR(13) || CHR(10);

-- ---------------------------------------------------------------------------
-- Per-document state
-- ---------------------------------------------------------------------------
  TYPE t_serial_state IS RECORD (
    pdf_doc     BLOB,
    obj_offsets DBMS_SQL.NUMBER_TABLE,
    pages       DBMS_SQL.BLOB_TABLE,
    page_nr     PLS_INTEGER    := 0,
    page_buffer VARCHAR2(32767)
  );

  TYPE t_serial_map IS TABLE OF t_serial_state INDEX BY PLS_INTEGER;
  g_docs t_serial_map;

-- ---------------------------------------------------------------------------
-- PRIVATE: initialise or recycle a temporary LOB
-- ---------------------------------------------------------------------------
  PROCEDURE init_lob(p_lob IN OUT NOCOPY BLOB) IS
  BEGIN
    IF p_lob IS NOT NULL AND DBMS_LOB.ISTEMPORARY(p_lob) = 1 THEN
      DBMS_LOB.FREETEMPORARY(p_lob);
    END IF;
    DBMS_LOB.CREATETEMPORARY(p_lob, TRUE, DBMS_LOB.SESSION);
  END init_lob;

-- ---------------------------------------------------------------------------
-- PRIVATE: append a RAW value to a BLOB (WRITEAPPEND, amount must be > 0)
-- ---------------------------------------------------------------------------
  PROCEDURE blob_append_raw(p_lob IN OUT NOCOPY BLOB, p_raw IN RAW) IS
    l_len PLS_INTEGER := UTL_RAW.LENGTH(p_raw);
  BEGIN
    IF l_len > 0 THEN
      DBMS_LOB.WRITEAPPEND(p_lob, l_len, p_raw);
    END IF;
  END blob_append_raw;

-- ---------------------------------------------------------------------------
-- Document lifecycle
-- ---------------------------------------------------------------------------
  PROCEDURE init_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_i PLS_INTEGER;
  BEGIN
    -- If a previous state exists for this handle, free its LOBs first.
    IF g_docs.EXISTS(p_doc) THEN
      IF g_docs(p_doc).pdf_doc IS NOT NULL
         AND DBMS_LOB.ISTEMPORARY(g_docs(p_doc).pdf_doc) = 1 THEN
        DBMS_LOB.FREETEMPORARY(g_docs(p_doc).pdf_doc);
      END IF;
      IF g_docs(p_doc).pages.COUNT > 0 THEN
        l_i := g_docs(p_doc).pages.FIRST;
        WHILE l_i IS NOT NULL LOOP
          IF g_docs(p_doc).pages(l_i) IS NOT NULL
             AND DBMS_LOB.ISTEMPORARY(g_docs(p_doc).pages(l_i)) = 1 THEN
            DBMS_LOB.FREETEMPORARY(g_docs(p_doc).pages(l_i));
          END IF;
          l_i := g_docs(p_doc).pages.NEXT(l_i);
        END LOOP;
      END IF;
    END IF;

    -- Initialise a fresh state record.
    g_docs(p_doc).pdf_doc     := NULL;
    g_docs(p_doc).obj_offsets.DELETE;
    g_docs(p_doc).pages.DELETE;
    g_docs(p_doc).page_nr     := 0;
    g_docs(p_doc).page_buffer := NULL;

    init_lob(g_docs(p_doc).pdf_doc);

    -- xref entry 0 is always the free-list head.
    g_docs(p_doc).obj_offsets(0) := 0;

    -- PDF header + binary marker comment.  PDF/A 6.1.2: the marker line
    -- must IMMEDIATELY follow the header EOL (no blank line between).
    doc_write(p_doc, '%PDF-1.4');
    blob_append_raw(g_docs(p_doc).pdf_doc, HEXTORAW('25E2E3CFD30A'));
  END init_doc;

-- ---------------------------------------------------------------------------
  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_i PLS_INTEGER;
  BEGIN
    IF NOT g_docs.EXISTS(p_doc) THEN RETURN; END IF;

    IF g_docs(p_doc).pdf_doc IS NOT NULL
       AND DBMS_LOB.ISTEMPORARY(g_docs(p_doc).pdf_doc) = 1 THEN
      DBMS_LOB.FREETEMPORARY(g_docs(p_doc).pdf_doc);
    END IF;

    IF g_docs(p_doc).pages.COUNT > 0 THEN
      l_i := g_docs(p_doc).pages.FIRST;
      WHILE l_i IS NOT NULL LOOP
        IF g_docs(p_doc).pages(l_i) IS NOT NULL
           AND DBMS_LOB.ISTEMPORARY(g_docs(p_doc).pages(l_i)) = 1 THEN
          DBMS_LOB.FREETEMPORARY(g_docs(p_doc).pages(l_i));
        END IF;
        l_i := g_docs(p_doc).pages.NEXT(l_i);
      END LOOP;
    END IF;

    g_docs.DELETE(p_doc);
  END close_doc;

-- ---------------------------------------------------------------------------
-- Document writes (main BLOB)
-- ---------------------------------------------------------------------------
  PROCEDURE doc_write(p_doc IN rad_pdf_types.t_doc_handle, p_txt IN VARCHAR2) IS
    l_raw    RAW(32767);
    c_nl_raw CONSTANT RAW(2) := UTL_RAW.CAST_TO_RAW(c_nl);
  BEGIN
    IF p_txt IS NOT NULL THEN
      l_raw := UTL_RAW.CAST_TO_RAW(p_txt);
      blob_append_raw(g_docs(p_doc).pdf_doc, l_raw);
      blob_append_raw(g_docs(p_doc).pdf_doc, c_nl_raw);
    END IF;
  END doc_write;

-- ---------------------------------------------------------------------------
  -- Appends a BLOB (e.g. a compressed stream) directly to the document BLOB.
  PROCEDURE doc_write_raw(p_doc IN rad_pdf_types.t_doc_handle, p_raw IN BLOB) IS
    l_len NUMBER := NVL(DBMS_LOB.GETLENGTH(p_raw), 0);
  BEGIN
    IF l_len > 0 THEN
      DBMS_LOB.APPEND(g_docs(p_doc).pdf_doc, p_raw);
    END IF;
  END doc_write_raw;

-- ---------------------------------------------------------------------------
-- PDF object management
-- ---------------------------------------------------------------------------
  FUNCTION begin_obj(p_doc         IN rad_pdf_types.t_doc_handle,
                     p_inline_dict IN VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    l_obj_nr NUMBER := g_docs(p_doc).obj_offsets.COUNT;
  BEGIN
    g_docs(p_doc).obj_offsets(l_obj_nr) :=
      DBMS_LOB.GETLENGTH(g_docs(p_doc).pdf_doc);

    IF p_inline_dict IS NULL THEN
      doc_write(p_doc, TO_CHAR(l_obj_nr) || ' 0 obj');
    ELSE
      doc_write(p_doc, TO_CHAR(l_obj_nr) || ' 0 obj' || c_nl ||
                       '<<' || p_inline_dict || '>>' || c_nl || 'endobj');
    END IF;
    RETURN l_obj_nr;
  END begin_obj;

-- ---------------------------------------------------------------------------
  PROCEDURE end_obj(p_doc IN rad_pdf_types.t_doc_handle) IS
  BEGIN
    doc_write(p_doc, 'endobj');
  END end_obj;

-- ---------------------------------------------------------------------------
  FUNCTION write_stream_obj(
    p_doc      IN     rad_pdf_types.t_doc_handle,
    p_data     IN OUT NOCOPY BLOB,
    p_extra    IN     VARCHAR2 DEFAULT NULL,
    p_compress IN     BOOLEAN  DEFAULT TRUE) RETURN NUMBER IS
    l_obj_nr NUMBER;
    l_stream BLOB;
    l_filter VARCHAR2(40) := '';
    l_dlen   NUMBER := NVL(DBMS_LOB.GETLENGTH(p_data), 0);
  BEGIN
    l_obj_nr := g_docs(p_doc).obj_offsets.COUNT;
    g_docs(p_doc).obj_offsets(l_obj_nr) :=
      DBMS_LOB.GETLENGTH(g_docs(p_doc).pdf_doc);
    doc_write(p_doc, TO_CHAR(l_obj_nr) || ' 0 obj');

    IF p_compress AND l_dlen > 0 THEN
      l_stream := rad_pdf_codec.flate_encode(p_data);
      l_filter  := '/Filter /FlateDecode ';
    ELSE
      DBMS_LOB.CREATETEMPORARY(l_stream, TRUE, DBMS_LOB.SESSION);
      IF l_dlen > 0 THEN
        DBMS_LOB.COPY(l_stream, p_data, l_dlen);
      END IF;
    END IF;

    doc_write(p_doc, '<<' || l_filter ||
                     '/Length ' || NVL(DBMS_LOB.GETLENGTH(l_stream), 0) ||
                     NVL(p_extra, '') || '>>');
    doc_write(p_doc, 'stream');
    doc_write_raw(p_doc, l_stream);
    -- PDF/A 6.1.7.1: endstream must be preceded by an EOL marker, and that
    -- EOL is NOT counted in /Length (which equals the exact stream bytes).
    blob_append_raw(g_docs(p_doc).pdf_doc, HEXTORAW('0A'));
    doc_write(p_doc, 'endstream');
    doc_write(p_doc, 'endobj');

    IF DBMS_LOB.ISTEMPORARY(l_stream) = 1 THEN
      DBMS_LOB.FREETEMPORARY(l_stream);
    END IF;
    RETURN l_obj_nr;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_stream IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_stream) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_stream);
      END IF;
      RAISE;
  END write_stream_obj;

-- ---------------------------------------------------------------------------
-- Page management
-- ---------------------------------------------------------------------------
  PROCEDURE page_flush(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_raw RAW(32767);
  BEGIN
    IF NVL(LENGTH(g_docs(p_doc).page_buffer), 0) > 0 THEN
      l_raw := UTL_RAW.CAST_TO_RAW(g_docs(p_doc).page_buffer);
      blob_append_raw(g_docs(p_doc).pages(g_docs(p_doc).page_nr), l_raw);
      g_docs(p_doc).page_buffer := NULL;
    END IF;
  END page_flush;

-- ---------------------------------------------------------------------------
  PROCEDURE new_page(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_blob BLOB;
  BEGIN
    -- Flush any buffered content for the current page (no-op on first call
    -- because the page BLOB does not exist yet and the buffer is NULL).
    IF g_docs(p_doc).pages.COUNT > 0 THEN
      page_flush(p_doc);
    END IF;

    -- Advance to the next page slot.
    g_docs(p_doc).page_nr := g_docs(p_doc).pages.COUNT;

    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE, DBMS_LOB.SESSION);
    g_docs(p_doc).pages(g_docs(p_doc).page_nr) := l_blob;
    g_docs(p_doc).page_buffer := NULL;
  END new_page;

-- ---------------------------------------------------------------------------
  PROCEDURE goto_page(p_doc     IN rad_pdf_types.t_doc_handle,
                      p_page_nr IN PLS_INTEGER) IS
  BEGIN
    page_flush(p_doc);
    IF NOT g_docs(p_doc).pages.EXISTS(p_page_nr) THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_validation,
        'rad_pdf_serial.goto_page: page ' || p_page_nr || ' does not exist', TRUE);
    END IF;
    g_docs(p_doc).page_nr := p_page_nr;
  END goto_page;

-- ---------------------------------------------------------------------------
  FUNCTION page_count(p_doc IN rad_pdf_types.t_doc_handle) RETURN PLS_INTEGER IS
  BEGIN
    IF NOT g_docs.EXISTS(p_doc) THEN RETURN 0; END IF;
    RETURN g_docs(p_doc).pages.COUNT;
  END page_count;

-- ---------------------------------------------------------------------------
  FUNCTION current_page(p_doc IN rad_pdf_types.t_doc_handle) RETURN PLS_INTEGER IS
  BEGIN
    RETURN g_docs(p_doc).page_nr;
  END current_page;

-- ---------------------------------------------------------------------------
  PROCEDURE page_write(p_doc IN rad_pdf_types.t_doc_handle, p_txt IN VARCHAR2) IS
    c_limit CONSTANT PLS_INTEGER := 28000;
    l_tlen  PLS_INTEGER := NVL(LENGTH(p_txt), 0) + 1;  -- +1 for trailing newline
    l_blen  PLS_INTEGER;
    l_raw   RAW(32767);
  BEGIN
    IF l_tlen = 1 THEN RETURN; END IF;  -- original was 0; empty string is LENGTH=NULL → +1 = 1

    l_blen := NVL(LENGTH(g_docs(p_doc).page_buffer), 0);

    IF l_blen + l_tlen > c_limit THEN
      IF l_blen > 0 THEN
        l_raw := UTL_RAW.CAST_TO_RAW(g_docs(p_doc).page_buffer);
        blob_append_raw(g_docs(p_doc).pages(g_docs(p_doc).page_nr), l_raw);
        g_docs(p_doc).page_buffer := NULL;
        l_blen := 0;
      END IF;
      IF l_tlen > c_limit THEN
        l_raw := UTL_RAW.CAST_TO_RAW(p_txt || CHR(10));
        blob_append_raw(g_docs(p_doc).pages(g_docs(p_doc).page_nr), l_raw);
        RETURN;
      END IF;
    END IF;

    g_docs(p_doc).page_buffer := g_docs(p_doc).page_buffer || p_txt || CHR(10);
  END page_write;

-- ---------------------------------------------------------------------------
  PROCEDURE page_write_raw(p_doc IN rad_pdf_types.t_doc_handle, p_raw IN RAW) IS
  BEGIN
    page_flush(p_doc);
    blob_append_raw(g_docs(p_doc).pages(g_docs(p_doc).page_nr), p_raw);
  END page_write_raw;

-- ---------------------------------------------------------------------------
  FUNCTION get_page_blob(p_doc     IN rad_pdf_types.t_doc_handle,
                         p_page_nr IN PLS_INTEGER) RETURN BLOB IS
  BEGIN
    RETURN g_docs(p_doc).pages(p_page_nr);
  END get_page_blob;

-- ---------------------------------------------------------------------------
-- Finalization
-- ---------------------------------------------------------------------------
  PROCEDURE finish_doc(
    p_doc           IN rad_pdf_types.t_doc_handle,
    p_catalogue_obj IN NUMBER,
    p_info_obj      IN NUMBER,
    p_total_pages   IN NUMBER) IS
    l_xref_offset NUMBER;
    l_obj_count   NUMBER := g_docs(p_doc).obj_offsets.COUNT;
  BEGIN
    page_flush(p_doc);

    l_xref_offset := DBMS_LOB.GETLENGTH(g_docs(p_doc).pdf_doc);

    doc_write(p_doc, 'xref');
    doc_write(p_doc, '0 ' || TO_CHAR(l_obj_count));
    doc_write(p_doc, '0000000000 65535 f');
    FOR i IN 1 .. l_obj_count - 1 LOOP
      doc_write(p_doc,
        TO_CHAR(g_docs(p_doc).obj_offsets(i), 'FM0000000000') || ' 00000 n');
    END LOOP;

    doc_write(p_doc, 'trailer');
    doc_write(p_doc, '<< /Root ' || TO_CHAR(p_catalogue_obj) || ' 0 R');
    doc_write(p_doc, '/Info '    || TO_CHAR(p_info_obj)      || ' 0 R');
    -- /ID: required by PDF/A (ISO 19005 6.1.3); harmless otherwise.
    -- Derived from the document bytes so far - both halves equal is valid
    -- for a first-generation file.
    DECLARE
      l_id VARCHAR2(32) :=
        UPPER(SUBSTR(rad_pdf_codec.sha256_hex(g_docs(p_doc).pdf_doc), 1, 32));
    BEGIN
      doc_write(p_doc, '/ID [<' || l_id || '> <' || l_id || '>]');
    END;
    doc_write(p_doc, '/Size '    || TO_CHAR(l_obj_count));
    doc_write(p_doc, '>>');
    doc_write(p_doc, 'startxref');
    doc_write(p_doc, TO_CHAR(l_xref_offset));
    doc_write(p_doc, '%%EOF');
  END finish_doc;

-- ---------------------------------------------------------------------------
  FUNCTION get_doc_copy(p_doc IN rad_pdf_types.t_doc_handle) RETURN BLOB IS
    l_copy BLOB;
    l_len  NUMBER := NVL(DBMS_LOB.GETLENGTH(g_docs(p_doc).pdf_doc), 0);
  BEGIN
    DBMS_LOB.CREATETEMPORARY(l_copy, TRUE, DBMS_LOB.SESSION);
    IF l_len > 0 THEN
      DBMS_LOB.COPY(l_copy, g_docs(p_doc).pdf_doc, l_len);
    END IF;
    RETURN l_copy;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_copy IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_copy) = 1 THEN
        DBMS_LOB.FREETEMPORARY(l_copy);
      END IF;
      RAISE;
  END get_doc_copy;

END rad_pdf_serial;
/
