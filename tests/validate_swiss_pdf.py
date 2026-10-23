#!/usr/bin/env python3
"""Independent Swiss QR/PDF checks for fixtures exported as PDFNAME/PAYLOADHEX/PDFHEX.

Usage: python tests/validate_swiss_pdf.py sqlcl-export.log /tmp/swiss-checked
Test-only requirements: pip install zxing-cpp pillow; Poppler on PATH.
No external library is needed by RAD_PDF itself. Fixture log contains published
sample payment data only. Keep real payment data out of test exports.
"""
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import zxingcpp
from PIL import Image

from validate_pdf import validate


def check(log: Path, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    fixtures = {}
    current = None
    for line in log.read_text().splitlines():
        if line.startswith('PDFNAME:'):
            current = line[8:]
            assert re.fullmatch('[a-z_0-9]+', current), 'unsafe fixture name'
            assert current not in fixtures, 'duplicate fixture'
            fixtures[current] = {'pdf': bytearray()}
        elif line.startswith('PAYLOADHEX:'):
            assert current, 'payload without fixture name'
            fixtures[current]['payload'] = bytes.fromhex(line[11:])
        elif line.startswith('PDFHEX:'):
            assert current, 'PDF without fixture name'
            fixtures[current]['pdf'].extend(bytes.fromhex(line[7:]))
    assert {'qrr_integrated','scor_separate','non_blank'} <= set(fixtures), 'incomplete Swiss fixture export'
    namespace = {'h': 'http://www.w3.org/1999/xhtml'}
    for name, fixture in fixtures.items():
        pdf = output / (name + '.pdf')
        pdf.write_bytes(fixture['pdf'])
        validate(pdf)
        text_path = output / (name + '.txt')
        bbox = output / (name + '.html')
        subprocess.run(['pdftotext', '-layout', str(pdf), str(text_path)], check=True)
        subprocess.run(['pdftotext', '-bbox-layout', str(pdf), str(bbox)], check=True)
        pages = ET.parse(bbox).getroot().findall('.//h:page', namespace)
        assert pages, 'no PDF pages'
        dpi = 300
        for page_nr, page in enumerate(pages, 1):
            image_path = output / f'{name}_{page_nr}'
            subprocess.run(['pdftoppm', '-f', str(page_nr), '-l', str(page_nr),
                            '-r', str(dpi), '-png', '-singlefile', str(pdf), str(image_path)], check=True)
            decoded = zxingcpp.read_barcodes(Image.open(str(image_path) + '.png'))
            if page_nr != len(pages):
                assert not decoded, 'payment code appeared before the final page'
                # Integrated invoice rows must remain outside the 115 mm reserve.
                if name == 'qrr_integrated':
                    for word in page.findall('.//h:word', namespace):
                        if (word.text or '').startswith('INVOICE_ROW_'):
                            assert float(word.attrib['yMax']) < float(page.attrib['height']) - 115 * 72 / 25.4
                continue
            assert len(decoded) == 1, f'{name}: expected exactly one readable QR'
            code = decoded[0]
            assert code.ec_level == 'M', f'{name}: incorrect error correction level'
            assert int(code.extra['Version']) <= 25, f'{name}: QR version exceeds 25'
            assert code.symbology_identifier == ']Q1', f'{name}: unexpected ECI/FNC1 mode'
            assert code.bytes == fixture['payload'], f'{name}: decoded payload differs byte-for-byte'
            assert code.bytes.startswith(b'SPC\n0200\n1\n') and not code.bytes.endswith(b'\n')
            points = [code.position.top_left, code.position.top_right,
                      code.position.bottom_left, code.position.bottom_right]
            left = min(p.x for p in points) * 25.4 / dpi
            right = max(p.x for p in points) * 25.4 / dpi
            top = min(p.y for p in points) * 25.4 / dpi
            page_height = float(page.attrib['height']) * 25.4 / 72
            assert abs(left - 67) < 0.3, f'{name}: QR x position {left}'
            assert abs(right - left - 46) < 0.3, f'{name}: QR width {right-left}'
            assert abs(top - (page_height - 88)) < 0.3, f'{name}: QR y position {top}'
            # Quiet zone is 5 mm; sample points outside symbol excluding nearby text.
            image = Image.open(str(image_path) + '.png').convert('RGB')
            for x_mm, bottom_mm in [(65, 65), (115, 65), (90, 90), (90, 40)]:
                pixel = image.getpixel((round(x_mm * dpi / 25.4), round((page_height-bottom_mm) * dpi / 25.4)))
                assert min(pixel) > 245, f'{name}: quiet zone contaminated'
        text = text_path.read_text()
        if name == 'qrr_integrated':
            for row in range(1, 121):
                assert re.search(r'\bINVOICE_ROW_' + str(row) + r'\b', text), f'missing invoice row {row}'
            assert text.count('Sezione pagamento') == 1
            assert '2 500.25' in text and 'eBill' in text
        if name == 'non_blank':
            assert text.count('Monnaie') == 2, 'French currency label wrapped/was truncated'
        if name == 'extended_cid':
            assert 'ĀœȘț€' in text, 'extended Latin was replaced/lost in visible text'
        if name == 'scor_separate':
            assert len(pages) == 2 and 'RF18 5390 0754 7034' in text
        print(f'PASS {name}: UTF-8 QR payload, 46 mm symbol at (67,42) mm, quiet zone, {len(pages)} pages')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    check(Path(sys.argv[1]), Path(sys.argv[2]))
