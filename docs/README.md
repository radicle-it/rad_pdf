# RAD_PDF - User Guide

**Version:** 1.7.0  
**Author:** Roberto Capancioni - [Radicle S.r.l.](https://radicle.it)  
**Based on:** [AS_PDF](https://github.com/antonscheffer/as_pdf) by Anton Scheffer; v1.5 graphics-state API modeled on [PLFPDF](https://github.com/mczarski/plfpdf) / [FPDF](http://www.fpdf.org/) by Olivier Plathey  
← [Back to project README](../README.md)

---

## Table of Contents

1. [Installation](#installation)
2. [Quick Start](#quick-start)
3. [Choose Your Approach](#choose-your-approach)
4. [Core Concepts](#core-concepts)
5. [Document Lifecycle](#document-lifecycle)
6. [Layout Engine](#layout-engine)
7. [Canvas API](#canvas-api)
8. [Tables](#tables)
9. [Styles](#styles)
10. [Page Geometry](#page-geometry)
11. [Page Templates (Header / Footer)](#page-templates)
12. [Fonts](#fonts)
13. [Images](#images)
14. [Template Engine](#template-engine)
15. [Watermarks](#watermarks)
16. [Line Dash Patterns](#line-dash-patterns)
17. [QR Codes](#qr-codes)
18. [1D Barcodes](#1d-barcodes)
19. [Bookmarks (Document Outline)](#bookmarks-document-outline)
20. [Charts](#charts)
21. [PDF/A Conformance](#pdfa-conformance)
22. [API Reference](#api-reference)
23. [Known Limitations](#known-limitations)
24. [Examples Index](#examples-index)

---

## Installation

### Requirements

- Oracle Database **19c or later**
- A schema with `CREATE PROCEDURE`, `CREATE PACKAGE`, `CREATE TYPE` privileges
- SQL*Plus or SQL Developer to run the install script

### Steps

**1. Get the source**

```bash
git clone https://github.com/your-org/rad_pdf.git
cd rad_pdf
```

**2. Connect to Oracle as the schema owner**

```bash
# SQL*Plus
sqlplus your_schema/your_password@your_db
```

Or open a SQL Developer connection as the target schema.

**3. Run the installer**

In SQL*Plus, set the working directory to `src/` then run:

```sql
-- SQL*Plus
CD src
@install.sql
```

In SQL Developer, open `src/install.sql` with *File → Open*, then press **F5** (Run Script)
while connected as the schema owner.

The installer compiles all 12 packages in dependency order. Each phase prints its name and
`SHOW ERRORS` output. A successful install ends with:

```
=== Phase 8 install complete ===
```

**4. Verify the installation**

```sql
-- From the repo root directory:
@tests/phase9_integration.sql      -- canvas API + core packages
@tests/phase10_template.sql        -- template engine
```

All lines should read `PASS`. The final line will show the total count:

```
Phase 9: 31 passed, 0 failed.
```

If any test fails, run the individual phase test to isolate the issue:

```sql
@tests/phase1_foundation.sql
@tests/phase2_ctx_decoders.sql
-- ... through phase8_pdf.sql
```

**5. Volumetric benchmark (optional)**

`tests/benchmark_large_table.sql` is a separate stress suite that generates large PDFs (10 000-row tables) to validate PGA behaviour and cache cleanup. It is **not** part of the standard regression run because it takes 10–30 seconds and produces several-hundred-page PDFs. Run it manually after installation:

```sql
@tests/benchmark_large_table.sql
```

Expected output:

```
=== benchmark_large_table ===
--- 1. refcursor2table 10 000 rows ---
PASS  10k-rows: finalize succeeds (BLOB not null)
PASS  10k-rows: starts %PDF
PASS  10k-rows: BLOB > 50 000 bytes
      size = NNN.N KB  elapsed = N.NN s
--- 2. query2table 10 000 rows ---
PASS  q2t-10k: finalize succeeds
PASS  q2t-10k: starts %PDF
PASS  q2t-10k: BLOB > 50 000 bytes
      size = NNN.N KB  elapsed = N.NN s
--- 3. sequential docs (PGA leak check) ---
PASS  seq-doc-1: finalize succeeds
PASS  seq-doc-1: BLOB > 25 000 bytes
PASS  seq-doc-2: finalize succeeds
PASS  seq-doc-2: BLOB > 25 000 bytes
      2 × 5 000-row docs elapsed = N.NN s
---
benchmark_large_table: 10 passed, 0 failed.
```

### Uninstall

```sql
DROP PACKAGE rad_pdf_template;
DROP PACKAGE rad_pdf;
DROP PACKAGE rad_pdf_table;   DROP PACKAGE rad_pdf_layout;
DROP PACKAGE rad_pdf_canvas;  DROP PACKAGE rad_pdf_images;
DROP PACKAGE rad_pdf_fonts;   DROP PACKAGE rad_pdf_serial;
DROP PACKAGE rad_pdf_ctx;     DROP PACKAGE rad_pdf_styles;
DROP PACKAGE rad_pdf_codec;   DROP PACKAGE rad_pdf_units;
DROP PACKAGE rad_pdf_types;
```

---

## Quick Start

```sql
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  rad_pdf_styles.load_defaults;          -- load built-in styles (call once per session)

  l_doc := rad_pdf.new_document;         -- create document, get handle
  rad_pdf.heading(l_doc, 'My Report', 1);
  rad_pdf.write  (l_doc, 'Hello, World!');
  l_pdf := rad_pdf.finalize(l_doc);      -- close handle, get PDF as BLOB

  -- use the BLOB: write to a table, return via bind variable, etc.
  DBMS_OUTPUT.PUT_LINE('Size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  DBMS_LOB.FREETEMPORARY(l_pdf);     -- caller owns the BLOB; free when done
END;
```

The **only packages application code needs to call** are `rad_pdf` (Canvas API) and optionally
`rad_pdf_template` (Template engine).  All other packages are extensions for advanced use.

---

## Choose Your Approach

RAD_PDF offers two ways to generate a PDF.  Both use the same document handle and the same
underlying layout engine; choose based on your use case.

| | Canvas API | Template engine |
|---|---|---|
| **How** | Call individual procedures (`heading`, `write`, `query2table`, …) | Pass an XML-like CLOB string with `#BIND#` tokens to `rad_pdf_template.render` |
| **Best for** | Complex or unique layouts; canvas drawing (images at exact coordinates, polygons, rotated text); reports built entirely in PL/SQL | Consistent structure with varying content; templates stored in a DB table; rapid report development without per-element procedure calls |
| **Flexibility** | Full pixel-level control | Covers the most common document elements; falls back to Canvas API for unusual layouts |
| **Mixing** | Can call Canvas API before or between `render()` calls | Yes - both approaches share the same document handle |

**Quick template engine example:**

```sql
l_binds(1).key := 'DEPT'; l_binds(1).value := 'Accounting';

rad_pdf_template.render(l_doc,
  '<h1>#DEPT# Report</h1>'                          ||
  '<p>Revenue increased <b>18%</b> year-over-year.</p>' ||
  '<if bind="NOTES"><p>#NOTES#</p></if>',
  l_binds);
```

Full tag reference and patterns: **[TEMPLATE_GUIDE.md](TEMPLATE_GUIDE.md)**  
Template engine section of this guide: [Template Engine](#template-engine)

---

## Core Concepts

### Document handle

`rad_pdf.new_document` returns a `rad_pdf_types.t_doc_handle` (a `PLS_INTEGER`).  
Pass this handle to every subsequent call. **One handle = one document.**  
`rad_pdf.finalize` closes the handle and returns the PDF BLOB.  
After `finalize`, the handle is invalid - do not reuse it.

### Two rendering modes

| Mode | When | How |
|---|---|---|
| **Layout mode** | After any `rad_pdf.write`, `rad_pdf.heading`, `rad_pdf.query2table`, etc. | Content flows automatically across pages |
| **Canvas mode** | If you call only `rad_pdf_canvas.*` directly | You position every element by explicit coordinates |

You cannot mix both modes in the same document. Canvas calls before the first layout call are fine (they go to the first page before the layout engine takes over), but calling layout functions after canvas functions is not supported.

### Coordinate system

PDF origin is the **lower-left corner** of the page. Y increases upward.  
Default unit in most canvas calls is points (`'pt'`).  
`rad_pdf_units.to_pt(value, 'mm')` converts from other units.

| Unit | Conversion |
|---|---|
| `'pt'` / `'point'` | 1 pt = 1/72 inch (base unit) |
| `'mm'` | 1 mm ≈ 2.835 pt |
| `'cm'` | 1 cm ≈ 28.35 pt |
| `'in'` / `'inch'` | 1 in = 72 pt |

---

## Document Lifecycle

```sql
-- 1. (Optional) Load styles once per session
rad_pdf_styles.load_defaults;

-- 2. Create document
DECLARE
  l_info rad_pdf_types.t_doc_info;
  l_tpl  rad_pdf_types.t_page_template;
  l_doc  rad_pdf_types.t_doc_handle;
BEGIN
  l_info.title  := 'Annual Report';
  l_info.author := 'Finance Dept';
  -- l_tpl.page_format_name := 'A4';    -- optional template
  l_doc := rad_pdf.new_document(p_info => l_info /*, p_template => l_tpl*/);

  -- 3. Add content
  rad_pdf.heading(l_doc, 'Title', 1);
  rad_pdf.write  (l_doc, 'Body text...');

  -- 4a. Finalise - returns BLOB, closes handle
  DECLARE l_pdf BLOB; BEGIN
    l_pdf := rad_pdf.finalize(l_doc);
    -- … use l_pdf …
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- 4b. Or save to a directory
  -- rad_pdf.save(l_doc, 'MY_DIR', 'report.rad_pdf');
END;
```

### Aborting a document

If you need to discard a document without producing output:

```sql
rad_pdf.close_document(l_doc);   -- releases all memory, no PDF produced
```

---

## Layout Engine

The layout engine automatically wraps text, measures element heights, and breaks pages.  
Add content via `rad_pdf.write`, `rad_pdf.heading`, `rad_pdf.spacer`, `rad_pdf.query2table`, or the lower-level
`rad_pdf.add` with explicit flowable constructors.

### Text paragraphs

```sql
-- Default 'body' style
rad_pdf.write(l_doc, 'Normal paragraph text.');

-- Named style (built-in or custom)
rad_pdf.write(l_doc, 'Caption text here.', 'caption');
rad_pdf.write(l_doc, 'A warning message.', 'notice');  -- if you defined 'notice'
```

### Headings (h1 – h6)

```sql
rad_pdf.heading(l_doc, 'Chapter 1',    1);   -- largest
rad_pdf.heading(l_doc, 'Section 1.1',  2);
rad_pdf.heading(l_doc, 'Sub-section',  3);
```

Built-in heading styles `h1`–`h6`: Helvetica Bold, sizes 18 / 16 / 14 / 12 / 11 / 10 pt.

### Spacer

```sql
rad_pdf.spacer(l_doc, 12);   -- 12-point vertical gap
```

### Horizontal rule

```sql
rad_pdf.add(l_doc, rad_pdf_layout.h_rule());                    -- black, 0.5 pt
rad_pdf.add(l_doc, rad_pdf_layout.h_rule('808080', 1));         -- grey, 1 pt thick
```

### Explicit page break

```sql
rad_pdf.new_page(l_doc);   -- in layout mode: inserts a page-break flowable
```

### CLOB paragraphs

```sql
DECLARE l_text CLOB; BEGIN
  DBMS_LOB.CREATETEMPORARY(l_text, TRUE);
  DBMS_LOB.APPEND(l_text, 'Long body text stored as a CLOB...');
  rad_pdf.add(l_doc, rad_pdf_layout.paragraph(l_text, 'body'));
  -- Note: the layout engine takes ownership; do NOT free l_text manually
END;
```

---

## Canvas API

Use `rad_pdf_canvas.*` for precise pixel-level control: watermarks, diagrams, custom headers.

```sql
l_doc := rad_pdf.new_document;   -- new_document always creates the first page

-- Font and colour
rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 14);   -- family, style (N/B/I/BI), size
rad_pdf_canvas.set_color(l_doc, 'CC3300');                -- hex RGB ink colour

-- Text at absolute position (x, y in points from lower-left)
rad_pdf_canvas.write_text(l_doc, 'Hello', 72, 700, 'pt');

-- Word-wrapped text within a width
-- p_align: 'L' left (default), 'C' centre, 'R' right, 'J' justified
rad_pdf_canvas.write_wrapped(l_doc, 'Long text...', 72, 650, 400, 'L', 'pt');
rad_pdf_canvas.write_wrapped(l_doc, 'Justified paragraph...', 72, 600, 400, 'J', 'pt');

-- Lines and shapes
rad_pdf_canvas.h_line  (l_doc, 50, 740, 495, 0.5, '808080', 'pt');  -- horiz. line
rad_pdf_canvas.v_line  (l_doc, 50, 600, 100, 0.5, '000000', 'pt');  -- vert. line
rad_pdf_canvas.rect    (l_doc, 50, 600, 200, 80, '003366', 'E0F0FF', 1, 'pt');  -- border, fill
rad_pdf_canvas.polygon (l_doc, l_xs, l_ys, '000000', 'FFE0A0', 1);  -- arbitrary polygon

-- Dash patterns for lines and rectangles (unit-aware)
rad_pdf.set_line_dash(l_doc, 3, p_gap => 2, p_unit => 'mm');  -- 3mm dash, 2mm gap
rad_pdf_canvas.h_line(l_doc, 50, 550, 495, 0.5, '888888', 'pt');
rad_pdf.set_line_dash(l_doc, 0);  -- restore solid lines

-- New page (canvas mode)
rad_pdf_canvas.new_page(l_doc);

-- Finalize (canvas-only path: no layout pass)
l_pdf := rad_pdf.finalize(l_doc);
```

### State queries

Use `rad_pdf.get_info` (public facade) to query document state at any point
during generation:

```sql
l_pg := rad_pdf.get_info(l_doc, rad_pdf_types.c_info_page_nr);     -- current page (1-based)
l_w  := rad_pdf.get_info(l_doc, rad_pdf_types.c_info_page_width);  -- page width in pt
l_mt := rad_pdf.get_info(l_doc, rad_pdf_types.c_info_margin_top);  -- top margin in pt
```

| Constant | Returns |
|---|---|
| `c_info_page_nr` | Current page number (1-based) |
| `c_info_page_count` | Total pages finalised so far |
| `c_info_page_width` | Page width in pt |
| `c_info_page_height` | Page height in pt |
| `c_info_margin_top` | Top margin in pt |
| `c_info_margin_bot` | Bottom margin in pt |
| `c_info_margin_left` | Left margin in pt |
| `c_info_margin_right` | Right margin in pt |
| `c_info_cursor_x` | Current canvas X cursor in pt |
| `c_info_cursor_y` | Current canvas Y cursor in pt |
| `c_info_font_size` | Active font size in pt |

The same constants are also accessible via `rad_pdf_canvas.get_info` for use
inside `header_proc` / `footer_proc` strings.

---

## Tables

Tables are rendered by the layout engine using `rad_pdf.query2table` (facade shortcut)
or `rad_pdf_table.query2table` / `rad_pdf_table.refcursor2table` (lower-level).

### Minimal table

```sql
DECLARE
  l_cols rad_pdf_types.t_columns;
BEGIN
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(3);
  l_cols(1).label := 'ID';     l_cols(1).width := 50;
  l_cols(2).label := 'Name';   l_cols(2).width := 200;
  l_cols(3).label := 'Amount'; l_cols(3).width := 80;
  l_cols(3).data_fmt.align_h := 'R';

  rad_pdf.query2table(l_doc,
    'SELECT id, name, amount FROM my_table ORDER BY id',
    l_cols);
END;
```

### Column definition fields (`rad_pdf_types.t_column_def`)

| Field | Default | Description |
|---|---|---|
| `label` | NULL | Column header text |
| `width` | 30 | Column width in the unit set by `t_table_options.unit` |
| `wrap` | FALSE | When TRUE, data cell text wraps across multiple lines; row height expands to fit |
| `auto_width` | FALSE | v1.3.0: when TRUE, width is derived from content during the measure pass; `width` acts as a minimum floor |
| `max_width` | NULL | v1.3.0: upper cap for `auto_width` columns in the same unit as `width` (NULL = no cap) |
| `header_fmt` | Helvetica B 9, center | Header cell format (see below) |
| `data_fmt` | Helvetica N 9, left | Data cell format |
| `cell_row` | 1 | Row within a multi-line cell group (advanced) |
| `offset_x/y` | NULL | Cell offset in multi-line groups (advanced) |

When `wrap = TRUE` the column text flows top-to-bottom inside the cell. The
row height for that row is computed as the maximum wrapped height across all
wrap-enabled columns in the row. Non-wrap columns in the same row use the
computed height unchanged.

```sql
l_cols(2).label  := 'Notes';
l_cols(2).width  := 200;
l_cols(2).wrap   := TRUE;   -- long text wraps; row grows to fit
```

When `auto_width = TRUE` the column measures the widest header + data cell
in both fonts and sets the width accordingly, floored by `width` and capped
by `max_width`. No second query is run — measurement uses the row cache.
`num_format` is honoured during measurement (formatted string is measured,
not the raw value). `auto_width` and `wrap = TRUE` on the same column are
incompatible; `auto_width` is silently ignored when `wrap = TRUE`.

```sql
l_cols(2).label      := 'Name';
l_cols(2).width      := 40;        -- minimum 40 pt even if content is narrower
l_cols(2).auto_width := TRUE;      -- grow to fit widest cell
l_cols(2).max_width  := 150;       -- but never wider than 150 pt
```

### Cell format fields (`rad_pdf_types.t_cell_format`)

| Field | Default | Description |
|---|---|---|
| `font_name` | `'Helvetica'` | Font family name |
| `font_style` | `'N'` | `'N'`, `'B'`, `'I'`, `'BI'` |
| `font_size` | 10 | Points |
| `font_color` | `'000000'` | Hex RGB |
| `back_color` | `'ffffff'` | Background fill |
| `line_color` | `'000000'` | Border colour |
| `border` | 0 | Bitmask: `c_border_top=1`, `c_border_bottom=2`, `c_border_left=4`, `c_border_right=8`, `c_border_all=15` |
| `align_h` | `'L'` | `'L'` left, `'C'` centre, `'R'` right |

### Color scheme (`rad_pdf_types.t_color_scheme`)

```sql
DECLARE l_clr rad_pdf_types.t_color_scheme; BEGIN
  l_clr := rad_pdf_styles.default_scheme;   -- start from defaults
  l_clr.header_paper  := '003366';      -- navy header
  l_clr.header_ink    := 'FFFFFF';      -- white header text
  l_clr.odd_paper     := 'EEF4FF';      -- light blue odd rows
  rad_pdf.query2table(l_doc, l_query, l_cols, p_colors => l_clr);
END;
```

### Table options (`rad_pdf_types.t_table_options`)

| Field | Default | Description |
|---|---|---|
| `unit` | `'pt'` | Unit for `start_x`, `start_y`, column widths |
| `start_x` | 0 | Left edge (0 = use margin) |
| `start_y` | 0 | Top edge (0 = current cursor) |
| `bulk_size` | 200 | Rows fetched per batch |
| `max_rows` | NULL | Row limit (NULL = all) |
| `break_field` | 0 | Column index to group-break on (0 = none) |

### REF CURSOR

```sql
DECLARE
  l_rc SYS_REFCURSOR;
BEGIN
  OPEN l_rc FOR SELECT dept_id, dept_name FROM departments ORDER BY 1;
  rad_pdf_table.refcursor2table(l_doc, l_rc, l_cols);
END;
```

---

## Styles

Styles are **session-scoped** named sets of font + color + alignment properties.  
They survive `rad_pdf.finalize` and can be reused across documents in the same session.

### Built-in styles

| Name | Font | Size | Notes |
|---|---|---|---|
| `'body'` / `'default'` | Helvetica N | 10 | Base body text |
| `'h1'` … `'h6'` | Helvetica B | 18 / 16 / 14 / 12 / 11 / 10 | Heading levels |
| `'caption'` | Helvetica I | 8 | Small grey caption |
| `'table_header'` | Helvetica B | 9 | Table header row |
| `'table_even'` | Helvetica N | 9 | Even data rows |
| `'table_odd'` | Helvetica N | 9 | Odd data rows (light grey) |

### Defining custom styles

```sql
rad_pdf_styles.load_defaults;   -- ensure built-ins are loaded

rad_pdf_styles.define('notice',
  p_font_name  => 'Helvetica',
  p_font_style => 'BI',
  p_font_size  => 11,
  p_font_color => 'CC3300');

rad_pdf_styles.define('code',
  p_font_name  => 'Courier',
  p_font_style => 'N',
  p_font_size  => 9,
  p_back_color => 'F5F5F5');

-- Use in layout:
rad_pdf.write(l_doc, 'WARNING: disk usage above 90%.', 'notice');
rad_pdf.write(l_doc, 'SELECT * FROM dual;',             'code');
```

---

## Page Geometry

### Page format

```sql
-- By name (A4, A3, A5, LETTER, LEGAL, TABLOID)
rad_pdf.set_page_format(l_doc, 'A4');

-- By explicit dimensions (in points)
DECLARE l_fmt rad_pdf_types.t_page_format; BEGIN
  l_fmt.width  := 595.276;   -- A4 width
  l_fmt.height := 841.890;   -- A4 height
  rad_pdf.set_page_format(l_doc, l_fmt);
END;
```

### Orientation

```sql
rad_pdf.set_page_orientation(l_doc, 'LANDSCAPE');   -- swaps width and height
rad_pdf.set_page_orientation(l_doc, 'PORTRAIT');    -- restores if currently landscape
```

### Margins

```sql
-- Individual margins in points; NULL keeps the current value
rad_pdf.set_margins(l_doc,
  p_top    => 85.039,   -- ~3 cm
  p_bottom => 56.693,   -- ~2 cm
  p_left   => 42.520,   -- ~1.5 cm
  p_right  => 42.520);

-- Or via a record
DECLARE l_mar rad_pdf_types.t_margins; BEGIN
  l_mar.top    := rad_pdf_units.to_pt(3,   'cm');
  l_mar.bottom := rad_pdf_units.to_pt(2,   'cm');
  l_mar.left   := rad_pdf_units.to_pt(1.5, 'cm');
  l_mar.right  := rad_pdf_units.to_pt(1.5, 'cm');
  rad_pdf.set_margins(l_doc, l_mar);
END;
```

---

## Page Templates

A page template sets default geometry and registers header/footer PL/SQL blocks
that are executed on **every page** after the full render pass (so `#PAGE_COUNT#` is available).

```sql
DECLARE
  l_tpl rad_pdf_types.t_page_template;
BEGIN
  l_tpl.page_format_name := 'A4';
  l_tpl.margin_top       := 70;    -- points - leave room for header
  l_tpl.margin_bottom    := 50;    -- points - leave room for footer

  -- Header proc: anonymous PL/SQL block.
  -- Tokens substituted before execution:
  --   #DOC_HANDLE#  → the numeric document handle (for rad_pdf_canvas calls)
  --   #PAGE_NR#     → current page number (1-based)
  --   #PAGE_COUNT#  → total pages in the document
  l_tpl.header_proc :=
    'BEGIN ' ||
      'rad_pdf_canvas.set_font(#DOC_HANDLE#, ''Helvetica'', ''B'', 9); ' ||
      'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
        '''My Report  |  Page #PAGE_NR# of #PAGE_COUNT#'', 42, 818, ''pt''); ' ||
      'rad_pdf_canvas.h_line(#DOC_HANDLE#, 42, 810, 511, 0.4, ''808080'', ''pt''); ' ||
    'END;';

  l_tpl.footer_proc :=
    'BEGIN ' ||
      'rad_pdf_canvas.set_font(#DOC_HANDLE#, ''Helvetica'', ''I'', 8); ' ||
      'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
        '''Confidential'', 42, 28, ''pt''); ' ||
    'END;';

  l_doc := rad_pdf.new_document(p_template => l_tpl);
END;
```

> **Tip:** `rad_pdf_canvas.h_line(doc, x, y, width_pt, thickness, color, unit)` -
> a quick horizontal line without needing `set_color` separately.

### Multi-column layout

Set `n_columns` in `t_page_template` to split the content area into equal-width
columns. The layout engine fills each column top-to-bottom before advancing to the
next. `col_gap` sets the gutter width in points.

```sql
l_tpl.n_columns := 2;     -- two equal columns
l_tpl.col_gap   := 20;    -- 20 pt gutter between them

l_doc := rad_pdf.new_document(p_template => l_tpl);
rad_pdf.write(l_doc, 'Left column content…');
-- Layout engine fills column 1, then wraps to column 2 automatically.
```

`t_page_template` geometry fields at a glance:

| Field | Default | Description |
|---|---|---|
| `page_format_name` | NULL | Named page size: `'A4'`, `'A3'`, `'A5'`, `'LETTER'`, `'LEGAL'`, `'TABLOID'` |
| `page_width` / `page_height` | NULL | Explicit dimensions in points (use instead of `page_format_name`) |
| `margin_top/bottom/left/right` | NULL | Margins in points; NULL keeps the current document value |
| `n_columns` | 1 | Number of equal-width content columns |
| `col_gap` | 20 | Gutter between columns in points |
| `header_proc` | NULL | Anonymous PL/SQL block run on every page after render |
| `footer_proc` | NULL | Anonymous PL/SQL block run on every page after render |

### Cover page with header/footer from page 2

A common pattern is a custom cover on page 1 (no header, no footer) followed
by a standard header on every subsequent page. Use an `IF #PAGE_NR# > 1` guard
inside `header_proc` and `footer_proc`:

```sql
l_tpl.header_proc :=
  'BEGIN
     IF #PAGE_NR# > 1 THEN
       rad_pdf_canvas.write_text(#DOC_HANDLE#, ''My Report'', 42, 820, ''pt'');
       rad_pdf_canvas.h_line   (#DOC_HANDLE#, 42, 778, 511, 0.5, ''1A3A5C'', ''pt'');
     END IF;
   END;';
```

Then force page 2 after placing the cover content:

```sql
l_doc := rad_pdf.new_document;          -- no template yet
-- ... load images, build proc strings, call set_template ...
rad_pdf_layout.set_template(l_doc, l_tpl);

-- Cover content on page 1
rad_pdf.spacer (l_doc, 280);
rad_pdf.heading(l_doc, 'Annual Report 2026', 1);
rad_pdf.new_page(l_doc);               -- header/footer appear from here

-- Report content on pages 2+
rad_pdf.query2table(l_doc, l_query, l_cols);
```

> **Important:** `header_proc` runs via `EXECUTE IMMEDIATE` at finalize time.
> PL/SQL locals from the outer block are out of scope at that point. Embed
> runtime values (image IDs, dates, APEX session items) as string literals in
> the proc string before passing it to `set_template`.
> See [docs/apex/apex_sample05.sql](apex/apex_sample05.sql).

---

## Fonts

### Standard PDF fonts (always available, no embedding required)

`Helvetica`, `Times`, `Courier`, `Symbol`, `ZapfDingbats`  
Each available in styles: `'N'` (Normal), `'B'` (Bold), `'I'` (Italic), `'BI'` (Bold-Italic).

```sql
rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 14);
rad_pdf_canvas.set_font(l_doc, 'Times',     'I', 10);
rad_pdf_canvas.set_font(l_doc, 'Courier',   'N', 9);
```

### TrueType fonts (TTF / TTC)

Load from a BLOB, an Oracle Directory, or an HTTPS URL:

```sql
-- From Oracle directory (recommended for production)
DECLARE l_fi PLS_INTEGER; BEGIN
  l_fi := rad_pdf_fonts.load_ttf(l_doc, 'MY_FONTS_DIR', 'OpenSans-Regular.ttf',
            p_embed => TRUE, p_compress => TRUE);
  rad_pdf_canvas.set_font(l_doc, l_fi, 12);   -- use the returned font index
END;

-- From a BLOB
DECLARE l_fi PLS_INTEGER; l_blob BLOB; BEGIN
  -- … populate l_blob …
  l_fi := rad_pdf_fonts.load_ttf(l_doc, l_blob, p_embed => TRUE);
  rad_pdf_canvas.set_font(l_doc, l_fi, 12);
END;
```

**`p_embed => TRUE`** includes the font program in the PDF (required for fonts not available on
all viewer platforms). **`p_compress => TRUE`** (default) compresses the embedded program.

### Preloading TTF fonts for batch reports

Per-document fonts are freed on `finalize`. For batch reports generating many PDFs:

```sql
-- Preload once per session - survives close_doc
rad_pdf_fonts.preload_ttf('MY_FONTS_DIR', 'OpenSans-Regular.ttf', p_embed => TRUE);
-- Then in each loop iteration:
l_doc := rad_pdf.new_document;
rad_pdf_canvas.set_font(l_doc, 'OpenSans-Regular', 'N', 10);
l_pdf := rad_pdf.finalize(l_doc);
```

---

## Images

Load JPEG, PNG, or GIF images from a BLOB, Oracle Directory, or HTTPS URL.  
Images are cached per-session by SHA-256 hash (default cache limit: 50 MB).

**JPEG support (v1.4.1+):** both baseline (SOF0) and progressive (SOF2) JPEG files are
handled. CMYK JPEG files exported by Photoshop or Adobe tools are rendered correctly with
automatic `/ColorSpace /DeviceCMYK /Decode [1 0 1 0 1 0 1 0]` inversion.

```sql
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_img PLS_INTEGER;
BEGIN
  l_doc := rad_pdf.new_document;

  -- Load from Oracle directory
  l_img := rad_pdf_images.load_image(l_doc, 'MY_IMAGES_DIR', 'logo.png');

  -- Place on canvas (x, y in points from lower-left; width/height optional - keeps aspect)
  rad_pdf_canvas.put_image(l_doc, l_img, 42, 760, 120, NULL, 'L', 'T', 'pt');

  -- Or add to layout flow (auto-positioned by layout engine)
  rad_pdf.image(l_doc, l_img, 120, NULL);   -- width 120 pt, height = auto

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
```

### Batch image pattern

```sql
-- Before the batch loop:
rad_pdf_images.set_image_cache_limit(104857600);   -- 100 MB cache

-- After the batch loop:
rad_pdf_images.clear_image_cache;
```

---

## Template Engine

The template engine (`rad_pdf_template`) lets you describe a PDF as an XML-like CLOB string
instead of making per-element procedure calls.  It is the recommended approach for new reports
whose structure stays the same while content varies.

### Quick start

```sql
DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  l_binds(1).key := 'CUSTOMER'; l_binds(1).value := 'Acme Corp';
  l_binds(2).key := 'YEAR';     l_binds(2).value := '2025';

  rad_pdf_template.render(l_doc,
    '<h1>#CUSTOMER# - Annual Report #YEAR#</h1>'    ||
    '<p>Revenue grew <b>18%</b> year-over-year.</p>',
    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
```

### Supported block tags

| Tag | Description |
|---|---|
| `<p [style="name"]>…</p>` | Paragraph; optional style name |
| `<h1>…</h1>` … `<h6>…</h6>` | Headings; inline markup supported |
| `<ul><li>…</li></ul>` | Unordered (bullet) list |
| `<ol><li>…</li></ol>` | Ordered (numbered) list |
| `<spacer [height="20pt"]/>` | Vertical gap; any unit (pt, mm, cm) |
| `<hr [color="RRGGBB"] [width="N"]/>` | Horizontal rule |
| `<img id="N" [width="Xmm"] [height="Ymm"]/>` | Embedded image by image-ID |
| `<table columns="NAME" query="…" allow_query="true" …/>` | Data table |
| `<pagebreak/>` | Explicit page break |

### Supported inline tags (inside `<p>`, `<li>`, `<h1>`–`<h6>`)

| Tag | Description |
|---|---|
| `<b>…</b>` | Bold run |
| `<i>…</i>` | Italic run |
| `<br/>` | Forced line break within the paragraph |
| `<color rgb="RRGGBB">…</color>` | Custom ink colour; unlimited nesting depth |
| `<font size="Xpt">…</font>` | Custom font size; unlimited nesting depth |

### Bind substitution

```sql
-- Bind values are auto-escaped (&, <, > → entities) by default.
-- Set raw=TRUE only for values that already contain trusted inline markup.
l_binds(1).key   := 'NOTES';
l_binds(1).value := apex_item.text(1);  -- user-supplied: keep raw=FALSE (default)

l_binds(2).key   := 'STATUS_HTML';
l_binds(2).value := '<b><color rgb="006600">Active</color></b>';
l_binds(2).raw   := TRUE;              -- trusted markup from PL/SQL code
```

### Conditional blocks

```sql
-- Block is rendered only when the bind value for KEY is non-NULL and non-empty.
-- Tokens inside a suppressed block are never evaluated.
'<if bind="COMM"><p>Commission: #COMM#</p></if>'
```

Blocks are included when the bind exists with a non-NULL value. *(v1.6.0)*
`eq="V"` / `ne="V"` compare the bind value (case-insensitive): see
[TEMPLATE_GUIDE.md](TEMPLATE_GUIDE.md#conditional-blocks) for the full rules.

### Data tables

```sql
-- 1. Register a named column set once per session.
rad_pdf_template.register_columns('EMP_COLS', l_cols);

-- 2. Reference it in the template; enable queries in t_template_options.
l_opts.allow_queries := TRUE;

rad_pdf_template.render(l_doc,
  '<table columns="EMP_COLS"'
    || ' query="SELECT empno, ename, sal FROM emp WHERE deptno = #DEPTNO#"'
    || ' allow_query="true"/>',
  l_binds, l_opts);
```

Both `allow_query="true"` on the tag **and** `allow_queries := TRUE` in the options are required.
Omitting either raises ORA-20815.

### Multiple render() calls

```sql
-- Multiple render() calls on the same handle are additive (append, not replace).
rad_pdf_template.render(l_doc, '<h1>Cover</h1>…');            -- page 1
FOR dept IN c_dept LOOP
  rad_pdf_template.render(l_doc, '<pagebreak/><h1>#DNAME#</h1>…', l_binds, l_opts);
END LOOP;
rad_pdf_template.render(l_doc, '<pagebreak/><p>End of report.</p>');
l_pdf := rad_pdf.finalize(l_doc);
```

### Full reference

**[TEMPLATE_GUIDE.md](TEMPLATE_GUIDE.md)** - complete tag catalogue, all attributes, error codes,
security notes, and patterns for APEX and non-APEX use.

---

## Watermarks

A watermark is a translucent text or image stamped across every page of the
document, typically used to mark a report as DRAFT, CONFIDENTIAL, or to display
a company logo in the background.

### `set_watermark` - text watermark

```sql
rad_pdf.set_watermark(
  p_doc       => l_doc,
  p_text      => 'DRAFT',
  p_font_name => 'Helvetica',
  p_font_size => 72,
  p_color     => 'C0C0C0',
  p_opacity   => 0.3,
  p_angle     => 45,
  p_layer     => 'UNDER');
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `p_doc` | `t_doc_handle` | - | Document handle returned by `new_document`. |
| `p_text` | `VARCHAR2` | - | Watermark text. Must be non-NULL and non-empty (ORA-20400 if blank). |
| `p_font_name` | `VARCHAR2` | `'Helvetica'` | Standard PDF font name or a loaded TTF font name. |
| `p_font_size` | `NUMBER` | `60` | Font size in points. Must be > 0 (ORA-20400 if not). Always in points - no unit conversion. |
| `p_color` | `t_rgb` | `'C0C0C0'` | 6-character uppercase hex RGB colour string (e.g. `'C0C0C0'` for light grey, `'FF0000'` for red). |
| `p_opacity` | `NUMBER` | `0.3` | Transparency: 0.0 = fully invisible, 1.0 = fully opaque. Must be in [0.0, 1.0] (ORA-20400 if not). |
| `p_angle` | `NUMBER` | `45` | Rotation in counter-clockwise degrees. Must be in [-360, 360] (ORA-20400 if not). 45 = default diagonal. |
| `p_layer` | `VARCHAR2` | `'UNDER'` | `'UNDER'` draws the watermark behind page content; `'OVER'` draws it on top. Any other value raises ORA-20400. |
| `p_pages` | `VARCHAR2` | `NULL` | *(v1.6.0)* 1-based page selection: `'1'`, `'2-5'`, `'3-'` (open range) or combinations `'1,3-5,8-'`. `NULL` = every page. Malformed specs raise ORA-20400. |

### `set_watermark_image` - image watermark

```sql
rad_pdf.set_watermark_image(
  p_doc       => l_doc,
  p_image_id  => l_logo_id,
  p_opacity   => 0.25,
  p_width_pct => 50,
  p_layer     => 'UNDER');
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `p_doc` | `t_doc_handle` | - | Document handle returned by `new_document`. |
| `p_image_id` | `PLS_INTEGER` | - | Image ID returned by `rad_pdf_images.load_image`. Must be registered for this document (ORA-20710 if not). |
| `p_opacity` | `NUMBER` | `0.3` | Transparency: 0.0 = fully invisible, 1.0 = fully opaque. Must be in [0.0, 1.0] (ORA-20400 if not). |
| `p_width_pct` | `NUMBER` | `60` | Width of the watermark image as a percentage of the page width (1-100). Aspect ratio is preserved. Must be in [1, 100] (ORA-20400 if not). |
| `p_layer` | `VARCHAR2` | `'UNDER'` | `'UNDER'` draws the watermark behind page content; `'OVER'` draws it on top. Any other value raises ORA-20400. |
| `p_pages` | `VARCHAR2` | `NULL` | *(v1.6.0)* 1-based page selection: `'1'`, `'2-5'`, `'3-'` (open range) or combinations `'1,3-5,8-'`. `NULL` = every page. Malformed specs raise ORA-20400. |

### `clear_watermark`

```sql
rad_pdf.clear_watermark(p_doc => l_doc);
```

Removes any previously registered watermark from the document. This is a no-op
if no watermark was set.

### Notes

- **One watermark per document.** Calling `set_watermark` or `set_watermark_image`
  a second time replaces the first registration entirely.
- **UNDER vs OVER.** `'UNDER'` (default) places the watermark behind all page
  content so text and tables remain easy to read. `'OVER'` places it in front,
  which can partially obscure content.
- **Opacity.** 0.0 is fully invisible; 1.0 is fully opaque. Values around 0.2-0.4
  are typical for DRAFT or CONFIDENTIAL marks.
- **Angle.** Rotation is counter-clockwise in degrees. 45 (the default) produces
  a diagonal mark from the lower-left to the upper-right corner of the page.
- **`p_font_size` is always in points.** Watermarks are page-level elements that
  are not tied to the document unit setting, so no `p_um` conversion is applied.
- **`p_image_id` must be loaded before calling `set_watermark_image`.** Use
  `rad_pdf_images.load_image` to obtain the ID. Passing an ID that is not
  registered for the document raises ORA-20710.
- **No watermark - no overhead.** When no watermark is set, the output is
  byte-identical to that produced by earlier versions of RAD_PDF.

### Quick example

```sql
l_doc := rad_pdf.new_document;
rad_pdf.heading(l_doc, 'Q1 Report', 1);
rad_pdf.query2table(l_doc, 'SELECT empno, ename, sal FROM emp', l_cols);
rad_pdf.set_watermark(l_doc, 'DRAFT', p_color => 'C0C0C0', p_opacity => 0.3);
l_pdf := rad_pdf.finalize(l_doc);
```

---

## Line Dash Patterns

`set_line_dash` sets the dash pattern for all subsequently stroked paths (lines, rectangles, polygons) until it is changed or reset.

```sql
-- 3 mm dash, 2 mm gap, starting at offset 0
rad_pdf.set_line_dash(l_doc, 3, p_gap => 2, p_unit => 'mm');
rad_pdf_canvas.h_line(l_doc, 50, 500, 495, 0.5, '555555', 'pt');

-- Symmetric: 5 pt dash and 5 pt gap (p_gap defaults to p_dash)
rad_pdf.set_line_dash(l_doc, 5);
rad_pdf_canvas.rect(l_doc, 50, 400, 200, 80, '003366', NULL, 1, 'pt');

-- Reset to solid lines
rad_pdf.set_line_dash(l_doc, 0);
```

### `set_line_dash` parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `p_doc` | `t_doc_handle` | - | Document handle. |
| `p_dash` | `NUMBER` | - | Dash length. Pass `0` to restore solid lines. |
| `p_gap` | `NUMBER` | `p_dash` | Gap length. Defaults to `p_dash` for a symmetric pattern. |
| `p_phase` | `NUMBER` | `0` | Offset into the pattern before the first dash (rarely needed). |
| `p_unit` | `t_unit` | `'pt'` | Unit for `p_dash`, `p_gap`, and `p_phase` (`'pt'`, `'mm'`, `'cm'`, `'in'`). |

**Notes:**
- The dash pattern persists in the graphics state until changed or until the page is closed. Use `set_line_dash(l_doc, 0)` to return to solid lines before switching styles.
- Dash patterns affect all stroked paths: `line`, `h_line`, `v_line`, `rect` (stroke only — fill is unaffected), `polygon`, `path`.

---

## Persistent Graphics-State Setters

`set_draw_color`, `set_fill_color`, and `set_line_width` store values in the
per-document canvas state. `line`, `h_line`, and `v_line` inherit these values
when their per-call `p_color` / `p_line_width` parameter is `NULL` (the default).

```sql
-- Set once; all subsequent h_line / v_line / line calls inherit these values.
rad_pdf.set_draw_color(l_doc, '1A3A5C');   -- dark navy stroke
rad_pdf.set_line_width(l_doc, 1.5, 'pt');  -- 1.5 pt line

-- These two calls inherit the persistent state (no per-call color/width needed).
rad_pdf_canvas.h_line(l_doc, 42, 780, 511, NULL, NULL, 'pt');
rad_pdf_canvas.h_line(l_doc, 42, 50,  511, NULL, NULL, 'pt');

-- Override for one call only; persistent state is unchanged.
rad_pdf_canvas.h_line(l_doc, 42, 415, 511, 0.3, 'AAAAAA', 'pt');

-- Reset to defaults.
rad_pdf.set_draw_color(l_doc, '000000');
rad_pdf.set_line_width(l_doc, 0.5, 'pt');
```

### Parameters

| Procedure | Parameter | Default | Description |
|---|---|---|---|
| `set_draw_color` | `p_rgb` | `'000000'` | Hex RGB stroke color for `line`, `h_line`, `v_line`. |
| `set_fill_color` | `p_rgb` | `NULL` | Reserved persistent fill. `rect`, `polygon`, `path` still use their per-call `p_fill_color`. |
| `set_line_width` | `p_width` | `0.5` | Line width for `line`, `h_line`, `v_line`. |
| `set_line_width` | `p_unit` | `'pt'` | Unit for `p_width` (`'pt'`, `'mm'`, `'cm'`, `'in'`). |

**Notes:**
- Initial state on `new_document`: stroke `'000000'`, fill `NULL`, width `0.5 pt` — identical to the previous hard-coded defaults, so **all existing code is backward-compatible**.
- `rect`, `polygon`, and `path` are per-call only: `p_line_color = NULL` still means "no stroke" for those primitives.
- `set_fill_color` stores a value but it is not yet read by `rect`/`polygon`/`path`. Its primary use is as an explicit documentation of the intended fill before a drawing loop, or for future extension.

---

## QR Codes

*(v1.6.0)* `rad_pdf_barcode.qrcode` draws a QR code as **pure vector
graphics** — filled PDF paths, no raster images — so it scales perfectly at
any print resolution. The facade shortcut `rad_pdf.qrcode` delegates to it.

```sql
-- 40 mm payment QR at x=150mm, y=240mm (lower-left corner of the square)
rad_pdf.qrcode(l_doc,
  p_value => 'https://pay.example.com/invoice/2026-0042',
  p_x     => 150, p_y => 240, p_size => 40,
  p_unit  => 'mm');
```

### `qrcode` parameters

| Parameter | Default | Description |
|---|---|---|
| `p_value` | — | Text/URL to encode. Encoding mode (numeric, alphanumeric, byte, UTF-8 ECI) and QR version (1–40) are selected automatically. |
| `p_x`, `p_y` | — | Lower-left corner of the QR square (canvas convention). |
| `p_size` | — | Side of the square. **Includes** the mandatory 4-module quiet zone. |
| `p_ec_level` | `'M'` | Error correction: `L` (7%), `M` (15%), `Q` (25%), `H` (30%). Unknown values fall back to `M`. |
| `p_color` | `'000000'` | Module color (6-char hex RGB). Keep strong contrast against the background. |
| `p_unit` | `'pt'` | Unit for `p_x`, `p_y`, `p_size`. |

### Sizing for print

`rad_pdf_barcode.qrcode_modules(p_value, p_ec_level)` returns the number of
modules per side (quiet zone included) without drawing. For reliable scanning
of printed documents keep the module size at or above ~0.8–1 mm:

```sql
l_modules := rad_pdf_barcode.qrcode_modules(l_url, 'M');  -- e.g. 37
-- p_size = 40mm -> module = 40/37 = 1.08 mm -> OK for print
```

### Notes

- Raises `c_err_barcode` (-20820) for NULL values, `p_size <= 0`, or content
  exceeding QR version 40 capacity at the requested EC level.
- UTF-8 content is encoded via ECI designator 26; accented characters
  round-trip byte-perfect.
- Higher EC levels produce denser codes but tolerate more damage — use `H`
  when overlaying a logo or printing on low-quality media.
- QR encoding logic ported from [as_barcode](https://github.com/antonscheffer/as_barcode)
  by Anton Scheffer (MIT license).

See [sample17.sql](sample17.sql) for payment-link, vCard and coloured-QR
examples.

---

## 1D Barcodes

*(v1.6.0)* Code 128, Code 39 and EAN-13, rendered as vector bars. The
generic facade `rad_pdf.barcode` covers the common cases; the
`rad_pdf_barcode` procedures expose symbology-specific options.

```sql
-- The bars fill the width × height box (quiet zones included)
rad_pdf.barcode(l_doc, 'CODE128', 'RAD-PDF-2026',
                p_x => 20, p_y => 240, p_width => 80, p_height => 18,
                p_unit => 'mm');

-- EAN-13 at nominal size: pass the module width instead of a total width
rad_pdf_barcode.ean13(l_doc, '590123412345',     -- check digit computed
                      p_x => 20, p_y => 190, p_height => 26, p_unit => 'mm');
```

### Symbologies

| Type | Charset / input | Notes |
|---|---|---|
| `CODE128` | Any Latin-1 text | Subset C auto-selected for all-numeric values (digits pack two per symbol); subset B otherwise; high bytes via FNC4 |
| `CODE39` | `A-Z 0-9 space - . $ / + %` | `p_full_ascii => TRUE` (direct API) enables extended Code 39 (full ASCII incl. lowercase); human-readable line shows the conventional `*…*` delimiters |
| `EAN13` | 1–13 digits | < 13 digits → left-padded to 12, check digit computed. Exactly 13 → check digit **validated** (`c_err_barcode` on mismatch). Standard layout: lead digit in the quiet zone, guard bars descending through the digit line |

### Notes

- `p_show_text` (default `TRUE`) prints the human-readable line under the
  bars; it is skipped automatically when the symbol is too short. The
  current document font is saved and restored.
- EAN-13 width is fixed by the standard at 113 modules including quiet
  zones; the nominal module is 0.33 mm (symbol ≈ 37.3 mm). Through the
  generic facade the module is derived as `p_width / 113`.
- For reliable laser-scanner reading keep the Code 128 module
  (`p_width / total modules`) at or above ~0.25 mm.

See [sample18.sql](sample18.sql) for a label-sheet example and
[apex/apex_sample14.sql](apex/apex_sample14.sql) for barcode labels from a
query in APEX.

---

## Bookmarks (Document Outline)

*(v1.6.0)* Bookmarks populate the PDF reader's outline sidebar; clicking an
entry jumps to the exact position. When at least one bookmark exists the
document opens with the sidebar visible (`/PageMode /UseOutlines`).

The simplest path — mirror headings into the outline:

```sql
rad_pdf.heading(l_doc, 'Chapter 1',   1, p_bookmark => TRUE);
rad_pdf.heading(l_doc, 'Section 1.1', 2, p_bookmark => TRUE);  -- nests under Chapter 1
```

Manual entries at any position (canvas mode included):

```sql
rad_pdf.add_bookmark(l_doc, 'Signature block', 1, p_y => 45, p_unit => 'mm');
```

### Rules

- **Hierarchy**: an entry nests under the nearest previous entry with a
  lower level (1–6, clamped). Level jumps are tolerated.
- **Destination**: `p_y` is the y to scroll to (top of the content);
  `NULL` = current cursor position plus the active font size. With
  `heading(p_bookmark => TRUE)` the destination is the exact top of the
  heading as placed by the layout engine — page breaks included.
- **Titles**: up to 500 characters; non-ASCII titles are written as
  UTF-16BE automatically (accents render correctly in every viewer).
- All entries are created expanded. No bookmarks → no `/Outlines` entry,
  output identical to previous versions.

See [sample19.sql](sample19.sql) for a navigable multi-chapter report.

---

## Charts

*(v1.7.0)* `rad_pdf_chart` draws single-series **bar**, **line** and **pie**
charts as pure vector graphics — axes, gridlines, bars and Bézier pie
slices, no images. Facade shortcuts: `rad_pdf.bar_chart`,
`rad_pdf.line_chart`, `rad_pdf.pie_chart`.

```sql
DECLARE
  l_v rad_pdf_types.t_number_list;   -- dense 1..n values
  l_l rad_pdf_types.t_text_list;     -- optional category labels
BEGIN
  l_v(1) := 120; l_v(2) := 340; l_v(3) := 90;
  l_l(1) := 'Gen'; l_l(2) := 'Feb'; l_l(3) := 'Mar';
  rad_pdf.bar_chart(l_doc, l_v,
                    p_x => 15, p_y => 195, p_width => 85, p_height => 60,
                    p_labels => l_l, p_title => 'Fatturato (k)', p_unit => 'mm');
END;
```

### Rules

- **Values** (`t_number_list`) must be dense `1..n` and non-NULL.
  Bar and pie values must be `>= 0`; the pie total must be `> 0`.
  Line charts accept negative values (the zero axis is drawn inside the plot).
- **Y scale** uses "nice numbers" (1/2/5 × 10^k steps): gridline labels are
  always round values.
- **Colours**: built-in 10-colour palette by default; pass `p_colors`
  (`t_rgb_list`) to override. Colours cycle when data points outnumber them.
- **Pie**: slices start at 12 o'clock, clockwise; legend (swatch + label +
  percentage) appears at the right when `p_labels` is supplied.
- The current document font is saved and restored around every chart.
- Validation failures raise `c_err_validation` (-20400).

See [sample20.sql](sample20.sql) for a dashboard with all three types.

---

## PDF/A Conformance

*(v1.7.0)* `rad_pdf.set_conformance(l_doc, 'PDF/A-2B')` produces an
**ISO 19005-2 (PDF/A-2b)** conformant document — the archival-grade format
required for long-term preservation (and, in Italy, "conservazione
sostitutiva"). Call it right after `new_document`, before adding content.

At finalize the document gains:

- **XMP metadata** synchronised with the Info dictionary (title, author,
  subject, keywords share a single timestamp — validators check this);
- an **sRGB OutputIntent** (embedded 456-byte CC0 ICC profile);
- the **file `/ID`** in the trailer.

### Rules

- **Every used font must be embedded**: load a TrueType with
  `rad_pdf_fonts.load_ttf(..., p_embed => TRUE)`. The standard 14 PDF
  fonts are metrics-only and raise `c_err_font` (-20700) naming the
  offending font.
- Charts inherit the current document font — set the embedded font before
  drawing them.
- Vector content (charts, QR/barcodes) and images work as usual; watermark
  transparency is allowed (PDF/A-2 permits it; PDF/A-1 would not).
- Unsupported levels raise `c_err_validation`; only `'PDF/A-2B'` is
  accepted in v1.7.

**Validation**: outputs verified with [veraPDF](https://verapdf.org)
(`verapdf -f 2b file.pdf` → `isCompliant="true"`, 144 rules). See
[sample21.sql](sample21.sql).

---

## API Reference

### `rad_pdf` package - public facade

| Subprogram | Description |
|---|---|
| `version` | Return the library version string, e.g. `'1.5.1'`. |
| `new_document(p_info, p_template)` | Create document. Returns handle. |
| `finalize(p_doc)` | Finalise, close handle, return BLOB. Caller must `FREETEMPORARY`. |
| `save(p_doc, p_dir, p_filename)` | Finalise and write to Oracle directory. |
| `close_document(p_doc)` | Discard document without producing output. |
| `write(p_doc, p_text, p_style)` | Add paragraph (layout mode). |
| `heading(p_doc, p_text, p_level, p_bookmark)` | Add heading h1–h6 (layout mode); `p_bookmark => TRUE` also registers an outline entry. |
| `add_bookmark(p_doc, p_title, p_level, p_y, p_unit)` | Register a PDF outline entry at the current page. See [Bookmarks](#bookmarks-document-outline). |
| `spacer(p_doc, p_height)` | Add vertical gap in points (layout mode). |
| `add(p_doc, p_flow)` | Add a pre-built flowable (layout mode). |
| `new_page(p_doc)` | Page break (layout) or new page (canvas). |
| `query2table(p_doc, p_query, p_columns, ...)` | Add table from SQL string or CLOB. |
| `refcursor2table(p_doc, p_rc, p_columns, ...)` | Add table from an open `SYS_REFCURSOR`. |
| `image(p_doc, p_image_id, p_width, p_height)` | Add image flowable (layout mode). |
| `qrcode(p_doc, p_value, p_x, p_y, p_size, p_ec_level, p_color, p_unit)` | Draw a vector QR code. See [QR Codes](#qr-codes). |
| `barcode(p_doc, p_type, p_value, p_x, p_y, p_width, p_height, p_show_text, p_color, p_unit)` | Draw a 1D barcode: `p_type` = `'CODE128'`, `'CODE39'` or `'EAN13'`. See [1D Barcodes](#1d-barcodes). |
| `bar_chart(p_doc, p_values, p_x, p_y, p_width, p_height, p_labels, p_colors, p_show_values, p_title, p_unit)` | Vertical bar chart. See [Charts](#charts). |
| `line_chart(p_doc, p_values, p_x, p_y, p_width, p_height, p_labels, p_colors, p_show_markers, p_title, p_unit)` | Single-series line chart (negatives supported). |
| `pie_chart(p_doc, p_values, p_cx, p_cy, p_radius, p_labels, p_colors, p_legend, p_title, p_unit)` | Pie chart with optional legend. |
| `set_conformance(p_doc, p_level)` | Switch the document to PDF/A-2b mode. See [PDF/A Conformance](#pdfa-conformance). |
| `get_info(p_doc, p_info)` | Query document state. Pass a `c_info_*` constant; returns NUMBER in pt. |
| `set_page_format(p_doc, p_name_or_fmt)` | Set page size by name or `t_page_format`. |
| `set_page_orientation(p_doc, p_orientation)` | `'PORTRAIT'` or `'LANDSCAPE'`. |
| `set_margins(p_doc, p_top, p_bottom, p_left, p_right)` | Set individual margins (points). |
| `set_watermark(p_doc, p_text, p_font_name, p_font_size, p_color, p_opacity, p_angle, p_layer)` | Register a text watermark applied to every page at finalization. See [Watermarks](#watermarks). |
| `set_watermark_image(p_doc, p_image_id, p_opacity, p_width_pct, p_layer)` | Register an image watermark applied to every page at finalization. See [Watermarks](#watermarks). |
| `clear_watermark(p_doc)` | Remove any registered watermark. No-op if none was set. |
| `set_line_dash(p_doc, p_dash, p_gap, p_phase, p_unit)` | Set line dash pattern for subsequent stroked paths. `p_dash=0` restores solid lines. See [Line Dash Patterns](#line-dash-patterns). |
| `set_draw_color(p_doc, p_rgb)` | Set persistent stroke color used by `line`, `h_line`, `v_line` when `p_color` is omitted. Default `'000000'`. See [Persistent Graphics-State Setters](#persistent-graphics-state-setters). |
| `set_fill_color(p_doc, p_rgb)` | Set persistent fill color. Default `NULL`. See [Persistent Graphics-State Setters](#persistent-graphics-state-setters). |
| `set_line_width(p_doc, p_width, p_unit)` | Set persistent line width used by `line`, `h_line`, `v_line` when `p_width` is omitted. Default `0.5 pt`. See [Persistent Graphics-State Setters](#persistent-graphics-state-setters). |
| `render_template(p_doc, p_clob_or_varchar2, ...)` | Shortcut for `rad_pdf_template.render`. Four overloads: CLOB or VARCHAR2 × with or without `p_binds`. See [Template Engine](#template-engine). |

### `rad_pdf_table` package - table and label rendering

| Subprogram | Description |
|---|---|
| `query2table(p_doc, p_query, p_columns, p_colors, p_options)` | Render a table from a SQL string or CLOB query. |
| `refcursor2table(p_doc, p_rc, p_columns, p_colors, p_options)` | Render a table from an open `SYS_REFCURSOR`. |
| `query2labels(p_doc, p_query, p_columns, p_label, p_colors, p_options)` | Render a peel-off label grid from a SQL string or CLOB query. `p_label` is a `t_label_def` record (columns, rows, width, height, spacing). |
| `refcursor2labels(p_doc, p_rc, p_columns, p_label, p_colors, p_options)` | Label grid from an open `SYS_REFCURSOR`. |

**`t_label_def` fields:**

| Field | Default | Description |
|---|---|---|
| `max_columns` | 2 | Number of label columns across the page |
| `max_rows` | 8 | Number of label rows down the page |
| `width` | 170.079 | Label width in points (~6 cm) |
| `height` | 85.039 | Label height in points (~3 cm) |
| `h_distance` | 14.173 | Horizontal gap between labels in points |
| `v_distance` | 0 | Vertical gap between labels in points |

### `rad_pdf_canvas` package - drawing primitives

| Subprogram | Description |
|---|---|
| `new_page(p_doc)` | Append a new blank page and make it current. |
| `goto_page(p_doc, p_page_nr)` | Make an existing page current for further drawing. 1-based. |
| `set_font(p_doc, p_family, p_style, p_size)` | Set font by name + style (`'N'`,`'B'`,`'I'`,`'BI'`) + size in pt. |
| `set_font(p_doc, p_font_idx, p_size)` | Set font by index returned from `rad_pdf_fonts.load_ttf`. |
| `set_color(p_doc, p_rgb)` | Set ink (text) colour. Default `'000000'`. |
| `set_bk_color(p_doc, p_rgb)` | Set background colour used for highlighted text. Default `'ffffff'`. |
| `set_draw_color(p_doc, p_rgb)` | Persistent stroke colour for `line`/`h_line`/`v_line`. |
| `set_fill_color(p_doc, p_rgb)` | Persistent fill colour (see [Persistent Graphics-State Setters](#persistent-graphics-state-setters)). |
| `set_line_width(p_doc, p_width, p_unit)` | Persistent line width for `line`/`h_line`/`v_line`. |
| `write_text(p_doc, p_text, p_x, p_y, p_unit, p_rotation)` | Place text at absolute canvas coordinates; optional rotation in degrees. |
| `write_wrapped(p_doc, p_text, p_x, p_y, p_width, p_align, p_unit, p_leading)` | Word-wrap text within a column width. `p_align`: `'L'`,`'C'`,`'R'`,`'J'`. |
| `text_width(p_doc, p_text)` | Return the width of `p_text` in points at the current font. Useful for manual positioning. |
| `measure_wrapped(p_doc, p_text, p_width, p_unit, p_leading)` | Return the total height in points that `p_text` would occupy when wrapped to `p_width`. |
| `line(p_doc, p_x1, p_y1, p_x2, p_y2, p_color, p_width, p_unit)` | Draw a line between two points. `NULL` color/width inherits persistent state. |
| `h_line(p_doc, p_x, p_y, p_width, p_line_width, p_color, p_unit)` | Horizontal line. `NULL` color/width inherits persistent state. |
| `v_line(p_doc, p_x, p_y, p_height, p_line_width, p_color, p_unit)` | Vertical line. `NULL` color/width inherits persistent state. |
| `rect(p_doc, p_x, p_y, p_width, p_height, p_line_color, p_fill_color, p_line_width, p_unit)` | Rectangle. `NULL` line_color = no stroke; `NULL` fill_color = no fill. |
| `polygon(p_doc, p_xs, p_ys, p_line_color, p_fill_color, p_line_width)` | Arbitrary polygon from coordinate arrays. |
| `path(p_doc, p_path, p_line_color, p_fill_color, p_line_width)` | Bezier path from a `t_path` array of `t_path_element` records (move-to, line-to, curve-to, close). |
| `set_line_dash(p_doc, p_dash, p_gap, p_phase, p_unit)` | Set dash pattern for subsequent stroked paths. `p_dash=0` restores solid lines. |
| `put_image(p_doc, p_image_id, p_x, p_y, p_width, p_height, p_align, p_valign, p_unit)` | Place image at absolute canvas coordinates. |
| `add_page_proc(p_doc, p_src)` | Register an additional PL/SQL block to run on every page (VARCHAR2 or CLOB). Appended after the template's `header_proc`/`footer_proc`. Tokens: `#PAGE_NR#`, `#PAGE_COUNT#`, `#DOC_HANDLE#`. |
| `add_bookmark(p_doc, p_title, p_level, p_y, p_unit)` | Register a PDF outline entry at the current page. See [Bookmarks](#bookmarks-document-outline). |
| `get_x(p_doc)` | Return current canvas X cursor in points. |
| `get_y(p_doc)` | Return current canvas Y cursor in points. |
| `get_info(p_doc, p_what)` | Return a numeric document property (same constants as `rad_pdf.get_info`). |

### `rad_pdf_layout` package - flowable constructors

| Function | Returns |
|---|---|
| `paragraph(p_text, p_style)` | `t_flowable` for a text paragraph |
| `heading(p_text, p_level)` | `t_flowable` for a heading |
| `spacer(p_height)` | `t_flowable` for a vertical gap |
| `h_rule(p_color, p_width)` | `t_flowable` for a horizontal line |
| `page_break` | `t_flowable` for an explicit page break |
| `image(p_image_id, p_width, p_height)` | `t_flowable` for an image |

### `rad_pdf_styles` package - style registry

| Subprogram | Description |
|---|---|
| `load_defaults` | Load built-in styles (idempotent). Call once per session. |
| `define(p_name, p_font_name, p_font_style, p_font_size, ...)` | Define or update a named style. |
| `get(p_name)` | Retrieve a `t_cell_format` by name. |
| `default_scheme` | Return a `t_color_scheme` built from built-in table styles. |

### `rad_pdf_barcode` package - QR codes and 1D barcodes (v1.6.0)

| Subprogram | Description |
|---|---|
| `qrcode(p_doc, p_value, p_x, p_y, p_size, p_ec_level, p_color, p_unit)` | Draw a QR code as filled vector paths. See [QR Codes](#qr-codes). |
| `qrcode_modules(p_value, p_ec_level)` | Return modules per side (quiet zone included) without drawing — for print-size calculations. |
| `code128(p_doc, p_value, p_x, p_y, p_width, p_height, p_show_text, p_color, p_unit)` | Code 128, subsets B/C auto-selected. See [1D Barcodes](#1d-barcodes). |
| `code39(p_doc, p_value, p_x, p_y, p_width, p_height, p_show_text, p_full_ascii, p_color, p_unit)` | Code 39; `p_full_ascii` enables extended ASCII. |
| `ean13(p_doc, p_digits, p_x, p_y, p_height, p_module_w, p_show_text, p_unit)` | EAN-13; check digit computed (12 digits) or validated (13). Width = 113 × module. |

### `rad_pdf_chart` package - vector charts (v1.7.0)

| Subprogram | Description |
|---|---|
| `bar_chart(...)` / `line_chart(...)` / `pie_chart(...)` | Same signatures as the facade shortcuts. See [Charts](#charts). |
| `no_labels()` / `no_colors()` | Empty-collection defaults (used in the parameter defaults; rarely called directly). |

### Error codes (`rad_pdf_types` constants)

| Constant | Code | When raised |
|---|---|---|
| `c_err_validation` | -20400 | Invalid arguments, bad filename/URL |
| `c_err_io` | -20500 | File or network I/O failure |
| `c_err_rendering` | -20600 | Rendering failure (e.g., bad stream) |
| `c_err_font` | -20700 | Font load or encoding error |
| `c_err_image` | -20710 | Image load or format error |
| `c_err_layout` | -20750 | Layout engine error |
| `c_err_handle` | -20760 | Invalid document handle |
| `c_err_barcode` | -20820 | QR/barcode encoding error (NULL value, size <= 0, capacity exceeded) |

**Template engine error codes** (`rad_pdf_template`):

| Constant | Code | When raised |
|---|---|---|
| `c_err_template` | -20810 | Unclosed tag, unclosed `<if>`, malformed template |
| - | -20811 | Unknown block tag (when `strict_tags = TRUE`) |
| `c_err_table_attr` | -20813 | `<table>` missing required attribute (`columns` or `query`) |
| `c_err_table_cols` | -20814 | `<table>` column set not registered |
| `c_err_table_qry` | -20815 | `<table>` query execution blocked (missing tag or options flag) |
| `c_err_img_id` | -20816 | `<img>` missing required `id` attribute |
| `c_err_attr_val` | -20817 | Invalid attribute value (e.g. non-numeric height) |

---

## Known Limitations

1. **CLOB paragraphs > 32767 chars** are silently truncated by `DBMS_LOB.SUBSTR`.  
   For very long bodies, split the text into multiple `rad_pdf.write` calls.

2. **Streaming table mode** (`t_table_def.streaming = TRUE`) cannot supply `#PAGE_COUNT#`
   in header/footer procs during the measure pass (page count is unknown).  
   Use the default non-streaming mode for accurate page-count tokens.

3. **Standard fonts** (Helvetica, Times, Courier) are not embedded - the viewer must have them.  
   For full portability, embed a TTF font via `rad_pdf_fonts.load_ttf(..., p_embed => TRUE)`.

4. **GIF animation** - only the first frame is used.

5. **PNG**: interlaced (Adam7) files and 16-bit-per-channel files with alpha
   are rejected with a clear error - re-save as non-interlaced / 8-bit.
   8-bit alpha (RGBA and grey+alpha) is fully supported: the alpha channel
   becomes a PDF SMask (v1.6.0).

5. **Right-to-left text** (Arabic, Hebrew) is not supported; glyphs are placed left-to-right.

---

## Examples Index

### Canvas API examples (standalone PL/SQL)

| File | Description |
|---|---|
| [sample01.sql](sample01.sql) | Minimal: `new_document` → `write` → `finalize` |
| [sample02.sql](sample02.sql) | Styled report: headings, body text, spacer, `h_rule`, custom style |
| [sample03.sql](sample03.sql) | Canvas-only: text, lines, rectangles, polygon at absolute positions |
| [sample04.sql](sample04.sql) | Table report: `query2table` with column defs and custom color scheme |
| [sample05.sql](sample05.sql) | Full report: page template (header/footer), metadata, table, `save` |
| [sample06.sql](sample06.sql) | Grouped report: `refcursor2table` with `break_field` (group separators) |
| [sample07.sql](sample07.sql) | Label sheet: `query2labels` with `t_label_def` (peel-off label grid) |
| [sample08.sql](sample08.sql) | Wide table in landscape orientation (`set_page_orientation`) |
| [sample09.sql](sample09.sql) | Image embedding: load from directory / BLOB / HTTPS URL |
| [sample10.sql](sample10.sql) | Table with `wrap = TRUE`: multi-line cell text, dynamic row height |
| [sample13.sql](sample13.sql) | Text watermark: "DRAFT" diagonal on an EMP table report |
| [sample14.sql](sample14.sql) | Image watermark: logo centred on every page, 25% opacity |
| [sample15.sql](sample15.sql) | Line dash patterns: dashed borders, asymmetric patterns, reset to solid |
| [sample16.sql](sample16.sql) | Justified text: `write_wrapped` with `'J'` alignment, multi-paragraph layout |
| [sample17.sql](sample17.sql) | QR codes: payment link, UTF-8 vCard, coloured QR with EC level H |
| [sample18.sql](sample18.sql) | 1D barcodes: Code 128, EAN-13, Code 39 product labels |
| [sample19.sql](sample19.sql) | Bookmarks: navigable outline from headings + manual anchors |
| [sample20.sql](sample20.sql) | Native charts: bar, line and pie on a dashboard page |
| [sample21.sql](sample21.sql) | PDF/A-2b: archival-grade conformant document with embedded font |

### Template engine examples (standalone PL/SQL)

For APEX-specific template examples see [apex/README.md](apex/README.md).

| File | Description |
|---|---|
| [template_sample01.sql](template_sample01.sql) | Basic structure: h1–h6, p, spacer, hr, pagebreak - no binds |
| [template_sample02.sql](template_sample02.sql) | Bind substitution, inline markup, conditional blocks - EMP data |
| [template_sample03.sql](template_sample03.sql) | Lists (`<ul>`, `<ol>`), inline colour and font size |
| [template_sample04.sql](template_sample04.sql) | Data table: `register_columns` + `<table>` tag with query |
| [template_sample05.sql](template_sample05.sql) | Multi-section document: one `render()` call per department |
| [sample11.sql](sample11.sql) | Template engine: department salary report with `<table>` and CLOB build |
| [sample12.sql](sample12.sql) | DB-driven templates: load and render CLOB templates stored in a table |

### Oracle APEX examples

See **[apex/README.md](apex/README.md)** for APEX-specific installation, streaming, and page-item patterns.

**Canvas API:**

| File | Description |
|---|---|
| [apex/apex_sample00.sql](apex/apex_sample00.sql) | Letterhead: logo, company info, page header/footer on every page |
| [apex/apex_sample01.sql](apex/apex_sample01.sql) | Minimal page process: generate PDF and stream to browser |
| [apex/apex_sample02.sql](apex/apex_sample02.sql) | Filtered report using APEX page items as bind variables |
| [apex/apex_sample03.sql](apex/apex_sample03.sql) | Multi-section report: department summary + employee detail tables |
| [apex/apex_sample04.sql](apex/apex_sample04.sql) | Full report with dynamic header, footer, and `V()` session info |
| [apex/apex_sample05.sql](apex/apex_sample05.sql) | Cover page on page 1, header/footer from page 2, `get_info` |
| [apex/apex_sample06.sql](apex/apex_sample06.sql) | Table with `wrap = TRUE`: multi-line cells, dynamic row height |
| [apex/apex_sample07.sql](apex/apex_sample07.sql) | Template engine quick-start: bind substitution, tags, data table |
| [apex/apex_sample09.sql](apex/apex_sample09.sql) | Conditional text watermark driven by page item P1_IS_DRAFT |
| [apex/apex_sample10.sql](apex/apex_sample10.sql) | Image watermark loaded from application static files with graceful fallback |
| [apex/apex_sample11.sql](apex/apex_sample11.sql) | Line dash patterns: dashed rules and decorative borders on reports |
| [apex/apex_sample12.sql](apex/apex_sample12.sql) | Justified paragraph text using `write_wrapped` with `'J'` alignment |
| [apex/apex_sample13.sql](apex/apex_sample13.sql) | Payment QR code driven by page items (demo app page 3) |
| [apex/apex_sample14.sql](apex/apex_sample14.sql) | 1D barcode label sheet from a query (demo app page 4) |

**Template engine (progressive curriculum - start at 01, work through to 14):**

| File | Feature introduced |
|---|---|
| [apex/apex_template_01.sql](apex/apex_template_01.sql) | Document structure: h1–h6, p, spacer, hr |
| [apex/apex_template_02.sql](apex/apex_template_02.sql) | Bind substitution with `#KEY#` tokens |
| [apex/apex_template_03.sql](apex/apex_template_03.sql) | Inline markup: `<b>`, `<i>`, raw binds |
| [apex/apex_template_04.sql](apex/apex_template_04.sql) | Inline colour and font size |
| [apex/apex_template_05.sql](apex/apex_template_05.sql) | Line breaks with `<br/>` |
| [apex/apex_template_06.sql](apex/apex_template_06.sql) | Conditional blocks `<if bind="…">` |
| [apex/apex_template_07.sql](apex/apex_template_07.sql) | Lists: `<ul>`, `<ol>`, `<li>` |
| [apex/apex_template_08.sql](apex/apex_template_08.sql) | Data table: `<table columns="…" query="…">` |
| [apex/apex_template_09.sql](apex/apex_template_09.sql) | Page break: two-page report |
| [apex/apex_template_10.sql](apex/apex_template_10.sql) | Inline markup inside h1–h6 headings |
| [apex/apex_template_11.sql](apex/apex_template_11.sql) | Multiple `render()` calls - one per department |
| [apex/apex_template_12.sql](apex/apex_template_12.sql) | Custom default font via `t_template_options` |
| [apex/apex_template_13.sql](apex/apex_template_13.sql) | DB-driven templates loaded from a table |
| [apex/apex_template_14.sql](apex/apex_template_14.sql) | Complete department report - all features combined |

