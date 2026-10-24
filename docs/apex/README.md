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

2. Grant EXECUTE on the required packages to each workspace schema:

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
   GRANT EXECUTE ON rad_pdf_swiss    TO <workspace_schema>;  -- Swiss bill/options types
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

### Watermarks

A watermark is a translucent text or image stamped across every page. RAD_PDF
applies it at `finalize` time - no per-page callback is required.

**Text watermark driven by a page item:**

```sql
-- Page item P1_IS_DRAFT: VARCHAR2(1), default 'N'
IF NVL(:P1_IS_DRAFT, 'N') = 'Y' THEN
  rad_pdf.set_watermark(
    p_doc       => l_doc,
    p_text      => 'DRAFT',
    p_font_name => 'Helvetica',
    p_font_size => 72,
    p_color     => 'C0C0C0',
    p_opacity   => 0.3,
    p_angle     => 45,
    p_layer     => 'UNDER');
END IF;
```

**Using an APEX authorization scheme instead of a page item:**

```sql
IF NOT APEX_AUTHORIZATION.IS_AUTHORIZED('REPORT_APPROVER') THEN
  rad_pdf.set_watermark(l_doc, 'RESTRICTED', p_opacity => 0.2);
END IF;
```

**Image watermark (logo) loaded from application static files:**

```sql
BEGIN
  SELECT file_content INTO l_logo_blob
  FROM   apex_application_static_files
  WHERE  application_id = :APP_ID
  AND    file_name      = 'company_logo.png';

  l_logo_id := rad_pdf_images.load_image(l_doc, l_logo_blob);
  rad_pdf.set_watermark_image(l_doc, l_logo_id,
    p_opacity   => 0.2,
    p_width_pct => 50,
    p_layer     => 'UNDER');
EXCEPTION
  WHEN NO_DATA_FOUND THEN NULL;  -- no image uploaded - proceed without watermark
END;
```

**Full parameter reference:** [docs/README.md - Watermarks](../README.md#watermarks)

| File | Description |
|---|---|
| [apex_sample09.sql](apex_sample09.sql) | Conditional text watermark driven by P1_IS_DRAFT; authorization-scheme alternative |
| [apex_sample10.sql](apex_sample10.sql) | Image watermark from application static files with graceful fallback when image is absent |
| [apex_sample11.sql](apex_sample11.sql) | Line dash patterns: dashed header/footer rules using set_line_dash in callbacks |
| [apex_sample12.sql](apex_sample12.sql) | Justified paragraph text: write_wrapped 'J' in a two-column letterhead layout |

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


## Swiss QR-bill examples

These three self-contained examples use published SIX test accounts and synthetic
invoice data. They require the full installer with `rad_pdf_swiss`, and no EMP/DEPT
tables, images, fonts or page items. They are payment-section demonstrations, not
complete Swiss tax/accounting invoice templates.

| Standalone | APEX process | Catalog value | Behaviour |
|---|---|---|---|
| [sample22.sql](../sample22.sql) | [apex_sample15.sql](apex_sample15.sql) | `SWISS_QRR` | CHF, QR-IBAN/QRR, JSON input, two invoice lines, Italian integrated payment section |
| [sample23.sql](../sample23.sql) | [apex_sample16.sql](apex_sample16.sql) | `SWISS_SCOR` | EUR, ordinary IBAN/SCOR, typed record, 72 rows, English payment page appended after all rows |
| [sample24.sql](../sample24.sql) | [apex_sample17.sql](apex_sample17.sql) | `SWISS_OPEN` | CHF, ordinary IBAN/NON, amount/debtor omitted, French handwritten fields on receipt and payment part |

### Existing demo app

The local app is `apex/pdf` (its existing deployment file uses ID 125). In cloud
workspace `RCAPANCIONI`, the live app named/aliased `PDF` is **151**, and its older
export does not yet have pages 3 and 4. The updates are therefore separate:

- The local catalog receives the three new choices and processes; its other
  examples are retained. [Local catalog patch](swiss_local_catalog.patch).
- The cloud update is built from the live export of app 151. It adds pages 3/4,
  a Swiss-only LOV and shared item, and Home/navigation links. It preserves the
  existing Home controls, page 2 examples, authentication and app settings.
  [Incremental cloud patch](swiss_app151.patch).

Both integrations use the same route:

1. Page 4, **Esempi**: choose a Swiss entry in `P4_ESEMPIO` / shared `ESEMPI_LOV`.
2. **Stampa Pdf** redirects to page 3 with application item `G_ESEMPIO`.
3. Exactly one Before Header process runs, conditioned on `G_ESEMPIO`.
4. The process validates/finalizes the PDF before sending HTTP headers, streams
   the BLOB with fixed filename and no-cache headers, then stops APEX rendering.

Page 4 displays an explanation only for the selected Swiss example. The new page
3 processes contain the same source as `apex_sample15.sql`–`apex_sample17.sql`.
The three standalone samples use identical PDF generation code, with SQLcl output
and BLOB cleanup in place of HTTP delivery.

For another app, create an **Execute Server-side Code** process at **On Load –
Before Header**, paste one APEX sample, and apply a suitable request condition.
Do not run all three unconditionally: each terminates the response with a download.
Keep the `E_STOP_APEX_ENGINE` handler before `WHEN OTHERS` so a successful download
is not treated as an error. The samples intentionally have no SQLcl `SET` commands
or trailing `/` in the APEX process source.

### Connecting your invoice service

Replace only the demonstration data with an authorized invoice/TAPI service result.
Inside Oracle prefer the typed `t_bill`; use JSON at an external service boundary.
The JSON example demonstrates the versioned contract, not arbitrary ERP JSON.
Use `rad_pdf_swiss.creditor_reference` when generating a new RF reference; validate
a stored reference rather than silently recalculating an incorrect check digit.

`INTEGRATED` reserves the lower 115 mm on **every** invoice page and paints the
payment section only on the last one. `SEPARATE` keeps the full body frame and
appends a payment page automatically. Do not add a manual page break before it.
Avoid header/footer callbacks in the lower payment area, and print at 100% size.
For open payer details leave the **whole** debtor record empty; a partial address
is rejected. A missing amount is NULL, not zero. QRR is CHF-only under IG 2.4;
EUR uses an ordinary IBAN with SCOR or NON.

See [Swiss QR-bill](../SWISS_QR_BILL.md) for the complete input contract, font
coverage rules and validation boundaries. To generate the standalone PDFs:

```sql
@docs/sample22.sql
@docs/sample23.sql
@docs/sample24.sql
```

The standalone scripts print generated sizes and free the BLOB. To retain a PDF,
store/stream the BLOB before freeing it, or replace `finalize` with `save` using an
Oracle directory you control. No directory object is required to run the examples.

### Applying the application source patches

The `apex/` tree is excluded by the repository's existing `.gitignore`; the two
patches above preserve the source changes in version control without importing
an unrelated application export into the library repository. Paths are relative
to an APEXLang **app root**, not this repository root.

Use the local patch only with the matching existing local catalog. For app 151,
first export the current cloud source, back it up, then check/apply only the cloud
patch inside that exported app directory:

```sh
patch --dry-run -p1 -i /absolute/path/docs/apex/swiss_app151.patch
patch -p1 -i /absolute/path/docs/apex/swiss_app151.patch
```

Validate with SQLcl `apex validate -input /absolute/path/to/app -workspaceid <id>`.
Import the checked source into the intended existing app ID only after review.
Do not import the complete old local ID-125 source over cloud app 151: their base
pages differ. The incremental patch preserves the cloud version's existing pages.
