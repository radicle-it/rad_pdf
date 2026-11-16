#!/usr/bin/env python3
"""The fidelity of a PDF against Word's export of the same document (middleware-docs 96a §10, point 2):

    python3 tests/word/fidelity.py OURS.pdf WORD.pdf

    pages      the same number of pages
    lines      the lines of text equal (the same words, in order) -- the measure of "a capo uguali": a paragraph
               whose lines are all equal breaks as Word does; reported as the share of Word's lines found equal
    positions  every word matched in order on its page (the same text): the deviation of its box (x and y of the
               top-left corner, from pdftotext -bbox) in points; maximum and 95th percentile
    pixels     per page, rendered at 72 dpi in grey: the share of pixels differing by more than 64 grey levels
               (the substituted font draws its own glyphs: never 0)

Thresholds of 96a §10 checked: same pages, lines >= 95 %, deviations <= 2 pt; pixels reported per page with the
threshold PIXEL_LIMIT declared below. Tools: pdfinfo, pdftotext, pdftoppm (poppler), Pillow.
"""
import difflib
import html
import re
import subprocess
import sys
import tempfile
from pathlib import Path

PIXEL_LIMIT = 0.03          # share of the page's pixels that may differ (substituted glyphs, antialiasing)
POS_LIMIT = 2.0             # points (96a §10)
LINES_LIMIT = 0.95          # 96a §10


def run(args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def pages(pdf):
    return int(re.search(r'^Pages:\s+(\d+)', run(['pdfinfo', str(pdf)]), re.M).group(1))


def layout(pdf):
    """per page: the lines (each a list of (word, xMin, yMin))"""
    xml = run(['pdftotext', '-bbox-layout', str(pdf), '-'])
    result = []
    for page in re.findall(r'<page .*?</page>', xml, re.S):
        lines = []
        for line in re.findall(r'<line .*?</line>', page, re.S):
            words = [(html.unescape(w), float(x), float(y)) for x, y, w in
                     re.findall(r'<word xMin="([\d.]+)" yMin="([\d.]+)"[^>]*>(.*?)</word>', line)]
            if words:
                lines.append(words)
        result.append(lines)
    return result


def compare(ours, word):
    out = {'pages': (pages(ours), pages(word))}
    lo, lw = layout(ours), layout(word)
    eq_lines = tot_lines = 0
    dev = []
    for p in range(min(len(lo), len(lw))):
        so = [' '.join(w for w, _, _ in ln) for ln in lo[p]]
        sw = [' '.join(w for w, _, _ in ln) for ln in lw[p]]
        sm = difflib.SequenceMatcher(None, so, sw, autojunk=False)
        eq_lines += sum(b.size for b in sm.get_matching_blocks())
        tot_lines += len(sw)
        wo = [w for ln in lo[p] for w in ln]
        ww = [w for ln in lw[p] for w in ln]
        sm = difflib.SequenceMatcher(None, [w for w, _, _ in wo], [w for w, _, _ in ww], autojunk=False)
        for b in sm.get_matching_blocks():
            for i in range(b.size):
                (_, xo, yo), (_, xw, yw) = wo[b.a + i], ww[b.b + i]
                dev.append(max(abs(xo - xw), abs(yo - yw)))
    dev.sort()
    out['lines'] = (eq_lines, tot_lines)
    out['words'] = len(dev)
    out['dev_max'] = dev[-1] if dev else None
    out['dev_p95'] = dev[int(0.95 * (len(dev) - 1))] if dev else None
    out['pixels'] = pixels(ours, word, min(out['pages']))
    return out


def pixels(ours, word, n):
    from PIL import Image, ImageChops
    res = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, pdf in (('o', ours), ('w', word)):
            subprocess.run(['pdftoppm', '-r', '72', '-gray', '-png', str(pdf), str(Path(tmp) / name)], check=True)
        for p in range(1, n + 1):
            a = Image.open(next(Path(tmp).glob(f'o-{p}.png')))
            b = Image.open(next(Path(tmp).glob(f'w-{p}.png')))
            if a.size != b.size:
                b = b.resize(a.size)
            diff = ImageChops.difference(a, b).point(lambda v: 255 if v > 64 else 0)
            hist = diff.histogram()
            res.append(hist[255] / (a.size[0] * a.size[1]))
    return res


def report(ours, word):
    r = compare(ours, word)
    po, pw = r['pages']
    eq, tot = r['lines']
    ok_pages = po == pw
    ok_lines = tot and eq / tot >= LINES_LIMIT
    ok_pos = r['dev_max'] is not None and r['dev_max'] <= POS_LIMIT
    ok_pix = all(v <= PIXEL_LIMIT for v in r['pixels'])
    print(f'fidelity pages: {po} vs Word {pw} -> {"OK" if ok_pages else "FAIL"}')
    print(f'fidelity lines: {eq}/{tot} equal ({100 * eq / tot:.1f} %, threshold {100 * LINES_LIMIT:.0f} %) -> {"OK" if ok_lines else "FAIL"}')
    print(f'fidelity positions: {r["words"]} words matched, max {r["dev_max"]:.2f} pt, p95 {r["dev_p95"]:.2f} pt '
          f'(threshold {POS_LIMIT} pt) -> {"OK" if ok_pos else "FAIL"}')
    print('fidelity pixels per page: ' + ', '.join(f'{100 * v:.2f} %' for v in r['pixels'])
          + f' (threshold {100 * PIXEL_LIMIT:.0f} %) -> {"OK" if ok_pix else "FAIL"}')
    return ok_pages and ok_lines and ok_pos and ok_pix


if __name__ == '__main__':
    sys.exit(0 if report(Path(sys.argv[1]), Path(sys.argv[2])) else 1)
