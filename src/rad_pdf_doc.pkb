CREATE OR REPLACE PACKAGE BODY rad_pdf_doc IS

  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_error VARCHAR2(4000);

    -- the first error only: its package, message and backtrace (the original exception cannot be re-raised once the
    -- other closers have run, so close_doc raises c_err_internal with this text)
    PROCEDURE note(p_package IN VARCHAR2) IS
    BEGIN
      IF l_error IS NULL THEN
        l_error := SUBSTR(p_package || ': ' || SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
      END IF;
    END note;
  BEGIN
    IF p_doc IS NULL THEN RETURN; END IF;
    IF NOT rad_pdf_ctx.is_valid(p_doc) THEN
      rad_pdf_ctx.release_doc(p_doc);
      RETURN;
    END IF;
    -- the highest level first; every closer runs even when one before it fails
    BEGIN rad_pdf_template.close_doc(p_doc); EXCEPTION WHEN OTHERS THEN note('rad_pdf_template'); END;
    BEGIN rad_pdf_layout.close_doc(p_doc);   EXCEPTION WHEN OTHERS THEN note('rad_pdf_layout');   END;
    BEGIN rad_pdf_table.close_doc(p_doc);    EXCEPTION WHEN OTHERS THEN note('rad_pdf_table');    END;
    BEGIN rad_pdf_canvas.close_doc(p_doc);   EXCEPTION WHEN OTHERS THEN note('rad_pdf_canvas');   END;
    BEGIN rad_pdf_images.close_doc(p_doc);   EXCEPTION WHEN OTHERS THEN note('rad_pdf_images');   END;
    BEGIN rad_pdf_fonts.close_doc(p_doc);    EXCEPTION WHEN OTHERS THEN note('rad_pdf_fonts');    END;
    BEGIN rad_pdf_serial.close_doc(p_doc);   EXCEPTION WHEN OTHERS THEN note('rad_pdf_serial');   END;
    rad_pdf_ctx.release_doc(p_doc);
    IF l_error IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_internal, 'Document cleanup: ' || l_error);
    END IF;
  END close_doc;

END rad_pdf_doc;
/
