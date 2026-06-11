# RAD_PDF

**Version 1.5.2** - Native PL/SQL library for generating PDF documents from Oracle Database 19c+.  
No Java, no external tools, no OS dependencies.

**Author:** Roberto Capancioni - [Radicle S.r.l.](https://radicle.it)  
**Based on:** [AS_PDF](https://github.com/antonscheffer/as_pdf) by Anton Scheffer

---

## What it does

RAD_PDF generates PDF files entirely inside Oracle Database using PL/SQL.  
You write SQL and PL/SQL; RAD_PDF produces a valid PDF BLOB — no Java, no file system, no middle tier required.

### Two ways to generate a PDF

**Canvas API** — call individual procedures for each element:

```sql
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.heading(l_doc, 'Quarterly Report', 1);
  rad_pdf.write  (l_doc, 'Revenue increased 18% year-over-year.');
  rad_pdf.query2table(l_doc, 'SELECT dept_name, headcount FROM departments', l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  -- store in a table, stream to browser, write to a directory...
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
```

**Template engine** — describe the document as an XML-like CLOB string:

```sql
DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_binds rad_pdf_types.t_bind_array;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  l_binds(1).key := 'DEPT'; l_binds(1).value := 'Accounting';
  l_binds(2).key := 'YEAR'; l_binds(2).value := '2025';

  rad_pdf_template.render(l_doc,
    '<h1>#DEPT# — Quarterly Report #YEAR#</h1>'  ||
    '<p>Revenue increased <b>18%</b> year-over-year.</p>',
    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
```

Use the **Canvas API** when you need pixel-level control over position, or when the document
contains complex interleaved drawing (images at exact coordinates, polygons, rotated text).  
Use the **Template engine** when document structure is consistent but content varies — templates
can be stored in a database table and updated without redeploying code.

---

## Installation

**Requirements:** Oracle Database 19c or later. A schema with `CREATE PROCEDURE` privilege.

```sql
-- 1. Connect to Oracle as the target schema owner (SQL*Plus or SQL Developer)

-- 2. Set the working directory to src/ and run the installer
@install.sql

-- 3. Verify (optional but recommended)
@../tests/phase9_integration.sql    -- Canvas API + core packages (all lines: PASS)
@../tests/phase10_template.sql      -- Template engine (all lines: PASS)
```

> **SQL Developer users:** use *File → Open* to open `src/install.sql`, then run it with F5
> while connected as the schema owner.

---

## Features

- **Layout engine** — automatic text wrap, page breaks, headings h1–h6, paragraphs, spacers, horizontal rules
- **Tables** — `query2table` / `refcursor2table`; column widths, alignment, color schemes, break fields, label grids
- **Template engine** — render PDFs from XML-like CLOB templates with `#BIND#` tokens, conditional blocks,
  inline markup, data tables, and page breaks; store templates in database tables
- **Standard PDF fonts** — Helvetica, Times, Courier (no embedding needed)
- **TrueType fonts** — load from BLOB, Oracle Directory, or HTTPS URL; embed and compress
- **Images** — JPEG, PNG, GIF; SHA-256 session cache; load from BLOB, directory, or HTTPS URL
- **Page templates** — header/footer PL/SQL blocks executed on every page; `#PAGE_NR#` / `#PAGE_COUNT#` tokens
- **Styles** — named, session-scoped style registry with built-in heading and table styles
- **QR codes & barcodes** — vector QR codes (auto encoding mode, EC levels L/M/Q/H) plus Code 128, EAN-13 (check-digit validation) and Code 39
- **Bookmarks** — navigable outline sidebar from headings (`p_bookmark => TRUE`) or manual anchors; automatic hierarchy
- **Canvas API** — absolute positioning, lines, rectangles, polygons, rotated text for advanced layouts
- **Document metadata** — title, author, subject, keywords in PDF Info dictionary
- **AUTHID CURRENT_USER** — runs with the caller's privileges; safe in shared schemas

---

## Documentation

| Document | Contents |
|---|---|
| [docs/README.md](docs/README.md) | Full user guide and API reference |
| [docs/apex/README.md](docs/apex/README.md) | Oracle APEX integration: streaming, page items, APEX-specific patterns |
| [docs/TEMPLATE_GUIDE.md](docs/TEMPLATE_GUIDE.md) | Template engine reference: tag catalogue, bind syntax, options, patterns |

### Canvas API examples

| File | Description |
|---|---|
| [docs/sample01.sql](docs/sample01.sql) | Minimal: `new_document` → `write` → `finalize` |
| [docs/sample02.sql](docs/sample02.sql) | Styled report: headings, spacers, horizontal rule, custom style |
| [docs/sample03.sql](docs/sample03.sql) | Canvas-only: text, lines, rectangles, polygon at absolute positions |
| [docs/sample04.sql](docs/sample04.sql) | Table report: `query2table` with column defs and color scheme |
| [docs/sample05.sql](docs/sample05.sql) | Full report: page template (header/footer), metadata, save to directory |
| [docs/sample06.sql](docs/sample06.sql) | Grouped report: `refcursor2table` with `break_field` |
| [docs/sample07.sql](docs/sample07.sql) | Label sheet: `query2labels` with `t_label_def` |
| [docs/sample08.sql](docs/sample08.sql) | Wide table in landscape orientation |
| [docs/sample09.sql](docs/sample09.sql) | Image embedding: load from directory / BLOB / HTTPS URL |
| [docs/sample10.sql](docs/sample10.sql) | Table with `wrap = TRUE`: multi-line cells, dynamic row height |
| [docs/sample13.sql](docs/sample13.sql) | Text watermark: "DRAFT" diagonal on an EMP table report |
| [docs/sample14.sql](docs/sample14.sql) | Image watermark: logo centred on every page, 25% opacity |
| [docs/sample15.sql](docs/sample15.sql) | Line dash patterns: dashed borders, asymmetric patterns, reset to solid |
| [docs/sample16.sql](docs/sample16.sql) | Justified text: `write_wrapped` with `'J'` alignment, multi-paragraph layout |
| [docs/sample17.sql](docs/sample17.sql) | QR codes: payment link, UTF-8 vCard, coloured QR with EC level H |
| [docs/sample18.sql](docs/sample18.sql) | 1D barcodes: Code 128, EAN-13, Code 39 product labels |
| [docs/sample19.sql](docs/sample19.sql) | Bookmarks: navigable outline from headings + manual anchors |

### Template engine examples

| File | Description |
|---|---|
| [docs/template_sample01.sql](docs/template_sample01.sql) | Basic structure: h1–h6, p, spacer, hr, pagebreak |
| [docs/template_sample02.sql](docs/template_sample02.sql) | Bind substitution, inline markup (`<b>`, `<i>`, `<br/>`), conditional blocks |
| [docs/template_sample03.sql](docs/template_sample03.sql) | Lists (`<ul>`, `<ol>`, `<li>`), inline colour and font size |
| [docs/template_sample04.sql](docs/template_sample04.sql) | Data table: `register_columns` + `<table>` tag |
| [docs/template_sample05.sql](docs/template_sample05.sql) | Multi-section document: multiple `render()` calls in a loop |
| [docs/sample11.sql](docs/sample11.sql) | Template engine: department salary report from a CLOB template |
| [docs/sample12.sql](docs/sample12.sql) | DB-driven templates: load and render templates stored in a table |

### Oracle APEX examples

See **[docs/apex/README.md](docs/apex/README.md)** for APEX-specific streaming and setup patterns.

| File | Description |
|---|---|
| [docs/apex/apex_sample00.sql](docs/apex/apex_sample00.sql) | Letterhead: logo, company info, header/footer on every page |
| [docs/apex/apex_sample01.sql](docs/apex/apex_sample01.sql) | Minimal page process: generate PDF and stream to browser |
| [docs/apex/apex_sample02.sql](docs/apex/apex_sample02.sql) | Filtered report using APEX page items as bind variables |
| [docs/apex/apex_sample03.sql](docs/apex/apex_sample03.sql) | Multi-section report: department summary + employee detail |
| [docs/apex/apex_sample04.sql](docs/apex/apex_sample04.sql) | Full report with dynamic header, footer, and `V()` session info |
| [docs/apex/apex_sample05.sql](docs/apex/apex_sample05.sql) | Cover page on page 1, header/footer from page 2 |
| [docs/apex/apex_sample06.sql](docs/apex/apex_sample06.sql) | Table with `wrap = TRUE`: multi-line cells, dynamic row height |
| [docs/apex/apex_sample07.sql](docs/apex/apex_sample07.sql) | Template engine quick-start: bind substitution, block tags, data table |
| [docs/apex/apex_sample08.sql](docs/apex/apex_sample08.sql) | Auto-width columns: derive column widths from content |
| [docs/apex/apex_sample09.sql](docs/apex/apex_sample09.sql) | Conditional text watermark driven by page item `P1_IS_DRAFT` |
| [docs/apex/apex_sample10.sql](docs/apex/apex_sample10.sql) | Image watermark loaded from application static files |
| [docs/apex/apex_sample11.sql](docs/apex/apex_sample11.sql) | Line dash patterns: dashed rules and decorative borders |
| [docs/apex/apex_sample12.sql](docs/apex/apex_sample12.sql) | Justified paragraph text with `write_wrapped 'J'` |
| [docs/apex/apex_sample13.sql](docs/apex/apex_sample13.sql) | Payment QR code driven by page items (demo app page 3) |
| [docs/apex/apex_sample14.sql](docs/apex/apex_sample14.sql) | 1D barcode label sheet from a query (demo app page 4) |

Template engine examples for APEX (progressive curriculum — see [TEMPLATE_GUIDE.md](docs/TEMPLATE_GUIDE.md)):

| File | Feature |
|---|---|
| [apex_template_01](docs/apex/apex_template_01.sql) | Document structure: h1–h6, p, spacer, hr |
| [apex_template_02](docs/apex/apex_template_02.sql) | Bind substitution with `#KEY#` tokens |
| [apex_template_03](docs/apex/apex_template_03.sql) | Inline markup: `<b>`, `<i>`, raw binds |
| [apex_template_04](docs/apex/apex_template_04.sql) | Inline colour and font size |
| [apex_template_05](docs/apex/apex_template_05.sql) | Line breaks with `<br/>` |
| [apex_template_06](docs/apex/apex_template_06.sql) | Conditional blocks `<if bind="…">` |
| [apex_template_07](docs/apex/apex_template_07.sql) | Lists: `<ul>`, `<ol>`, `<li>` |
| [apex_template_08](docs/apex/apex_template_08.sql) | Data table: `<table columns="…" query="…">` |
| [apex_template_09](docs/apex/apex_template_09.sql) | Page break: two-page report |
| [apex_template_10](docs/apex/apex_template_10.sql) | Inline markup inside h1–h6 headings |
| [apex_template_11](docs/apex/apex_template_11.sql) | Multiple `render()` calls — one per department |
| [apex_template_12](docs/apex/apex_template_12.sql) | Custom font via `t_template_options` |
| [apex_template_13](docs/apex/apex_template_13.sql) | DB-driven templates from a table |
| [apex_template_14](docs/apex/apex_template_14.sql) | Complete department report — all features |

---

## Repository layout

```
src/     PL/SQL packages + install scripts (start here)
tests/   Acceptance test suite (one file per phase)
docs/    User guide (README.md) and runnable examples
  apex/  APEX integration guide and APEX-specific examples
spec/    Architecture and refactoring specification documents
```

---

## Credits

RAD_PDF is a complete rewrite of [AS_PDF](https://github.com/antonscheffer/as_pdf),
originally created by **Anton Scheffer** (Oracle APEX team).
The PDF generation algorithms and font-width tables from AS_PDF are the foundation of this work.

The v1.5 graphics-state API (`set_draw_color`, `set_fill_color`, `set_line_width`, `set_line_dash`)
was modeled on [PLFPDF](https://github.com/mczarski/plfpdf), a PL/SQL port of
[FPDF](http://www.fpdf.org/) by **Olivier Plathey**.

The v1.6 QR code encoding logic (`rad_pdf_barcode`) is ported from
[as_barcode](https://github.com/antonscheffer/as_barcode) by **Anton Scheffer**
(MIT license — full notice in `src/rad_pdf_barcode.pkb`).

| Role | Name |
|---|---|
| Original author | Anton Scheffer |
| AS_PDF contributors | Valerio Rossetti, Andreas Weiden, Lee Lindley, Javier Meza |
| FPDF (PHP) | Olivier Plathey |
| PLFPDF (PL/SQL port) | mczarski and contributors |
| as_barcode (QR encoder, MIT) | Anton Scheffer |
| RAD_PDF rewrite | Roberto Capancioni - Radicle S.r.l. |

---

## License

RAD_PDF is a derivative work of AS_PDF, which was published by Anton Scheffer without a formal
open-source license. This rewrite is distributed under the same informal terms: free to use and
adapt, with attribution to both Anton Scheffer and Roberto Capancioni / Radicle S.r.l.
