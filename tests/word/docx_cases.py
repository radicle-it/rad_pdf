#!/usr/bin/env python3
"""Step B4 of the Word evolution: the reader (rad_pdf_docx, rad_pdf_zip) on generated templates -- middleware-docs
96a §6 (tags), §7.2 (the degradation matrix), §7.3 (the report), §8 (security and budgets).

    python3 tests/word/docx_cases.py          build every case, read each one in the test schema (the golden bench's
                                              connection), check the outcome; exit 1 on any mismatch
    python3 tests/word/docx_cases.py NAME...  only these cases

Each case is a small .docx written here (the XML by hand, the ZIP by zipfile or, for the hostile packages, by a ZIP
writer that can lie) and one expected outcome:
  - ERRORS {codes}     the report holds exactly these ERROR codes (the version would not be published), no RI;
  - WARNS {codes}      no error, at least these WARNING codes, an RI;
  - RI [texts]         no error, an RI whose canonical JSON holds every text;
  - RAISE (code, text) the package is refused: [PDF_DOCX] or [PDF_BUDGET], the message holding the text.
The last cases read two templates in one session, the second after a refused package, and compare the results with
the first reads (no state left behind).
"""
import base64
import json
import struct
import sys
import zipfile
import zlib
from io import BytesIO
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'golden'))
import bench  # noqa: E402

NS = ('xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" '
      'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
      'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" '
      'xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"')
REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
CT_DOC = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'
SECT = ('<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1417" w:right="1134" w:bottom="1134" '
        'w:left="1134" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>')
STYLES = ('<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:sz w:val="20"/></w:rPr>'
          '</w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="0"/></w:pPr></w:pPrDefault></w:docDefaults>'
          '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
          '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr>'
          '<w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr>'
          '</w:style>')
# a table style with a conditional format (96a §7.2: error)
COND_STYLE = ('<w:style w:type="table" w:styleId="Banded"><w:name w:val="Banded"/><w:basedOn w:val="TableNormal"/>'
              '<w:tblStylePr w:type="firstRow"><w:rPr><w:b/></w:rPr></w:tblStylePr></w:style>')

SCHEMA = {'fields': [
    {'path': 'name', 'type': 'TEXT', 'required': 'Y'},
    {'path': 'code', 'type': 'TEXT', 'required': 'N'},
    {'path': 'flag', 'type': 'BOOLEAN', 'required': 'Y'},
    {'path': 'logo', 'type': 'IMAGE', 'required': 'N'},
    {'path': 'quote', 'type': 'OBJECT', 'required': 'Y'},
    {'path': 'quote.no', 'type': 'TEXT', 'required': 'Y'},
    {'path': 'lines', 'type': 'ARRAY', 'required': 'Y'},
    {'path': 'lines[].code', 'type': 'TEXT', 'required': 'N'},
    {'path': 'lines[].subs', 'type': 'ARRAY', 'required': 'N'},
    {'path': 'lines[].subs[].x', 'type': 'TEXT', 'required': 'N'},
    {'path': 'lines[].subs[].deep', 'type': 'ARRAY', 'required': 'N'},
    {'path': 'lines[].subs[].deep[].d4', 'type': 'ARRAY', 'required': 'N'},
    {'path': 'lines[].subs[].deep[].d4[].v', 'type': 'TEXT', 'required': 'N'},
]}


# ---------------------------------------------------------------------------------------------------------------
# WordprocessingML pieces
# ---------------------------------------------------------------------------------------------------------------
def esc(t):
    return t.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def R(text, rpr=''):
    return f'<w:r>{f"<w:rPr>{rpr}</w:rPr>" if rpr else ""}<w:t xml:space="preserve">{esc(text)}</w:t></w:r>'


def P(*runs, ppr=''):
    body = ''.join(r if r.startswith('<') else R(r) for r in runs)
    return f'<w:p>{f"<w:pPr>{ppr}</w:pPr>" if ppr else ""}{body}</w:p>'


def TC(*paras, tcpr='<w:tcW w:w="2000" w:type="dxa"/>'):
    return f'<w:tc><w:tcPr>{tcpr}</w:tcPr>{"".join(paras) or P()}</w:tc>'


def TR(*cells, trpr=''):
    return f'<w:tr>{f"<w:trPr>{trpr}</w:trPr>" if trpr else ""}{"".join(cells)}</w:tr>'


def TBL(*rows, cols=2, tblpr=''):
    grid = ''.join('<w:gridCol w:w="2000"/>' for _ in range(cols))
    return (f'<w:tbl><w:tblPr>{tblpr}<w:tblW w:w="0" w:type="auto"/><w:tblLayout w:type="fixed"/></w:tblPr>'
            f'<w:tblGrid>{grid}</w:tblGrid>{"".join(rows)}</w:tbl>')


def PIC(rid='rIdImg', cx=914400, cy=457200, blip_extra='', anchor=False, uri='http://schemas.openxmlformats.org/drawingml/2006/picture'):
    kind = 'anchor' if anchor else 'inline'
    return (f'<w:r><w:drawing><wp:{kind}><wp:extent cx="{cx}" cy="{cy}"/><wp:docPr id="1" name="p"/><a:graphic>'
            f'<a:graphicData uri="{uri}"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="i"/><pic:cNvPicPr/>'
            f'</pic:nvPicPr><pic:blipFill><a:blip r:embed="{rid}">{blip_extra}</a:blip><a:stretch><a:fillRect/>'
            f'</a:stretch></pic:blipFill><pic:spPr/></pic:pic></a:graphicData></a:graphic></wp:{kind}></w:drawing></w:r>')


def png(w, h):
    raw = b''.join(b'\x00' + b'\xff\x00\x00' * w for _ in range(h))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def png_header_only(w, h):
    """a PNG whose header claims w x h (the reader stops at the header)"""
    return png(1, 1)[:16] + struct.pack('>II', w, h) + png(1, 1)[24:]


def docx(*blocks, styles=STYLES, sect=SECT, rels=(), parts=None, ct=(), doc_xml=None, settings=None):
    """a minimal .docx: blocks = the body's XML pieces; rels = (Id, type suffix, target[, external]);
    parts = {name: bytes}; ct = extra Override"""
    body = ''.join(blocks)
    doc = doc_xml or f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document {NS}><w:body>{body}{sect}</w:body></w:document>'
    ext = ' TargetMode="External"'
    rl = ''.join(f'<Relationship Id="{r[0]}" Type="{REL}{r[1]}" Target="{r[2]}"'
                 f'{ext if len(r) > 3 and r[3] else ""}/>' for r in rels)
    files = {
        '[Content_Types].xml': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                                '<Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>'
                                '<Default Extension="emf" ContentType="image/x-emf"/>'
                                f'<Override PartName="/word/document.xml" ContentType="{CT_DOC}"/>'
                                + ''.join(f'<Override PartName="{n}" ContentType="{t}"/>' for n, t in ct) + '</Types>'),
        '_rels/.rels': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                        f'<Relationship Id="rId1" Type="{REL}officeDocument" Target="word/document.xml"/></Relationships>'),
        'word/document.xml': doc,
        'word/_rels/document.xml.rels': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                                         f'<Relationship Id="rIdSt" Type="{REL}styles" Target="styles.xml"/>{rl}</Relationships>'),
        'word/styles.xml': f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles {NS}>{styles}</w:styles>',
    }
    if settings:
        files['word/settings.xml'] = f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:settings {NS}>{settings}</w:settings>'
        files['word/_rels/document.xml.rels'] = files['word/_rels/document.xml.rels'].replace(
            '</Relationships>', f'<Relationship Id="rIdSe" Type="{REL}settings" Target="settings.xml"/></Relationships>')
    files.update(parts or {})
    buf = BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        for n, d in files.items():
            z.writestr(n, d if isinstance(d, bytes) else d.encode('utf-8'))
    return buf.getvalue()


def hdr(body, kind='hdr'):
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:{kind} {NS}>{body}</w:{kind}>'


# ---------------------------------------------------------------------------------------------------------------
# a ZIP writer that can lie (hostile packages)
# ---------------------------------------------------------------------------------------------------------------
def raw_zip(entries, central_extra=None):
    """entries: dicts name, data, method (0/8), flags, usize/csize overrides, offset (point the central record at
    another local header); central_extra: more central records (dicts like entries, with 'offset')"""
    out, central, offs = BytesIO(), [], {}
    for e in entries:
        data = e['data']
        comp = data if e.get('method', 8) == 0 else zlib.compressobj(9, zlib.DEFLATED, -15).compress(data) + zlib.compressobj(9, zlib.DEFLATED, -15).flush()
        if e.get('method', 8) == 8:
            co = zlib.compressobj(9, zlib.DEFLATED, -15)
            comp = co.compress(data) + co.flush()
        crc = zlib.crc32(data) & 0xffffffff
        name = e['name'].encode('utf-8')
        us, cs = e.get('usize', len(data)), e.get('csize', len(comp))
        offs[e['name']] = out.tell()
        out.write(struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, e.get('flags', 0), e.get('method', 8), 0, 0, crc, cs, us,
                              len(name), 0) + name + comp)
        central.append((name, e.get('flags', 0), e.get('method', 8), crc, cs, us, e.get('offset', offs[e['name']])))
    for c in central_extra or []:
        central.append((c['name'].encode(), 0, c.get('method', 0), c.get('crc', 0), c['csize'], c['usize'], c['offset']))
    cd = out.tell()
    for name, flags, method, crc, cs, us, off in central:
        out.write(struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 20, 20, flags, method, 0, 0, crc, cs, us, len(name),
                              0, 0, 0, 0, 0, off) + name)
    cdlen = out.tell() - cd
    out.write(struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, len(central), len(central), cdlen, cd, 0))
    return out.getvalue()


def entries_of(blob):
    """the entries of a normal .docx, to rebuild it with raw_zip"""
    z = zipfile.ZipFile(BytesIO(blob))
    return [{'name': i.filename, 'data': z.read(i.filename)} for i in z.infolist()]


BASE = docx(P('Hello ', '{name}'))


def with_entries(extra, base=BASE):
    return raw_zip(entries_of(base) + extra)


def bomb_text(n, keep=0.02):
    """n bytes that deflate to about n * keep: mostly zeros with a little noise"""
    import random
    rnd = random.Random(7)
    block = 1000
    k = max(1, int(block * keep))
    return b''.join(bytes(rnd.getrandbits(8) for _ in range(k)) + b'\0' * (block - k) for _ in range(n // block))


# ---------------------------------------------------------------------------------------------------------------
# the cases
# ---------------------------------------------------------------------------------------------------------------
IMG_REL = [('rIdImg', 'image', 'media/image1.png')]
CASES = {}


def case(name, blob, kind, expect):
    CASES[name] = (blob, kind, expect)


# ---- positive: what the subset does ---------------------------------------------------------------------------
case('pos_row_loop', docx(TBL(TR(TC(P('Code')), TC(P('Note')), trpr='<w:tblHeader/>'),
                              TR(TC(P('{#lines}{code}')), TC(P('-{/lines}'))))),
     'RI', ['"kind":"row_region","region":"LOOP","scope":null,"path":"lines"',
            '"kind":"tag","op":"FIELD","scope":"lines","path":"lines[].code"', '"header":"Y"'])
case('pos_one_cell_row', docx(TBL(TR(TC(P('{#lines}{code}{/lines}'))), cols=1)),
     'RI', ['"kind":"row_region","region":"LOOP"'])
case('pos_paragraph_loop', docx(P('{#lines}Line {code}'), P('second paragraph{/lines}'), P('after')),
     'RI', ['"kind":"block_region","region":"LOOP","scope":null,"path":"lines"'])
case('pos_inline_section', docx(P('Flag: {#flag}yes{/flag} end')),
     'RI', ['"kind":"inline_region","region":"SECTION","scope":null,"path":"flag"'])
case('pos_paragraph_section', docx(P('{#flag}The whole paragraph{/flag}')),
     'RI', ['"kind":"block_region","region":"SECTION"'])
case('pos_nested_scopes', docx(P('{#lines}{#subs}{x} of {code} for {quote.no}{/subs}{/lines}')),
     'RI', ['"scope":"lines","path":"lines[].subs"', '"scope":"lines[].subs","path":"lines[].subs[].x"',
            '"scope":"lines","path":"lines[].code"', '"scope":null,"path":"quote.no"'])
case('pos_inner_wins', docx(P('{#lines}{code}{/lines} and {code}')),
     'RI', ['"scope":"lines","path":"lines[].code"', '"scope":null,"path":"code"'])
case('pos_index_path', docx(P('First: {lines.0.code}')), 'RI', ['"scope":null,"path":"lines.0.code"'])
case('pos_tag_across_runs', docx(P(R('{na', '<w:b/>'), R('me}'), R(' {quote.'), R('no}', '<w:i/>'))),
     'RI', ['"op":"FIELD","scope":null,"path":"name","fmt":{"font":"Arial","size":10,"bold":"Y"',
            '"path":"quote.no","fmt":{"font":"Arial","size":10,"bold":"N","italic":"N"'])
case('pos_image_and_tags', docx(P('Logo ', PIC(), ' {%logo} {?flag}'), rels=IMG_REL,
                                parts={'word/media/image1.png': png(4, 2)}),
     'RI', ['"kind":"image"', '"op":"IMAGE","scope":null,"path":"logo"', '"op":"PAGEBREAK","scope":null,"path":"flag"',
            '"format":"PNG"'])
def noise_png(w, h):
    import random
    rnd = random.Random(3)
    raw = b''.join(b'\x00' + bytes(rnd.getrandbits(8) for _ in range(3 * w)) for _ in range(h))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


# an incompressible picture: deflate's worst case (csize x 1032) passes the budget, so the part is read by the
# bounded PL/SQL inflater (rad_pdf_codec.inflate_raw), not natively
case('pos_bounded_inflate', docx(P(PIC()), rels=IMG_REL, parts={'word/media/image1.png': noise_png(120, 120)}),
     'RI', ['"format":"PNG","px_w":120,"px_h":120'])
case('pos_page_break', docx(P('before', '<w:r><w:br w:type="page"/></w:r>', 'after'), P('next', ppr='<w:pageBreakBefore/>')),
     'RI', ['"text":"before"', '"kind":"page_break"', '"text":"after"'])
case('pos_fields_and_header', docx(P('{name}'), sect=SECT.replace('<w:pgSz', '<w:headerReference w:type="default" r:id="rIdH"/><w:pgSz'),
                                   rels=[('rIdH', 'header', 'header1.xml')],
                                   parts={'word/header1.xml': hdr(P('Page ', '<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
                                                                       '<w:r><w:instrText> PAGE \\* MERGEFORMAT </w:instrText></w:r>'
                                                                       '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
                                                                       '<w:r><w:t>9</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>'
                                                                       ' of <w:fldSimple w:instr=" NUMPAGES "><w:r><w:t>9</w:t></w:r></w:fldSimple>'))}),
     'RI', ['"kind":"field","code":"PAGE"', '"kind":"field","code":"NUMPAGES"', '"name":"header_default"'])
case('pos_styles_chain', docx(P('x', ppr='<w:pStyle w:val="Child"/>'),
                              styles=STYLES + '<w:style w:type="paragraph" w:styleId="Base"><w:basedOn w:val="Normal"/>'
                                     '<w:pPr><w:spacing w:before="240" w:line="360" w:lineRule="auto"/><w:jc w:val="center"/></w:pPr>'
                                     '<w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>'
                                     '<w:style w:type="paragraph" w:styleId="Child"><w:basedOn w:val="Base"/>'
                                     '<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr><w:rPr><w:color w:val="FF0000"/></w:rPr></w:style>'),
     'RI', ['"align":"C","ind_left":36,"ind_right":0,"ind_first":-18,"space_before":12,"space_after":0,"line_mult":1.5',
            '"fmt":{"font":"Arial","size":14,"bold":"Y","italic":"N","underline":"N","color":"FF0000"}'])
case('pos_tab_clear', docx(P('a', '<w:r><w:tab/></w:r>', 'b', ppr='<w:pStyle w:val="Tabbed"/><w:tabs><w:tab w:val="clear" w:pos="2000"/>'
                                                              '<w:tab w:val="decimal" w:pos="4000"/></w:tabs>'),
                           styles=STYLES + '<w:style w:type="paragraph" w:styleId="Tabbed"><w:pPr><w:tabs>'
                                  '<w:tab w:val="left" w:pos="2000"/><w:tab w:val="right" w:pos="3000"/></w:tabs></w:pPr></w:style>'),
     'RI', ['"tabs":[{"pos":150,"kind":"R"},{"pos":200,"kind":"D"}]'])

# ---- warnings: drawn approximately, reported -----------------------------------------------------------------
case('warn_matrix', docx(
    P('{name}', ppr='<w:spacing w:line="300" w:lineRule="exact"/><w:widowControl/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>'
                    '<w:tabs><w:tab w:val="center" w:pos="3000"/><w:tab w:val="right" w:leader="dot" w:pos="5000"/></w:tabs>'),
    P(R('marked', '<w:highlight w:val="yellow"/>'), '<w:hyperlink r:id="rIdL"><w:r><w:t>link</w:t></w:r></w:hyperlink>'),
    TBL(TR(TC(P('a'), tcpr='<w:tcW w:w="2000" w:type="dxa"/><w:vMerge w:val="restart"/><w:vAlign w:val="center"/>'), TC(P('b')),
           trpr='<w:trHeight w:val="400"/>'),
        TR(TC(P(), tcpr='<w:tcW w:w="2000" w:type="dxa"/><w:vMerge/>'), TC(P('c')))),
    rels=[('rIdL', 'hyperlink', 'https://example.invalid/', True)]),
    'WARNS', {'LINE_RULE', 'WIDOW', 'LIST', 'TAB_CENTER', 'TAB_LEADER', 'HIGHLIGHT', 'LINK', 'VMERGE', 'VALIGN', 'ROW_HEIGHT'})
case('warn_effects', docx(P(R('x', '<w:caps/><w:strike/><w:vertAlign w:val="superscript"/>')),
                          settings='<w:defaultTabStop w:val="709"/>'),
     'WARNS', {'RUN_EFFECT', 'DEFAULT_TAB'})

# ---- errors of the matrix (96a §7.2) and of the tags (§6) -----------------------------------------------------
case('err_field', docx(P('<w:fldSimple w:instr=" DATE \\@ &quot;dd/MM/yyyy&quot; "><w:r><w:t>1/1</w:t></w:r></w:fldSimple>')),
     'ERRORS', {'FIELD'})
case('err_nested_table', docx(TBL(TR(TC(P('a'), TBL(TR(TC(P('b')), TC(P('c'))))), TC(P('d'))))), 'ERRORS', {'NESTED_TABLE'})
case('err_anchored', docx(P(PIC(anchor=True)), rels=IMG_REL, parts={'word/media/image1.png': png(2, 2)}), 'ERRORS', {'ANCHORED'})
case('err_textbox', docx(P('<w:r><w:pict><v:shape xmlns:v="urn:schemas-microsoft-com:vml"><v:textbox/></v:shape></w:pict></w:r>')),
     'ERRORS', {'TEXTBOX'})
case('err_chart', docx(P(PIC(uri='http://schemas.openxmlformats.org/drawingml/2006/chart')), rels=IMG_REL,
                       parts={'word/media/image1.png': png(2, 2)}), 'ERRORS', {'DRAWING'})
case('err_second_section', docx(P('one', ppr=SECT), P('two')), 'ERRORS', {'SECTION'})
case('err_columns', docx(P('x'), sect=SECT.replace('</w:sectPr>', '<w:cols w:num="2"/></w:sectPr>')), 'ERRORS', {'SECTION'})
case('err_revision', docx('<w:p><w:ins w:id="1" w:author="a"><w:r><w:t>new</w:t></w:r></w:ins></w:p>'), 'ERRORS', {'REVISION'})
case('err_comment', docx(P('<w:commentRangeStart w:id="0"/>', 'x', '<w:commentRangeEnd w:id="0"/>',
                           '<w:r><w:commentReference w:id="0"/></w:r>')), 'ERRORS', {'COMMENT'})
case('err_note', docx(P('x', '<w:r><w:footnoteReference w:id="1"/></w:r>')), 'ERRORS', {'NOTE'})
case('err_emf', docx(P(PIC()), rels=[('rIdImg', 'image', 'media/image1.emf')],
                     parts={'word/media/image1.emf': b'\x01\x00\x00\x00' + b'\x00' * 100}), 'ERRORS', {'IMAGE_FORMAT'})
case('err_svg', docx(P(PIC(blip_extra='<a:extLst><a:ext uri="{96DAC541}"><asvg:svgBlip xmlns:asvg="http://schemas.microsoft.com/office/drawing/2016/SVG/main" r:embed="rIdImg"/></a:ext></a:extLst>')),
                     rels=IMG_REL, parts={'word/media/image1.png': png(2, 2)}), 'ERRORS', {'IMAGE_FORMAT'})
case('err_image_px', docx(P(PIC()), rels=IMG_REL, parts={'word/media/image1.png': png_header_only(4001, 10)}),
     'ERRORS', {'IMAGE_BUDGET'})
case('err_image_external', docx(P(PIC(rid='rIdX')), rels=[('rIdX', 'image', 'https://example.invalid/i.png', True)]),
     'ERRORS', {'IMAGE_EXTERNAL'})
case('err_rtl', docx(P(R('x', '<w:rtl/>')), P('y', ppr='<w:bidi/>')), 'ERRORS', {'RTL'})
case('err_conditional_style', docx(TBL(TR(TC(P('a')), TC(P('b'))), tblpr='<w:tblStyle w:val="Banded"/>'),
                                   styles=STYLES + COND_STYLE), 'ERRORS', {'TABLE_CONDITIONAL'})
case('err_unknown_element', docx('<w:sdt><w:sdtContent>' + P('x') + '</w:sdtContent></w:sdt>'), 'ERRORS', {'ELEMENT'})
case('err_grid_before', docx(TBL(TR(TC(P('a')), trpr='<w:gridBefore w:val="1"/>'))), 'ERRORS', {'GRID'})
case('err_tag_syntax', docx(P('price {total | money}'), P('open { brace'), P('{#}')), 'ERRORS', {'TAG_SYNTAX'})
case('err_tag_path', docx(P('{#lines}{colour}{/lines}')), 'ERRORS', {'TAG_PATH'})
case('err_tag_type', docx(P('{lines}'), P('{%name}'), P('{?name}')), 'ERRORS', {'TAG_TYPE'})
case('err_tag_region_rows', docx(TBL(TR(TC(P('{#lines}{code}')), TC(P('x'))), TR(TC(P('y')), TC(P('{/lines}'))))),
     'ERRORS', {'TAG_REGION'})
case('err_tag_region_paras', docx(P('text {#flag}a'), P('b{/flag}')), 'ERRORS', {'TAG_REGION'})
case('err_tag_region_cell_exit', docx(TBL(TR(TC(P('x {#flag}a')), TC(P('b')))), P('{/flag}')), 'ERRORS', {'TAG_REGION'})
case('err_tag_header_row', docx(TBL(TR(TC(P('{#lines}{code}')), TC(P('{/lines}')), trpr='<w:tblHeader/>'))),
     'ERRORS', {'TAG_REGION'})
case('err_tag_empty_inline', docx(P('x {#flag}{/flag} y')), 'ERRORS', {'TAG_REGION'})
case('err_tag_balance', docx(P('{/lines}'), P('{#lines}{#flag}x{/lines}{/flag}'), P('{#flag}open')), 'ERRORS', {'TAG_BALANCE'})
case('err_tag_depth', docx(P('{#lines}{#subs}{#deep}{#d4}{v}{/d4}{/deep}{/subs}{/lines}')), 'ERRORS', {'TAG_DEPTH'})
case('err_field_in_field', docx(P('<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText>PAGE</w:instrText></w:r>'
                                  '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText>NUMPAGES</w:instrText></w:r>'
                                  '<w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>')),
     'ERRORS', {'FIELD'})

# ---- the package refused (96a §8) ------------------------------------------------------------------------------
case('pkg_not_zip', b'PK\x03\x04 this is not a zip at all' * 3, 'RAISE', ('PDF_DOCX', 'end of central directory'))
case('pkg_bomb_ratio', with_entries([{'name': 'word/media/zeros.bin', 'data': b'\0' * (3 * 1024 * 1024)}]),
     'RAISE', ('PDF_BUDGET', 'compression ratio'))
case('pkg_total_bytes', with_entries([{'name': f'word/media/n{i}.bin', 'data': bomb_text(8 * 1024 * 1024)} for i in range(4)]),
     'RAISE', ('PDF_BUDGET', 'decompressed bytes'))
def noise(n):
    import random
    rnd = random.Random(11)
    return base64.b64encode(bytes(rnd.getrandbits(8) for _ in range(n))).decode('ascii')


# a size that lies: small (the whole stream in one piece: UTL_COMPRESS refuses the size at its end) and large (the
# bytes counted during decompression pass the declared size before the end)
case('pkg_lying_size_small', raw_zip([dict(e, usize=len(e['data']) // 2) if e['name'] == 'word/document.xml' else e
                                      for e in entries_of(docx(P('padding ' * 200)))]),
     'RAISE', ('PDF_DOCX', 'cannot be decompressed'))
case('pkg_lying_size', raw_zip([dict(e, usize=50000) if e['name'] == 'word/document.xml' else e
                                for e in entries_of(docx(P(noise(150000))))]),
     'RAISE', ('PDF_DOCX', 'beyond its declared size'))
case('pkg_parts', with_entries([{'name': f'x/{i}.xml', 'data': b'<a/>'} for i in range(200)]), 'RAISE', ('PDF_BUDGET', 'entries'))
case('pkg_duplicate_case', with_entries([{'name': 'Word/Document.xml', 'data': b'<a/>'}]), 'RAISE', ('PDF_DOCX', 'duplicate entry'))
case('pkg_dotdot', with_entries([{'name': '../evil.xml', 'data': b'<a/>'}]), 'RAISE', ('PDF_DOCX', '".." segment'))
case('pkg_absolute', with_entries([{'name': '/etc/evil.xml', 'data': b'<a/>'}]), 'RAISE', ('PDF_DOCX', 'not allowed'))
case('pkg_backslash', with_entries([{'name': 'word\\evil.xml', 'data': b'<a/>'}]), 'RAISE', ('PDF_DOCX', 'not allowed'))
case('pkg_encrypted', raw_zip([dict(e, flags=1) if e['name'] == 'word/styles.xml' else e for e in entries_of(BASE)]),
     'RAISE', ('PDF_DOCX', 'encrypted'))
case('pkg_target_outside', docx(P('x'), sect=SECT.replace('<w:pgSz', '<w:headerReference w:type="default" r:id="rIdH"/><w:pgSz'),
                                rels=[('rIdH', 'header', '../../header1.xml')]), 'RAISE', ('PDF_DOCX', 'outside the package'))
case('pkg_external_header', docx(P('x'), sect=SECT.replace('<w:pgSz', '<w:headerReference w:type="default" r:id="rIdH"/><w:pgSz'),
                                 rels=[('rIdH', 'header', 'https://example.invalid/h.xml', True)]),
     'RAISE', ('PDF_DOCX', 'missing or external'))
case('pkg_dtd', docx('', doc_xml='<?xml version="1.0"?><!DOCTYPE d [<!ENTITY e "x">]><w:document ' + NS + '><w:body>'
                     + '<w:p><w:r><w:t>&e;</w:t></w:r></w:p>' + SECT + '</w:body></w:document>'), 'RAISE', ('PDF_DOCX', 'DTD'))
case('pkg_macro', docx(P('x'), parts={'word/vbaProject.bin': b'\0' * 10}), 'RAISE', ('PDF_DOCX', 'macro'))
case('pkg_docm', docx(P('x'), ct=[('/word/document.xml', 'application/vnd.ms-word.document.macroEnabled.main+xml')]),
     'RAISE', ('PDF_DOCX', 'macro'))
case('pkg_embedding', docx(P('x'), parts={'word/embeddings/oleObject1.bin': b'\0' * 10}), 'RAISE', ('PDF_DOCX', 'embedded object'))
case('pkg_activex', docx(P('x'), parts={'word/activeX/activeX1.xml': b'<a/>'}), 'RAISE', ('PDF_DOCX', 'active content'))
case('pkg_altchunk', docx('<w:altChunk r:id="rIdA"/>', rels=[('rIdA', 'aFChunk', 'afchunk.htm')],
                          parts={'word/afchunk.htm': b'<html/>'}), 'RAISE', ('PDF_DOCX', 'aFChunk'))
case('pkg_depth', docx(P(R('x'), '<w:customXml w:element="a">' * 70 + '</w:customXml>' * 70)), 'RAISE', ('PDF_BUDGET', 'deeper'))
case('pkg_not_word', docx(P('x'), ct=[('/word/document.xml', 'application/xml')]), 'RAISE', ('PDF_DOCX', 'not a Word document'))
case('pkg_strict', docx('', doc_xml='<?xml version="1.0"?><w:document xmlns:w="http://purl.oclc.org/ooxml/wordprocessingml/main">'
                        '<w:body><w:p/></w:body></w:document>'), 'RAISE', ('PDF_DOCX', 'Strict'))


def overlap_zip():
    """a stored entry whose data holds the local header of another entry, both in the central directory"""
    inner_name = b'word/b.xml'
    inner_data = b'<b/>'
    inner = struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, 0, 0, 0, 0, zlib.crc32(inner_data), len(inner_data),
                        len(inner_data), len(inner_name), 0) + inner_name + inner_data
    ents = entries_of(BASE)
    blob = raw_zip(ents + [{'name': 'word/a.bin', 'data': inner, 'method': 0}])
    # where word/a.bin's data starts: after its local header
    pos = blob.find(b'word/a.bin') + len(b'word/a.bin')
    return raw_zip(ents + [{'name': 'word/a.bin', 'data': inner, 'method': 0}],
                   central_extra=[{'name': 'word/b.xml', 'csize': len(inner_data), 'usize': len(inner_data),
                                   'offset': pos, 'crc': zlib.crc32(inner_data)}])


CASES['pkg_overlap'] = (overlap_zip(), 'RAISE', ('PDF_DOCX', 'overlap'))
# no state across reads: in ONE session, a template, a refused package, a template in error, the first template
# again -- the last read identical to the first (run as one batch, see run())
SESSION = [('session_first', 'pos_nested_scopes'), ('session_refused', 'pkg_lying_size'),
           ('session_error', 'err_tag_balance'), ('session_again', 'pos_nested_scopes')]


# ---------------------------------------------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------------------------------------------
def b64_block(blob):
    b = base64.b64encode(blob).decode('ascii')
    return '\n'.join(f"    DBMS_LOB.APPEND(c, '{b[i:i + 30000]}');" for i in range(0, len(b), 30000))


# the temporary LOBs the session holds, read by a statement of its own before and after the batch: inside one call
# Oracle counts call-duration temporaries too, released when the call ends (measured in B4); what survives the call
# is what a read would leave in a pooled session (UTL_COMPRESS's piecewise API did: one per part)
LOBS = ("SELECT 'LOBS:{}:' || NVL(SUM(cache_lobs + nocache_lobs + abstract_lobs), 0) FROM v$temporary_lobs "
        "WHERE sid = SYS_CONTEXT('USERENV', 'SID');")


def script(names):
    calls = []
    for n in names:
        blob = CASES[dict(SESSION).get(n, n)][0]
        calls.append(f"""  DECLARE c CLOB; BEGIN
    DBMS_LOB.CREATETEMPORARY(c, TRUE);
{b64_block(blob)}
    run_case('{n}', c);
    DBMS_LOB.FREETEMPORARY(c);
  END;""")
    sch = json.dumps(SCHEMA, ensure_ascii=True)
    return f"""SET SERVEROUTPUT ON SIZE UNLIMITED
SET PAGESIZE 0 FEEDBACK OFF
{LOBS.format('before')}
DECLARE
  l_sch rad_pdf_merge.t_schema := rad_pdf_merge.schema_from_json(q'~{sch}~');
  PROCEDURE out_lob(p_tag VARCHAR2, p_clob CLOB) IS
    l_pos PLS_INTEGER := 1;
  BEGIN
    WHILE l_pos <= DBMS_LOB.GETLENGTH(p_clob) LOOP
      DBMS_OUTPUT.PUT_LINE(p_tag || DBMS_LOB.SUBSTR(p_clob, 8000, l_pos));
      l_pos := l_pos + 8000;
    END LOOP;
  END out_lob;
  PROCEDURE run_case(p_name VARCHAR2, p_b64 CLOB) IS
    b  BLOB;
    r  rad_pdf_docx.t_result;
    j  CLOB;
  BEGIN
    b := rad_pdf_codec.base64_decode(p_b64);
    BEGIN
      r := rad_pdf_docx.read(b, l_sch);
      j := rad_pdf_docx.report_json(r);
      out_lob('REP:' || p_name || ':', j);
      DBMS_LOB.FREETEMPORARY(j);
      IF r.errors = 0 THEN
        j := rad_pdf_ri.to_json(r.ri);
        out_lob('RI:' || p_name || ':', j);
        DBMS_LOB.FREETEMPORARY(j);
        rad_pdf_ri.free(r.ri);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('RAISED:' || p_name || ':' || REGEXP_SUBSTR(SQLERRM, '[^' || CHR(10) || ']+'));
    END;
    DBMS_LOB.FREETEMPORARY(b);
  END run_case;
BEGIN
{chr(10).join(calls)}
END;
/
{LOBS.format('after')}"""


def run(names):
    got = {}
    batches = [names[i:i + 8] for i in range(0, len(names), 8)] + [[a for a, _ in SESSION]]
    for batch in batches:
        rc, out = bench.sqlcl(script(batch), timeout=1800)
        if rc:
            sys.exit(f'the batch {batch} failed (rc={rc}):\n{out[-3000:]}')
        for line in out.splitlines():
            if line.startswith('LOBS:'):
                got.setdefault('lobs', {}).setdefault(line.split(':')[1], []).append(int(line.split(':')[2]))
            for tag in ('REP', 'RI', 'RAISED'):
                if line.startswith(tag + ':'):
                    name, _, rest = line[len(tag) + 1:].partition(':')
                    got.setdefault(name, {}).setdefault(tag, []).append(rest)
    return got


def main():
    names = sys.argv[1:] or list(CASES)
    unknown = [n for n in names if n not in CASES]
    if unknown:
        sys.exit(f'unknown cases: {unknown}')
    got = run(names)
    ok = True
    for n in names:
        blob, kind, expect = CASES[n]
        g = got.get(n, {})
        rep = json.loads(''.join(g['REP'])) if 'REP' in g else None
        ri = ''.join(g.get('RI', []))
        raised = g.get('RAISED', [None])[0]
        errs = {i['code'] for i in rep['issues'] if i['severity'] == 'ERROR'} if rep else set()
        warns = {i['code'] for i in rep['issues'] if i['severity'] == 'WARNING'} if rep else set()
        if kind == 'ERRORS':
            good = rep is not None and errs == expect and not ri
            detail = f'errors {sorted(errs)}' if rep else f'raised {raised}'
        elif kind == 'WARNS':
            good = rep is not None and not errs and expect <= warns and bool(ri)
            detail = f'warnings {sorted(warns)}, errors {sorted(errs)}' if rep else f'raised {raised}'
        elif kind == 'RI':
            missing = [t for t in expect if t not in ri]
            good = rep is not None and not errs and bool(ri) and not missing
            detail = (f'missing {missing}' if missing else 'all texts found') if rep else f'raised {raised}'
            if rep and errs:
                detail = f'errors {sorted(errs)}: ' + '; '.join(i['message'] for i in rep['issues'] if i['severity'] == 'ERROR')
        elif kind == 'RAISE':
            code, text = expect
            good = raised is not None and f'[{code}]' in raised and text in raised
            detail = f'raised {raised}' if raised else f'not refused: errors {sorted(errs)}'
        ok = ok and good
        print(f'{"ok  " if good else "FAIL"} {n:32s} {kind:7s} {detail[:220]}')
    first, again = got.get('session_first', {}), got.get('session_again', {})
    good = (bool(first.get('RI')) and first.get('RI') == again.get('RI') and first.get('REP') == again.get('REP')
            and 'RAISED' in got.get('session_refused', {}) and 'REP' in got.get('session_error', {}))
    ok = ok and good
    print(f'{"ok  " if good else "FAIL"} {"one session":32s} {"SAME":7s} a read, a refused package, a template in error, '
          f'the first read again: {"identical" if good else "DIFFERENT"}')
    lobs = got.get('lobs', {})
    good = len(lobs.get('before', [])) == len(lobs.get('after', [])) > 0 and lobs['before'] == lobs['after']
    ok = ok and good
    print(f'{"ok  " if good else "FAIL"} {"temporary LOBs":32s} {"0 LEFT":7s} per batch, before {lobs.get("before")} '
          f'after {lobs.get("after")}')
    print(f'docx cases: {"OK" if ok else "FAILED"} ({len(names)} cases)')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
