#!/usr/bin/env python3
"""The fonts of the Word tests (D3, middleware-docs 96a §9) in the test schema: the table rad_pdf_test_font (a TEST
object, never in src/: in the middleware the fonts are att_ files of PDF_FONT) with Liberation Sans in its four
variants, the free substitute of Arial.

    python3 tests/word/load_fonts.py [DIR]    DIR: the folder of LiberationSans-{Regular,Bold,Italic,BoldItalic}.ttf
                                              (default: $RAD_PDF_FONT_DIR, else the Homebrew cask font-liberation)

Liberation fonts 2.1.5, SIL Open Font License 1.1 (https://github.com/liberationfonts/liberation-fonts): free to use,
embed and redistribute. The script prints the SHA-256 of each file loaded, recorded in the test report.
"""
import base64
import glob
import hashlib
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'golden'))
import bench  # noqa: E402

VARIANTS = {'R': 'Regular', 'B': 'Bold', 'I': 'Italic', 'X': 'BoldItalic'}
TABLE = """DECLARE
  l_n PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = 'RAD_PDF_TEST_FONT';
  IF l_n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE TABLE rad_pdf_test_font (family VARCHAR2(100), variant CHAR(1), sha256 VARCHAR2(64), '
                   || 'bytes BLOB, CONSTRAINT rad_pdf_test_font_pk PRIMARY KEY (family, variant))';
  END IF;
END;
/
"""


def font_dir(argv):
    if len(argv) > 1:
        return Path(argv[1])
    if os.environ.get('RAD_PDF_FONT_DIR'):
        return Path(os.environ['RAD_PDF_FONT_DIR'])
    found = sorted(glob.glob('/opt/homebrew/Caskroom/font-liberation/*/liberation-fonts-ttf-*'))
    if not found:
        sys.exit('no font folder: pass DIR or set RAD_PDF_FONT_DIR')
    return Path(found[-1])


def main():
    d = font_dir(sys.argv)
    script = [TABLE]
    for v, name in VARIANTS.items():
        data = (d / f'LiberationSans-{name}.ttf').read_bytes()
        sha = hashlib.sha256(data).hexdigest()
        b64 = base64.b64encode(data).decode('ascii')
        chunks = '\n'.join(f"  DBMS_LOB.APPEND(l_c, '{b64[i:i + 30000]}');" for i in range(0, len(b64), 30000))
        script.append(f"""DECLARE
  l_c CLOB;
  l_b BLOB;
BEGIN
  DBMS_LOB.CREATETEMPORARY(l_c, TRUE);
{chunks}
  l_b := rad_pdf_codec.base64_decode(l_c);
  DELETE FROM rad_pdf_test_font WHERE family = 'Liberation Sans' AND variant = '{v}';
  INSERT INTO rad_pdf_test_font VALUES ('Liberation Sans', '{v}', '{sha}', l_b);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('LOADED:{v}:' || DBMS_LOB.GETLENGTH(l_b) || ':{sha}');
  DBMS_LOB.FREETEMPORARY(l_b);
  DBMS_LOB.FREETEMPORARY(l_c);
END;
/
""")
    rc, out = bench.sqlcl('\n'.join(script))
    loaded = [line for line in out.splitlines() if line.startswith('LOADED:')]
    for line in loaded:
        print(line)
    if rc or len(loaded) != 4:
        sys.exit('load failed:\n' + out[-2000:])


if __name__ == '__main__':
    main()
