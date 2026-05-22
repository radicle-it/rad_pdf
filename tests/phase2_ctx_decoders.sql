-- phase2_ctx_decoders.sql — acceptance tests for Phase 2
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  l_ok   PLS_INTEGER := 0;
  l_fail PLS_INTEGER := 0;

  PROCEDURE ok(p_label IN VARCHAR2, p_cond IN BOOLEAN) IS
  BEGIN
    IF p_cond THEN
      DBMS_OUTPUT.PUT_LINE('PASS  ' || p_label); l_ok := l_ok + 1;
    ELSE
      DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_label); l_fail := l_fail + 1;
    END IF;
  END;

  PROCEDURE ok(p_label IN VARCHAR2, p_got IN VARCHAR2, p_exp IN VARCHAR2) IS
  BEGIN
    ok(p_label, NVL(p_got,'<null>') = NVL(p_exp,'<null>'));
  END;

BEGIN
  -- =========================================================================
  -- rad_pdf_ctx — handle lifecycle
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_doc2 rad_pdf_types.t_doc_handle;
    l_info rad_pdf_types.t_doc_info;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    ok('new_doc > 0',          l_doc > 0);
    ok('is_valid after new',   rad_pdf_ctx.is_valid(l_doc));

    l_doc2 := rad_pdf_ctx.new_doc;
    ok('two handles distinct', l_doc != l_doc2);

    rad_pdf_ctx.close_doc(l_doc);
    ok('invalid after close',  NOT rad_pdf_ctx.is_valid(l_doc));

    rad_pdf_ctx.close_doc(l_doc);  -- idempotent: must not raise
    ok('close idempotent',     TRUE);

    ok('NULL not valid',       NOT rad_pdf_ctx.is_valid(NULL));

    -- set_info / get_info round-trip
    l_info.title  := 'Test Doc';
    l_info.author := 'Test Author';
    rad_pdf_ctx.set_info(l_doc2, l_info);
    DECLARE l_r rad_pdf_types.t_doc_info; BEGIN
      l_r := rad_pdf_ctx.get_info(l_doc2);
      ok('get_info title',  l_r.title,  'Test Doc');
      ok('get_info author', l_r.author, 'Test Author');
    END;

    -- assert_valid raises on closed handle
    DECLARE l_raised BOOLEAN := FALSE; BEGIN
      BEGIN
        rad_pdf_ctx.assert_valid(l_doc);
      EXCEPTION WHEN OTHERS THEN l_raised := TRUE;
      END;
      ok('assert_valid raises', l_raised);
    END;

    rad_pdf_ctx.close_doc(l_doc2);
  END;

  -- =========================================================================
  -- rad_pdf_img_data — constructor
  -- =========================================================================
  DECLARE l_b BLOB; l_d rad_pdf_img_data; BEGIN
    DBMS_LOB.CREATETEMPORARY(l_b, TRUE);
    l_d := rad_pdf_img_data('JPG', 100, 200, 8, 3, 0, NULL, l_b, NULL);
    ok('img_data img_type', l_d.img_type, 'JPG');
    ok('img_data width',    l_d.width  = 100);
    ok('img_data height',   l_d.height = 200);
    ok('img_data greyscale', l_d.greyscale = 0);
    DBMS_LOB.FREETEMPORARY(l_b);
  END;

  -- =========================================================================
  -- Decoder detect methods
  -- =========================================================================
  DECLARE l_dec rad_pdf_img_decoder := rad_pdf_jpeg_decoder(NULL); BEGIN
    ok('jpeg detect FFD8',    l_dec.detect(HEXTORAW('FFD8FFE000104A464946')) = 1);
    ok('jpeg detect not png', l_dec.detect(HEXTORAW('89504E470D0A1A0A0000')) = 0);
    ok('jpeg detect null',    l_dec.detect(NULL) = 0);
  END;

  DECLARE l_dec rad_pdf_img_decoder := rad_pdf_png_decoder(NULL); BEGIN
    ok('png detect sig',      l_dec.detect(HEXTORAW('89504E470D0A1A0A0000')) = 1);
    ok('png detect not jpeg', l_dec.detect(HEXTORAW('FFD8FFE000104A464946')) = 0);
  END;

  DECLARE l_dec rad_pdf_img_decoder := rad_pdf_gif_decoder(NULL); BEGIN
    ok('gif detect GIF',      l_dec.detect(UTL_RAW.CAST_TO_RAW('GIF89a      ')) = 1);
    ok('gif detect not jpeg', l_dec.detect(HEXTORAW('FFD8FFE000104A464946')) = 0);
  END;

  -- =========================================================================
  -- Polymorphic dispatch
  -- =========================================================================
  DECLARE
    TYPE t_decoders IS TABLE OF rad_pdf_img_decoder;
    l_decoders t_decoders := t_decoders(
      rad_pdf_jpeg_decoder(NULL),
      rad_pdf_png_decoder(NULL),
      rad_pdf_gif_decoder(NULL)
    );
    l_jpeg_hdr RAW(16) := HEXTORAW('FFD8FFE000104A464946460001010000');
    l_png_hdr  RAW(16) := HEXTORAW('89504E470D0A1A0A0000000D49484452');
    l_gif_hdr  RAW(16) := UTL_RAW.CONCAT(
                            UTL_RAW.CAST_TO_RAW('GIF89a'),
                            HEXTORAW('FFFFFFFFFF'));
    l_matched  VARCHAR2(10);
  BEGIN
    FOR i IN 1..3 LOOP
      IF l_decoders(i).detect(l_jpeg_hdr) = 1 THEN l_matched := 'jpeg'; END IF;
    END LOOP;
    ok('dispatch jpeg', l_matched, 'jpeg');

    l_matched := NULL;
    FOR i IN 1..3 LOOP
      IF l_decoders(i).detect(l_png_hdr) = 1 THEN l_matched := 'png'; END IF;
    END LOOP;
    ok('dispatch png', l_matched, 'png');

    l_matched := NULL;
    FOR i IN 1..3 LOOP
      IF l_decoders(i).detect(l_gif_hdr) = 1 THEN l_matched := 'gif'; END IF;
    END LOOP;
    ok('dispatch gif', l_matched, 'gif');
  END;

  -- =========================================================================
  -- Summary
  -- =========================================================================
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('Phase 2: ' || l_ok || ' passed, ' || l_fail || ' failed.');
  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Phase 2 FAILED: ' || l_fail || ' failure(s)');
  END IF;
END;
/
