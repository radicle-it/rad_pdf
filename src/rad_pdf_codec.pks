CREATE OR REPLACE PACKAGE rad_pdf_codec AUTHID DEFINER IS
/*
  rad_pdf_codec — stateless binary utilities for PDF generation.
  Oracle 19c+. No package-level state.

  All functions are pure (no side effects other than LOB allocation for BLOB returns).
  The BLOB returned by flate_encode is a temporary LOB; the caller must call
  DBMS_LOB.FREETEMPORARY when done.
*/

-- ---------------------------------------------------------------------------
-- Compression
-- ---------------------------------------------------------------------------

  -- Flate (zlib FlateDecode) encoding for PDF streams.
  -- Input BLOB is read but not modified (IN OUT NOCOPY for efficiency only).
  -- Returns a new temporary SESSION BLOB containing the compressed payload
  -- with a correct Adler32 checksum appended.
  FUNCTION flate_encode(p_src IN OUT NOCOPY BLOB) RETURN BLOB;

  -- Decompress a zlib RFC-1950 stream (2-byte header + deflate + 4-byte Adler32).
  -- p_uncompressed_len must be the exact expected byte count of the output.
  -- Returns a new temporary SESSION BLOB of decompressed bytes.
  -- Raises the underlying Oracle error if decompression fails.
  FUNCTION flate_decode(p_src             IN BLOB,
                        p_uncompressed_len IN NUMBER) RETURN BLOB;

  -- Adler32 checksum as 8-character uppercase hex.
  FUNCTION adler32(p_src IN BLOB) RETURN VARCHAR2;

-- ---------------------------------------------------------------------------
-- Hash
-- ---------------------------------------------------------------------------

  -- SHA-256 as 64-character lowercase hex string.
  -- Used by rad_pdf_images as image cache key.
  FUNCTION sha256_hex(p_blob IN BLOB) RETURN VARCHAR2;

-- ---------------------------------------------------------------------------
-- PDF numeric formatting
-- ---------------------------------------------------------------------------

  -- Format a NUMBER for use in PDF stream operators.
  -- Always uses '.' as decimal separator regardless of NLS settings.
  FUNCTION fmt(p_value IN NUMBER, p_decimals IN PLS_INTEGER DEFAULT 3)
    RETURN VARCHAR2;

-- ---------------------------------------------------------------------------
-- PDF string helpers
-- ---------------------------------------------------------------------------

  -- Escape a string for use inside PDF string objects (parentheses notation).
  -- Escapes: '\' → '\\', '(' → '\(', ')' → '\)'.
  FUNCTION escape_pdf_str(p_str IN VARCHAR2) RETURN VARCHAR2;

  -- Convert a 6-char hex RGB to PDF colour operator triple ('R G B').
  -- e.g. 'ff8000' → '1 0.502 0'
  FUNCTION rgb_to_pdf(p_rgb IN rad_pdf_types.t_rgb) RETURN VARCHAR2;

-- ---------------------------------------------------------------------------
-- PDF/A support (v1.7.0)
-- ---------------------------------------------------------------------------

  -- Minimal sRGB ICC v2 profile (456 bytes) for the PDF/A OutputIntent.
  -- Source: Compact-ICC-Profiles "sRGB-v2-micro" (CC0 / public domain,
  -- https://github.com/saucecontrol/Compact-ICC-Profiles).
  -- Returns a temporary SESSION BLOB; caller frees it.
  FUNCTION srgb_icc RETURN BLOB;

  -- Escape &, < and > for XML text nodes (XMP metadata).
  FUNCTION xml_escape(p_str IN VARCHAR2) RETURN VARCHAR2;

END rad_pdf_codec;
/
