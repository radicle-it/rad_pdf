"""The first gate of doc 96a §10: the sal_ quote template (conforming to 96a §6-§7), its JSON (96a §5.3), negative JSON
cases, and the SAME document merged by this script (plain substitution, only for the reference) so that Word can export
the reference PDF. Run: python3 tests/word/make_quote_sample.py  (writes tests/word/samples/)."""
import copy, json, os
from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_TAB_ALIGNMENT, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

OUT = os.path.join(os.path.dirname(__file__), 'samples')
FONT = 'Arial'                    # as a real author writes it; our engine substitutes Liberation Sans (metric twin, D3)

def field(par, code):
    """a simple Word field (PAGE / NUMPAGES) as fldChar begin/instr/separate/end"""
    def fc(t):
        r = par.add_run(); e = OxmlElement('w:fldChar'); e.set(qn('w:fldCharType'), t); r._r.append(e)
    fc('begin'); r = par.add_run(); i = OxmlElement('w:instrText'); i.set(qn('xml:space'), 'preserve'); i.text = f' {code} '; r._r.append(i)
    fc('separate'); par.add_run('1'); fc('end')

def shade(cell, hex_):
    tcPr = cell._tc.get_or_add_tcPr(); s = OxmlElement('w:shd'); s.set(qn('w:val'), 'clear'); s.set(qn('w:color'), 'auto'); s.set(qn('w:fill'), hex_); tcPr.append(s)

def borders(table):
    tblPr = table._tbl.tblPr; b = OxmlElement('w:tblBorders')
    for side in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'):
        e = OxmlElement(f'w:{side}'); e.set(qn('w:val'), 'single'); e.set(qn('w:sz'), '4'); e.set(qn('w:color'), '999999'); b.append(e)
    tblPr.append(b)

def repeat_header(row):
    trPr = row._tr.get_or_add_trPr(); h = OxmlElement('w:tblHeader'); h.set(qn('w:val'), 'true'); trPr.append(h)
    c = OxmlElement('w:cantSplit'); c.set(qn('w:val'), 'true'); trPr.append(c)

def no_theme(style):
    """the heading styles name the theme fonts (asciiTheme...): the explicit name only, so Word and we read the same"""
    rf = style.element.rPr.rFonts
    for a in ('w:asciiTheme', 'w:hAnsiTheme', 'w:eastAsiaTheme', 'w:cstheme'):
        if rf.get(qn(a)) is not None: del rf.attrib[qn(a)]
    rf.set(qn('w:ascii'), FONT); rf.set(qn('w:hAnsi'), FONT)

def build(data=None):
    """the template when data is None; the merged reference document otherwise"""
    d = Document()
    st = d.styles['Normal']; st.font.name = FONT; st.font.size = Pt(10)
    st.element.rPr.rFonts.set(qn('w:eastAsia'), FONT)
    h1 = d.styles['Heading 1']; h1.font.name = FONT; no_theme(h1); h1.font.size = Pt(16); h1.font.color.rgb = RGBColor(0x1F, 0x3A, 0x5F)
    sec = d.sections[0]
    sec.page_width, sec.page_height = Cm(21), Cm(29.7)
    sec.left_margin = sec.right_margin = Cm(2); sec.top_margin = Cm(2.5); sec.bottom_margin = Cm(2)
    sec.different_first_page_header_footer = True
    v = (lambda p, default='': default if data is None else str(get(data, p) or '')) if data is not None else None
    def T(path):                         # a tag in the template, the value in the merged document
        return '{' + path + '}' if data is None else (str(get(data, path)) if get(data, path) is not None else '')
    # first-page header: company and logo; other pages: the quote number
    fh = sec.first_page_header.paragraphs[0]; fh.text = T('company.name'); fh.runs[0].bold = True
    fh2 = sec.first_page_header.add_paragraph(T('company.address'))
    oh = sec.header.paragraphs[0]; oh.text = 'Offerta ' + T('quote.no')
    for ft in (sec.footer, sec.first_page_footer):
        p = ft.paragraphs[0]; p.alignment = WD_ALIGN_PARAGRAPH.RIGHT; p.add_run('Pagina '); field(p, 'PAGE'); p.add_run(' di '); field(p, 'NUMPAGES')
    d.add_paragraph('Offerta ' + T('quote.no') + ' · ' + T('quote.title'), style='Heading 1')
    p = d.add_paragraph(); p.paragraph_format.tab_stops.add_tab_stop(Cm(17), WD_TAB_ALIGNMENT.RIGHT)
    p.add_run('Data: ' + T('quote.date') + '\tValida fino al: ' + T('quote.valid_until'))
    c = d.add_paragraph(); c.paragraph_format.left_indent = Cm(9); c.paragraph_format.space_before = Pt(12)
    c.add_run('Spett.le ').italic = True; c.add_run(T('customer.name')).bold = True
    d.add_paragraph(T('customer.address')).paragraph_format.left_indent = Cm(9)
    i = d.add_paragraph(T('intro_text')); i.paragraph_format.space_before = Pt(12); i.paragraph_format.space_after = Pt(6)
    i.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
    # the lines: header row repeated, one row repeated by the loop (open in the first cell, close in the last)
    cols = [('Pos.', 1.2), ('Codice', 2.3), ('Descrizione', 6.5), ('Q.tà', 1.5), ('UM', 1.2), ('Prezzo', 2.2), ('Importo', 2.1)]
    t = d.add_table(rows=1, cols=len(cols)); t.alignment = WD_TABLE_ALIGNMENT.CENTER; borders(t); t.autofit = False
    for k, (name, w) in enumerate(cols):
        cell = t.rows[0].cells[k]; cell.width = Cm(w); cell.text = name; cell.paragraphs[0].runs[0].bold = True; shade(cell, 'DCE6F0')
    repeat_header(t.rows[0])
    keys = ['line_no', 'code', 'description', 'qty', 'uom', 'unit_price', 'amount']
    lines = [None] if data is None else data['lines']
    for ln in lines:
        r = t.add_row()
        for k, key in enumerate(keys):
            txt = ('{' + key + '}') if data is None else str(ln.get(key) or '')
            if data is None and k == 0: txt = '{#lines}' + txt
            if data is None and k == len(keys) - 1: txt = txt + '{/lines}'
            r.cells[k].width = Cm(cols[k][1]); r.cells[k].text = txt
            if k >= 3 and k != 4: r.cells[k].paragraphs[0].alignment = WD_ALIGN_PARAGRAPH.RIGHT
    # totals: a gridSpan row is not needed here -- a paragraph with a decimal tab stop, kept with the next
    for label, path in (('Imponibile', 'totals.net'), ('IVA', 'totals.vat'), ('Totale', 'totals.gross')):
        q = d.add_paragraph(); q.paragraph_format.tab_stops.add_tab_stop(Cm(17), WD_TAB_ALIGNMENT.DECIMAL)
        q.paragraph_format.keep_with_next = True
        r = q.add_run(label + '\t' + T(path)); r.bold = (label == 'Totale')
    disc = d.add_paragraph()
    if data is None: disc.add_run('{#has_discount}Gli importi includono gli sconti indicati.{/has_discount}')
    elif data['has_discount']: disc.add_run('Gli importi includono gli sconti indicati.')
    d.add_paragraph('Condizioni di pagamento: ' + T('payment_term'))
    cl = d.add_paragraph(T('closing_text')); cl.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
    return d

def get(o, path):
    for part in path.split('.'):
        if o is None: return None
        o = o.get(part) if isinstance(o, dict) else None
    return o

DATA = {
    'quote': {'no': 'OFF-2026/0142', 'title': 'Carenaggio e pitturazione scafo', 'date': '16/11/2026', 'valid_until': '16/12/2026', 'reference': 'RDA 4711'},
    'company': {'name': 'Cantiere Demo S.r.l.', 'address': 'Via del Porto 1, 16100 Genova', 'vat': 'IT01234567890'},
    'customer': {'name': 'Armatore Demo S.p.A.', 'address': 'Calata Gadda 3, 16126 Genova', 'vat': 'IT09876543210'},
    'intro_text': "Facendo seguito alla Vostra richiesta, Vi sottoponiamo la nostra migliore offerta per i lavori in oggetto, "
                  "eseguiti presso il nostro bacino secondo le specifiche tecniche concordate durante il sopralluogo.",
    'lines': [{'line_no': str(n), 'code': f'LAV-{n:03d}', 'description': d_, 'qty': q, 'uom': u, 'unit_price': p, 'amount': a}
              for n, (d_, q, u, p, a) in enumerate([
                  ('Ingresso e uscita dal bacino, ormeggio e assistenza', '1', 'nr', '4.500,00', '4.500,00'),
                  ('Sabbiatura carena grado SA 2,5', '850', 'm²', '12,50', '10.625,00'),
                  ('Pitturazione antivegetativa, due mani', '850', 'm²', '9,80', '8.330,00'),
                  ('Sostituzione anodi sacrificali in zinco', '24', 'nr', '85,00', '2.040,00'),
                  ('Controllo e revisione eliche e linee d\'asse', '1', 'nr', '3.200,00', '3.200,00'),
              ] * 8, start=1)],
    'has_discount': True,
    'totals': {'net': '229.560,00', 'vat': '50.503,20', 'gross': '280.063,20'},
    'payment_term': '30% all\'ordine, saldo a fine lavori',
    'closing_text': "I prezzi si intendono IVA esclusa. L'offerta è valida fino alla data indicata; eventuali lavori "
                    "aggiuntivi saranno quotati a parte previa approvazione del cliente.",
}

if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    build().save(os.path.join(OUT, 'sal_quote_v1.docx'))
    build(DATA).save(os.path.join(OUT, 'sal_quote_v1_merged.docx'))
    json.dump(DATA, open(os.path.join(OUT, 'sal_quote_v1.json'), 'w'), ensure_ascii=False, indent=1)
    neg = {'lines_not_array': dict(DATA, lines={'x': 1}), 'missing_required': {k: v for k, v in DATA.items() if k != 'totals'},
           'wrong_type': dict(DATA, has_discount='yes')}
    for k, v in neg.items():
        json.dump(v, open(os.path.join(OUT, f'sal_quote_v1_neg_{k}.json'), 'w'), ensure_ascii=False, indent=1)
    print('written to', OUT)
