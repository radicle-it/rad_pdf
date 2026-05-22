-- rad_pdf_img_decoder.sql — abstract base type for image format decoders.
-- NOT INSTANTIABLE: cannot be used directly; must be sub-typed.
-- NOT FINAL: subtypes (rad_pdf_jpeg_decoder, rad_pdf_png_decoder, rad_pdf_gif_decoder)
--            override detect() and decode().
CREATE OR REPLACE TYPE rad_pdf_img_decoder FORCE AS OBJECT (

  -- Oracle requires at least one attribute in an object type.
  -- Concrete subtypes inherit this field; pass NULL when instantiating.
  dummy_ NUMBER,

  -- Returns 1 if the first bytes of the image identify this format, 0 otherwise.
  -- p_header: first 16 bytes of the image file (may be shorter for very small files).
  MEMBER FUNCTION detect(p_header IN RAW) RETURN NUMBER,

  -- Decodes the full image blob and returns a populated rad_pdf_img_data instance.
  -- The pixels BLOB inside the result is a SESSION-scoped temporary LOB;
  -- the caller is responsible for DBMS_LOB.FREETEMPORARY when done.
  MEMBER FUNCTION decode(p_blob IN BLOB) RETURN rad_pdf_img_data

) NOT INSTANTIABLE NOT FINAL;
/
