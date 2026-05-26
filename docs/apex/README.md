# RAD_PDF - Oracle APEX Integration Guide

This guide explains how to use RAD_PDF inside Oracle APEX to generate and deliver
PDF documents from page processes, dynamic actions, or PL/SQL regions.

---

## Installation for APEX

RAD_PDF must be installed in a schema that is accessible from your APEX workspace.

### Option A - Install in the workspace schema (simplest)

Connect to the same schema your APEX workspace parses as and run the installer:

```sql
-- In SQL Workshop → SQL Scripts, or SQL*Plus connected as the workspace schema:
@src/install.sql
```

The packages are now available directly.

### Option B - Install in a shared utility schema

If you want one RAD_PDF installation shared by multiple workspaces:

1. Install RAD_PDF in the utility schema (e.g. `RAD_UTILS`):

   ```sql
   -- connected as RAD_UTILS:
   @src/install.sql
   ```

2. Grant EXECUTE on all eight packages to each workspace schema (or to PUBLIC):

   ```sql
   -- connected as RAD_UTILS:
   GRANT EXECUTE ON rad_pdf_types   TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_units   TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_codec   TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_styles  TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_ctx     TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_serial  TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_fonts   TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_images  TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_canvas   TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_layout   TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_table    TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf          TO <workspace_schema>;
   GRANT EXECUTE ON rad_pdf_template TO <workspace_schema>;  -- Phase 9 template engine
   ```

3. In the workspace schema, create public synonyms if you do not want to prefix
   every call with `RAD_UTILS.`:

   ```sql
   -- connected as <workspace_schema>:
   CREATE OR REPLACE SYNONYM rad_pdf_types  FOR rad_utils.rad_pdf_types;
   CREATE OR REPLACE SYNONYM rad_pdf_styles FOR rad_utils.rad_pdf_styles;
   CREATE OR REPLACE SYNONYM rad_pdf_table  FOR rad_utils.rad_pdf_table;
   CREATE OR REPLACE SYNONYM rad_pdf        FOR rad_utils.rad_pdf;
   -- ... repeat for any packages you call directly
   ```

---

## Streaming a PDF to the browser

To make APEX deliver the PDF as a file download instead of rendering an HTML page,
use this pattern inside an **Execute Server-side Code** page process:

```sql
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Hello from APEX');
  l_pdf := rad_pdf.finalize(l_doc);

  -- Stream the BLOB as a PDF download
  owa_util.mime_header('application/pdf', FALSE);
  htp.p('Content-Length: ' || DBMS_LOB.getlength(l_pdf));
  htp.p('Content-Disposition: attachment; filename="report.pdf"');
  htp.p('Cache-Control: no-store, no-cache, must-revalidate');
  htp.p('Pragma: no-cache');
  owa_util.http_header_close;
  wpg_docload.download_file(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);

  -- Stop APEX from rendering the rest of the page
  apex_application.stop_apex_engine;
END;
```

**Key points:**

- `owa_util.mime_header` must be called *before* `http_header_close` and before
  any page output has been sent.  Place the process early in the processing order.
- `apex_application.stop_apex_engine` raises an exception that APEX catches and
  uses to halt normal page rendering.  Always call it as the last statement.
- `Content-Disposition: attachment` forces a Save As dialog.  Omit it to let the
  browser decide (inline view or download) based on the user's PDF viewer settings.

---

## Using APEX page items as bind variables

Use `rad_pdf_table.refcursor2table` instead of `rad_pdf.query2table` when the query
depends on APEX session state.  Open the cursor using APEX's `:PXXX_ITEM` bind
variable syntax:

```sql
OPEN l_rc FOR
  SELECT order_id, product_name, qty, unit_price
  FROM   order_lines
  WHERE  order_id = :P5_ORDER_ID;   -- APEX page item as bind variable

rad_pdf_table.refcursor2table(l_doc, l_rc, l_cols);
```

Never concatenate APEX item values directly into a query string - that is a
SQL injection vulnerability.  Always use the bind variable syntax.

You can also call `V('P5_ORDER_ID')` (returns VARCHAR2) or `NV('P5_ORDER_ID')`
(returns NUMBER) inside the PL/SQL block to use item values in PL/SQL logic.

---

## Storing generated PDFs in a table

For large PDFs, or when the same PDF is downloaded multiple times, generate the
BLOB once and store it in a table rather than re-generating on every request:

```sql
-- Table to hold generated PDFs
CREATE TABLE generated_pdfs (
  id           NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  created_at   DATE           DEFAULT SYSDATE NOT NULL,
  filename     VARCHAR2(200)  NOT NULL,
  pdf_data     BLOB
);
```

An APEX process (or a background job) inserts the row; a separate download
page process reads and streams it.

---

---

## Cover page with header/footer from page 2

A common requirement is a custom cover page on page 1 (full-bleed image, title,
no header/footer) and a standard header on every subsequent page.

RAD_PDF supports this with a single `IF #PAGE_NR# > 1` guard inside
`header_proc` and `footer_proc`. Both blocks execute for every page at
finalization time, but the guard makes them a no-op on page 1.

```sql
l_tpl.header_proc :=
  'BEGIN
     IF #PAGE_NR# > 1 THEN
       rad_pdf_canvas.write_text(#DOC_HANDLE#, ''My Header'', 42, 820, ''pt'');
       rad_pdf_canvas.h_line   (#DOC_HANDLE#, 42, 778, 511, 0.5, ''1A3A5C'', ''pt'');
     END IF;
   END;';
```

After placing cover content, call `rad_pdf.new_page(l_doc)` to start page 2
where header and footer will appear.

Important: `header_proc` is executed via `EXECUTE IMMEDIATE` at `finalize` time,
so PL/SQL locals from the outer block are out of scope. Capture any runtime
values (APEX session items, image IDs, dates) into local variables first and
embed them as literals in the proc string before passing it to `set_template`.

See [apex_sample05.sql](apex_sample05.sql) for a complete working example.

---

## Reading the current page number

To read the current page number at any point during document generation:

```sql
l_page := rad_pdf.get_info(l_doc, rad_pdf_types.c_info_page_nr);
```

Available `c_info_*` constants (all return values in points unless noted):

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

---

## Examples

### Canvas API examples

| File | Description |
|---|---|
| [apex_sample00.sql](apex_sample00.sql) | Letterhead template: logo, company info, page header/footer on every page |
| [apex_sample01.sql](apex_sample01.sql) | Minimal page process: generate PDF and stream to browser |
| [apex_sample02.sql](apex_sample02.sql) | Filtered report using APEX page items as bind variables |
| [apex_sample03.sql](apex_sample03.sql) | Multi-section report: department summary + employee detail tables |
| [apex_sample04.sql](apex_sample04.sql) | Full report with dynamic header, footer, and V() session info |
| [apex_sample05.sql](apex_sample05.sql) | Cover page on page 1, header/footer from page 2, get_info usage |
| [apex_sample06.sql](apex_sample06.sql) | Table with `wrap = TRUE`: multi-line cell text, dynamic row height |
| [apex_sample07.sql](apex_sample07.sql) | Template engine quick-start: bind substitution, block tags, table tag |

---

## Template engine

The template engine (`rad_pdf_template`) lets you describe a PDF document as an
XML-like CLOB string - no per-primitive canvas calls required.  It is the
recommended approach for new reports.

**Full reference and patterns:** [TEMPLATE_GUIDE.md](../TEMPLATE_GUIDE.md)

### Template engine examples (progressive, EMP/DEPT)

The examples below build incrementally - each file introduces one new feature.
Start from `apex_template_01.sql` and work through to `apex_template_14.sql`.

| File | Feature introduced | APEX page items |
|---|---|---|
| [apex_template_01.sql](apex_template_01.sql) | Document structure: h1–h6, p, spacer, hr | none |
| [apex_template_02.sql](apex_template_02.sql) | Bind substitution with `#KEY#` tokens | `P1_EMPNO` |
| [apex_template_03.sql](apex_template_03.sql) | Inline markup: `<b>`, `<i>`, raw binds | `P1_DEPTNO` |
| [apex_template_04.sql](apex_template_04.sql) | Inline colour and font size | `P1_DEPTNO` |
| [apex_template_05.sql](apex_template_05.sql) | Line breaks with `<br/>` | `P1_EMPNO` |
| [apex_template_06.sql](apex_template_06.sql) | Conditional blocks `<if bind="…">` | `P1_EMPNO`, `P1_SHOW_SALARY`, `P1_NOTES` |
| [apex_template_07.sql](apex_template_07.sql) | Lists: `<ul>`, `<ol>`, `<li>` with inline markup | `P1_DEPTNO` |
| [apex_template_08.sql](apex_template_08.sql) | Data table with `<table columns="…" query="…">` | `P1_DEPTNO` |
| [apex_template_09.sql](apex_template_09.sql) | Page break - two-page report | `P1_DEPTNO` |
| [apex_template_10.sql](apex_template_10.sql) | Inline markup inside headings h1–h6 | `P1_DEPTNO` |
| [apex_template_11.sql](apex_template_11.sql) | Multiple `render()` calls - one per department | none |
| [apex_template_12.sql](apex_template_12.sql) | Custom default font via `t_template_options` | `P1_DEPTNO`, `P1_FONT_SIZE`, `P1_FONT_STYLE` |
| [apex_template_13.sql](apex_template_13.sql) | DB-driven templates loaded from a table | `P1_DEPTNO`, `P1_TEMPLATE_NAME` |
| [apex_template_14.sql](apex_template_14.sql) | Complete department report - all features combined | `P1_DEPTNO`, `P1_NOTES`, `P1_SHOW_COMMS` |
