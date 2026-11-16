CREATE OR REPLACE PACKAGE BODY rad_pdf_doc IS

  -- RAISE_APPLICATION_ERROR takes at most 2048 bytes of message
  c_max_msg_bytes CONSTANT PLS_INTEGER := 2048;
  c_prefix        CONSTANT VARCHAR2(30) := 'Document cleanup: ';

  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_head  VARCHAR2(4000);   -- package, code and message of the first failure
    l_trace VARCHAR2(4000);   -- its backtrace

    -- the first failure only: its package and error stack (code and message: SQLERRM would stop at 512 bytes) first,
    -- then the backtrace in the bytes left
    PROCEDURE note(p_package IN VARCHAR2) IS
    BEGIN
      IF l_head IS NULL THEN
        l_head  := SUBSTRB(p_package || ': ' || RTRIM(DBMS_UTILITY.FORMAT_ERROR_STACK, CHR(10)), 1, 1500);
        l_trace := SUBSTRB(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 2000);
      END IF;
    END note;

    -- every closer runs; a failure is noted and the next one runs
    PROCEDURE run(p_package IN VARCHAR2) IS
    BEGIN
      $IF $$rad_pdf_test $THEN
      -- fault injection, compiled only with PLSQL_CCFLAGS='rad_pdf_test:TRUE' (tests/phase22_doc_isolation.sql):
      -- CLIENT_INFO 'rad_pdf_fault=<package>' makes that closer fail before it closes anything, with a long multibyte
      -- message
      IF SYS_CONTEXT('USERENV', 'CLIENT_INFO') = 'rad_pdf_fault=' || p_package THEN
        RAISE_APPLICATION_ERROR(-20990, 'injected fault in ' || p_package || ' ' || RPAD(UNISTR('\00E9'), 900, UNISTR('\00E9')));
      END IF;
      $END
      CASE p_package
        WHEN 'rad_pdf_template' THEN rad_pdf_template.close_doc(p_doc);
        WHEN 'rad_pdf_layout'   THEN rad_pdf_layout.close_doc(p_doc);
        WHEN 'rad_pdf_table'    THEN rad_pdf_table.close_doc(p_doc);
        WHEN 'rad_pdf_canvas'   THEN rad_pdf_canvas.close_doc(p_doc);
        WHEN 'rad_pdf_images'   THEN rad_pdf_images.close_doc(p_doc);
        WHEN 'rad_pdf_fonts'    THEN rad_pdf_fonts.close_doc(p_doc);
        WHEN 'rad_pdf_serial'   THEN rad_pdf_serial.close_doc(p_doc);
      END CASE;
    EXCEPTION
      WHEN OTHERS THEN note(p_package);
    END run;
  BEGIN
    IF p_doc IS NULL THEN RETURN; END IF;
    IF NOT rad_pdf_ctx.is_valid(p_doc) THEN
      rad_pdf_ctx.release_doc(p_doc);
      RETURN;
    END IF;
    -- the highest level first
    run('rad_pdf_template');
    run('rad_pdf_layout');
    run('rad_pdf_table');
    run('rad_pdf_canvas');
    run('rad_pdf_images');
    run('rad_pdf_fonts');
    run('rad_pdf_serial');
    rad_pdf_ctx.release_doc(p_doc);
    IF l_head IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_internal,
        SUBSTRB(c_prefix || l_head || CHR(10) || l_trace, 1, c_max_msg_bytes));
    END IF;
  END close_doc;

END rad_pdf_doc;
/
