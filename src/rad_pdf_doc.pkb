CREATE OR REPLACE PACKAGE BODY rad_pdf_doc IS

  PROCEDURE close_doc(p_doc IN rad_pdf_types.t_doc_handle) IS
    l_error VARCHAR2(2000);
  BEGIN
    IF p_doc IS NULL THEN RETURN; END IF;
    IF NOT rad_pdf_ctx.is_valid(p_doc) THEN
      rad_pdf_ctx.release_doc(p_doc);
      RETURN;
    END IF;
    -- the highest level first
    BEGIN rad_pdf_template.close_doc(p_doc);
    EXCEPTION WHEN OTHERS THEN l_error := NVL(l_error,SQLERRM); END;
    BEGIN rad_pdf_layout.close_doc(p_doc);
    EXCEPTION WHEN OTHERS THEN l_error := NVL(l_error,SQLERRM); END;
    BEGIN rad_pdf_table.close_doc(p_doc);
    EXCEPTION WHEN OTHERS THEN l_error := NVL(l_error,SQLERRM); END;
    BEGIN rad_pdf_canvas.close_doc(p_doc);
    EXCEPTION WHEN OTHERS THEN l_error := NVL(l_error,SQLERRM); END;
    BEGIN rad_pdf_images.close_doc(p_doc);
    EXCEPTION WHEN OTHERS THEN l_error := NVL(l_error,SQLERRM); END;
    BEGIN rad_pdf_fonts.close_doc(p_doc);
    EXCEPTION WHEN OTHERS THEN l_error := NVL(l_error,SQLERRM); END;
    BEGIN rad_pdf_serial.close_doc(p_doc);
    EXCEPTION WHEN OTHERS THEN l_error := NVL(l_error,SQLERRM); END;
    rad_pdf_ctx.release_doc(p_doc);
    IF l_error IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(rad_pdf_types.c_err_internal,'Document cleanup: '||l_error);
    END IF;
  END close_doc;

END rad_pdf_doc;
/
