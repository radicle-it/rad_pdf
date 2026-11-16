CREATE OR REPLACE PACKAGE BODY rad_pdf_doc IS

  -- RAISE_APPLICATION_ERROR takes at most 2048 bytes of message
  c_max_msg_bytes CONSTANT PLS_INTEGER := 2048;
  c_prefix        CONSTANT VARCHAR2(30) := 'Document cleanup: ';

  -- ---------------------------------------------------------------------------
  -- the cleanup of a document: every closer runs; the first failure is kept and raised at the end
  -- ---------------------------------------------------------------------------
  PROCEDURE note(p_state IN OUT NOCOPY t_close, p_package IN VARCHAR2) IS
  BEGIN
    IF p_state.head IS NULL THEN
      -- package, code and message first (SQLERRM would stop at 512 bytes), then the backtrace in the bytes left
      p_state.head  := SUBSTRB(p_package || ': ' || RTRIM(DBMS_UTILITY.FORMAT_ERROR_STACK, CHR(10)), 1, 1500);
      p_state.trace := SUBSTRB(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 2000);
    END IF;
  END note;

  PROCEDURE inject(p_package IN VARCHAR2) IS
  BEGIN
    $IF $$rad_pdf_test $THEN
    -- fault injection, compiled only with PLSQL_CCFLAGS='rad_pdf_test:TRUE' (tests/phase22_doc_isolation.sql):
    -- CLIENT_INFO 'rad_pdf_fault=<package>' makes that closer fail before it closes anything, with a long multibyte
    -- message; it serves the closers of the core (here) and those of the flowable layer (rad_pdf.close_document)
    IF SYS_CONTEXT('USERENV', 'CLIENT_INFO') = 'rad_pdf_fault=' || p_package THEN
      RAISE_APPLICATION_ERROR(-20990, 'injected fault in ' || p_package || ' ' || RPAD(UNISTR('\00E9'), 900, UNISTR('\00E9')));
    END IF;
    $END
    NULL;
  END inject;

  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_state t_close;
  BEGIN
    close_doc(p_doc, l_state);
  END close_doc;

  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle, p_state IN OUT NOCOPY t_close) IS
    -- the closers of the core only: the flowable layer is closed by rad_pdf.close_document before it calls this
    PROCEDURE run(p_package IN VARCHAR2) IS
    BEGIN
      inject(p_package);
      CASE p_package
        WHEN 'rad_pdf_canvas'   THEN rad_pdf_canvas.close_doc(p_doc);
        WHEN 'rad_pdf_images'   THEN rad_pdf_images.close_doc(p_doc);
        WHEN 'rad_pdf_fonts'    THEN rad_pdf_fonts.close_doc(p_doc);
        WHEN 'rad_pdf_serial'   THEN rad_pdf_serial.close_doc(p_doc);
      END CASE;
    EXCEPTION
      WHEN OTHERS THEN note(p_state, p_package);
    END run;
  BEGIN
    IF p_doc IS NULL THEN RETURN; END IF;
    IF NOT rad_pdf_ctx.is_valid(p_doc) THEN
      rad_pdf_ctx.release_doc(p_doc);
      RETURN;
    END IF;
    run('rad_pdf_canvas');
    run('rad_pdf_images');
    run('rad_pdf_fonts');
    run('rad_pdf_serial');
    rad_pdf_ctx.release_doc(p_doc);
    IF p_state.head IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_internal,
        SUBSTRB(c_prefix || p_state.head || CHR(10) || p_state.trace, 1, c_max_msg_bytes));
    END IF;
  END close_doc;

  -- ---------------------------------------------------------------------------
  -- opening and assembling (moved from rad_pdf: the core makes a PDF without the flowable layer)
  -- ---------------------------------------------------------------------------
  FUNCTION open_doc(p_info IN rad_pdf_types.t_doc_info DEFAULT NULL,
                    p_compress_pages IN BOOLEAN DEFAULT TRUE) RETURN rad_pdf_types.t_doc_handle IS
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_serial.set_page_compression(l_doc,p_compress_pages);
    rad_pdf_fonts.load_standard_fonts;
    -- Store document metadata
    IF p_info.title    IS NOT NULL OR p_info.author  IS NOT NULL OR
       p_info.subject  IS NOT NULL OR p_info.keywords IS NOT NULL THEN
      rad_pdf_ctx.set_info(l_doc, p_info);
    END IF;
    RETURN l_doc;
  EXCEPTION
    WHEN OTHERS THEN
      -- the initialization error wins: a cleanup error must not replace it
      BEGIN close_doc(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
      RAISE;
  END open_doc;

  FUNCTION pdf_date RETURN VARCHAR2 IS
  BEGIN
    RETURN 'D:' || TO_CHAR(rad_pdf_ctx.now_utc, 'YYYYMMDDHH24MISS') || 'Z';
  END pdf_date;

-- ---------------------------------------------------------------------------
-- PRIVATE: XMP metadata packet for PDF/A (UTF-8; BOM in the xpacket header).
-- Values MUST stay consistent with the Info dictionary (veraPDF checks).
-- ---------------------------------------------------------------------------
  FUNCTION build_xmp(p_info     IN rad_pdf_types.t_doc_info,
                     p_date_iso IN VARCHAR2) RETURN BLOB IS
    l_b   BLOB;
    l_xml VARCHAR2(32767);
    PROCEDURE w(p_s IN VARCHAR2) IS
    BEGIN
      l_xml := l_xml || p_s || CHR(10);
    END w;
  BEGIN
    w('<?xpacket begin="' || UTL_RAW.CAST_TO_VARCHAR2(HEXTORAW('EFBBBF'))
      || '" id="W5M0MpCehiHzreSzNTczkc9d"?>');
    w('<x:xmpmeta xmlns:x="adobe:ns:meta/">');
    w(' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">');
    w('  <rdf:Description rdf:about=""'
      || ' xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">');
    w('   <pdfaid:part>2</pdfaid:part>');
    w('   <pdfaid:conformance>B</pdfaid:conformance>');
    w('  </rdf:Description>');
    w('  <rdf:Description rdf:about=""'
      || ' xmlns:dc="http://purl.org/dc/elements/1.1/">');
    IF p_info.title IS NOT NULL THEN
      w('   <dc:title><rdf:Alt><rdf:li xml:lang="x-default">'
        || rad_pdf_codec.xml_escape(p_info.title)
        || '</rdf:li></rdf:Alt></dc:title>');
    END IF;
    IF p_info.author IS NOT NULL THEN
      w('   <dc:creator><rdf:Seq><rdf:li>'
        || rad_pdf_codec.xml_escape(p_info.author)
        || '</rdf:li></rdf:Seq></dc:creator>');
    END IF;
    IF p_info.subject IS NOT NULL THEN
      w('   <dc:description><rdf:Alt><rdf:li xml:lang="x-default">'
        || rad_pdf_codec.xml_escape(p_info.subject)
        || '</rdf:li></rdf:Alt></dc:description>');
    END IF;
    w('  </rdf:Description>');
    w('  <rdf:Description rdf:about=""'
      || ' xmlns:xmp="http://ns.adobe.com/xap/1.0/">');
    w('   <xmp:CreatorTool>RAD_PDF</xmp:CreatorTool>');
    w('   <xmp:CreateDate>' || p_date_iso || '</xmp:CreateDate>');
    w('   <xmp:ModifyDate>' || p_date_iso || '</xmp:ModifyDate>');
    w('  </rdf:Description>');
    w('  <rdf:Description rdf:about=""'
      || ' xmlns:pdf="http://ns.adobe.com/pdf/1.3/">');
    w('   <pdf:Producer>Oracle Database 19c+</pdf:Producer>');
    IF p_info.keywords IS NOT NULL THEN
      w('   <pdf:Keywords>' || rad_pdf_codec.xml_escape(p_info.keywords)
        || '</pdf:Keywords>');
    END IF;
    w('  </rdf:Description>');
    w(' </rdf:RDF>');
    w('</x:xmpmeta>');
    w('<?xpacket end="w"?>');
    DBMS_LOB.CREATETEMPORARY(l_b, TRUE, DBMS_LOB.SESSION);
    DBMS_LOB.WRITEAPPEND(l_b, UTL_RAW.LENGTH(UTL_RAW.CAST_TO_RAW(l_xml)),
                         UTL_RAW.CAST_TO_RAW(l_xml));
    RETURN l_b;
  END build_xmp;

-- ---------------------------------------------------------------------------
  FUNCTION assemble(p_doc IN rad_pdf_types.t_doc_handle) RETURN BLOB IS
    l_font_res   CLOB;   -- A6
    l_img_res    CLOB;
    l_pages_obj  NUMBER;
    l_outline_obj NUMBER;
    l_cat_obj    NUMBER;
    l_info_obj   NUMBER;
    l_conf       VARCHAR2(10);
    l_icc        BLOB;
    l_icc_obj    NUMBER;
    l_oi_obj     NUMBER;
    l_xmp        BLOB;
    l_xmp_obj    NUMBER;
    l_ts         TIMESTAMP WITH TIME ZONE;
    l_date_iso   VARCHAR2(30);
    l_doc_info   rad_pdf_types.t_doc_info;
    l_total_pgs  PLS_INTEGER;
    l_date_str   VARCHAR2(30);
    l_result     BLOB;
  BEGIN
    l_total_pgs := rad_pdf_serial.page_count(p_doc);
    l_conf      := rad_pdf_ctx.get_conformance(p_doc);

    -- 2. Font resource objects (PDF/A: every used font must be embedded)
    IF l_conf IS NOT NULL THEN
      rad_pdf_fonts.assert_all_embedded(p_doc);
    END IF;
    l_font_res := rad_pdf_fonts.write_font_objects(p_doc);

    -- 3. Image resource objects
    l_img_res := rad_pdf_images.write_image_objects(p_doc);

    -- 4. Page content streams + page dictionaries + Pages root
    l_pages_obj := rad_pdf_canvas.write_page_objects(p_doc, l_font_res, l_img_res);

    -- 5. Outline tree (NULL when no bookmarks); PDF/A objects; Catalog
    l_outline_obj := rad_pdf_canvas.write_outline_objects(p_doc);

    IF l_conf IS NOT NULL THEN
      -- One timestamp for BOTH the XMP packet and the Info dictionary:
      -- PDF/A validators check that they are consistent.
      l_ts       := rad_pdf_ctx.now_utc;
      l_date_iso := TO_CHAR(l_ts, 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

      -- sRGB OutputIntent (ICC profile stream + intent dictionary)
      l_icc := rad_pdf_codec.srgb_icc;
      l_icc_obj := rad_pdf_serial.write_stream_obj(p_doc, l_icc,
                     ' /N 3', TRUE);
      DBMS_LOB.FREETEMPORARY(l_icc);
      l_oi_obj := rad_pdf_serial.begin_obj(p_doc,
        '/Type /OutputIntent /S /GTS_PDFA1'
        || ' /OutputConditionIdentifier (sRGB)'
        || ' /Info (sRGB IEC61966-2.1)'
        || ' /DestOutputProfile ' || TO_CHAR(l_icc_obj) || ' 0 R');

      -- XMP metadata stream (must be UNCOMPRESSED per ISO 19005)
      l_doc_info := rad_pdf_ctx.get_info(p_doc);
      l_xmp := build_xmp(l_doc_info, l_date_iso);
      l_xmp_obj := rad_pdf_serial.write_stream_obj(p_doc, l_xmp,
                     ' /Type /Metadata /Subtype /XML', FALSE);
      DBMS_LOB.FREETEMPORARY(l_xmp);
    END IF;

    l_cat_obj := rad_pdf_serial.begin_obj(p_doc,
      ' /Type /Catalog /Pages ' || TO_CHAR(l_pages_obj) || ' 0 R '
      || CASE WHEN l_outline_obj IS NOT NULL THEN
           '/Outlines ' || TO_CHAR(l_outline_obj) || ' 0 R '
           || '/PageMode /UseOutlines '
         END
      || CASE WHEN l_conf IS NOT NULL THEN
           '/Metadata ' || TO_CHAR(l_xmp_obj) || ' 0 R '
           || '/OutputIntents [' || TO_CHAR(l_oi_obj) || ' 0 R] '
         END);

    -- 6. Info dictionary (PDF/A: dates and Producer/Creator must match XMP)
    l_doc_info  := rad_pdf_ctx.get_info(p_doc);
    IF l_conf IS NOT NULL THEN
      l_date_str := 'D:' || TO_CHAR(l_ts, 'YYYYMMDDHH24MISS') || 'Z';
    ELSE
      l_date_str := pdf_date;
    END IF;
    l_info_obj  := rad_pdf_serial.begin_obj(p_doc);
    rad_pdf_serial.doc_write(p_doc, '<<');
    IF l_doc_info.title    IS NOT NULL THEN
      rad_pdf_serial.doc_write(p_doc, '/Title ('    ||
                                  rad_pdf_codec.escape_pdf_str(l_doc_info.title)    || ')');
    END IF;
    IF l_doc_info.author   IS NOT NULL THEN
      rad_pdf_serial.doc_write(p_doc, '/Author ('   ||
                                  rad_pdf_codec.escape_pdf_str(l_doc_info.author)   || ')');
    END IF;
    IF l_doc_info.subject  IS NOT NULL THEN
      rad_pdf_serial.doc_write(p_doc, '/Subject ('  ||
                                  rad_pdf_codec.escape_pdf_str(l_doc_info.subject)  || ')');
    END IF;
    IF l_doc_info.keywords IS NOT NULL THEN
      rad_pdf_serial.doc_write(p_doc, '/Keywords (' ||
                                  rad_pdf_codec.escape_pdf_str(l_doc_info.keywords) || ')');
    END IF;
    rad_pdf_serial.doc_write(p_doc, '/Creator (RAD_PDF)');
    rad_pdf_serial.doc_write(p_doc, '/Producer (Oracle Database 19c+)');
    rad_pdf_serial.doc_write(p_doc, '/CreationDate (' || l_date_str || ')');
    rad_pdf_serial.doc_write(p_doc, '/ModDate ('      || l_date_str || ')');
    rad_pdf_serial.doc_write(p_doc, '>>');
    rad_pdf_serial.end_obj(p_doc);

    -- 7. Cross-reference table and trailer
    rad_pdf_serial.finish_doc(p_doc, l_cat_obj, l_info_obj, l_total_pgs);

    -- 8. Transfer the finished PDF BLOB; caller must FREETEMPORARY.
    -- 8. Transfer the finished PDF BLOB; caller must FREETEMPORARY.
    l_result := rad_pdf_serial.take_doc(p_doc);
    RETURN l_result;
  EXCEPTION
    WHEN OTHERS THEN
      IF DBMS_LOB.ISTEMPORARY(l_icc)=1 THEN DBMS_LOB.FREETEMPORARY(l_icc); END IF;
      IF DBMS_LOB.ISTEMPORARY(l_xmp)=1 THEN DBMS_LOB.FREETEMPORARY(l_xmp); END IF;
      IF DBMS_LOB.ISTEMPORARY(l_result)=1 THEN DBMS_LOB.FREETEMPORARY(l_result); END IF;
      RAISE;
  END assemble;

END rad_pdf_doc;
/
