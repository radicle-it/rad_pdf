# Rendering performance refactor

Measured on 2026-10-23 using Oracle Cloud development database DB26AIFREE01,
with the same schema, SQLcl client and `tests/benchmark_rendering.sql` workloads.
Baseline: commit `9778911`; optimized version: branch `codex/pdf-performance`.
Numbers below are medians of three executions. Individual measurements are in
[rendering_20261023.csv](../tests/benchmarks/rendering_20261023.csv). CPU is server CPU from
`DBMS_UTILITY.GET_CPU_TIME`; output size is bytes. These are workload-specific
measurements, not a performance guarantee for other databases or documents.

| Workload | Previous CPU | New CPU | Speedup | Previous bytes | New bytes |
|---|---:|---:|---:|---:|---:|
| `clob_156k` | 3.77 s | 0.98 s | 3.8× | 232,875 | 17,065 |
| `mixed_200` | 0.52 s | 0.17 s | 3.1× | 82,594 | 7,043 |
| `table_5000x4` | 7.73 s | 1.65 s | 4.7× | 2,341,460 | 243,954 |
| `wrapped_1000` | 4.88 s | 0.44 s | 11.1× | 319,991 | 32,825 |
| `batch_50` | 0.13 s | 0.05 s | 2.6× | 60,291 | 58,705 |

Both runs used default options. Page compression is now enabled by default;
therefore the comparison measures the complete change, including compression.
The text rendering operators also changed, so file sizes differ even with
compression disabled. The byte sizes for `batch_50` are the sum of 50 PDFs.

## Architecture

- `rad_pdf_text` prepares typed text plans: resolved fonts, line breaks, fragment
  positions, gaps, heights and alignment. It depends on font/style primitives,
  without depending on canvas or serialization. It accepts CLOBs, existing inline
  runs and VARCHAR2 cell text; it does not own input LOBs or document state.
- `rad_pdf_layout` prepares paragraph plans and paginates their lines using the
  actual drawing cursor. Measurement and painting share the same plan. The
  previous paragraph-to-runs expansion and duplicate word-layout logic are gone.
- `rad_pdf_canvas` paints prepared fragments. Its internal painter emits cached
  font/color prefixes and explicit coordinates, without changing the public
  canvas cursor or repeatedly resolving fonts. Public drawing APIs remain.
- `rad_pdf_table` fetches each source once. It prepares alternating text styles
  per column, formats each data cell once and prepares wrapping once per row.
  Painting reuses that row's plans across page breaks. The renderer no longer
  measures the entire wrapped table before drawing it. Explicit `measure_table`
  remains available for callers that need the total height.
- `rad_pdf_fonts` caches the 256 encoded-byte metrics per simple font and static
  byte escaping. Conversion is bounded by chunks; safe printable ASCII uses a
  direct encoding path. CID glyph mapping and usage tracking are retained.
- `rad_pdf_serial` buffers document writes and computes xref offsets using the
  logical byte position, including buffered bytes. Uncompressed streams borrow
  their input; page LOBs are released after serialization. `finalize` transfers
  ownership of the finished BLOB rather than copying it. Snapshot API
  `get_doc_copy` still makes an independent copy.

Text parsing searches delimiters by spans rather than iterating over every
character. Width caching is bounded to 1,024 words per plan. Long words and
multibyte text respect the 4,000-byte fragment limit. Explicit CRLF, CR, LF and
blank lines are handled by the same compiler used for wrapping.

## Compatibility and ownership

Existing calls to `new_document(p_info, p_template)` continue to compile.
The new optional `p_compress_pages` argument defaults to `TRUE`. For readable
content streams, use:

```sql
l_doc := rad_pdf.new_document(p_compress_pages => FALSE);
```

Compression changes PDF bytes, not the extracted content. Tests that inspect
raw drawing operators explicitly disable it. `finalize` still closes the handle
and returns a caller-owned temporary BLOB; free it with
`DBMS_LOB.FREETEMPORARY`. Input LOBs and borrowed stream data remain caller-owned.

Oversized words now wrap; a single glyph that cannot fit raises a layout error.
Wrapping also respects explicit newlines. Such inputs can paginate differently
from the previous renderer, which could overflow a cell or ignore line breaks.

## Verification and scope

The complete SQL regression suite, `phase20_text_pipeline.sql`, and the
10,000-row stress suite passed on the cloud development schema: 614 assertions
in total, including 100 in the new text-pipeline suite. New tests
cover line width/height invariants, CLOB chunk boundaries, empty lines, byte
buffer limits, borrowed streams, snapshots, output ownership and compression.

Independent checks use `tests/validate_pdf.py` for xref byte offsets, exact stream
lengths and zlib checksums, plus Poppler for text extraction and bounding boxes.
The reference outputs include embedded CID Greek/euro/accent text, simple
embedded WinAnsi text, and a 78-page table/paragraph document. All 36 table rows,
the complete 48 KB paragraph and all 78 page-number footers are retained.

This remains a document-rendering library with a public facade and specialized
modules. ExpreSQL TAPI can call that facade from application services. No data
access layers, generic dispatch framework or new dependency is required.

Table source rows and paragraph plans remain in memory until document close;
this is not an unbounded streaming renderer. Peak PGA was not instrumented by
this benchmark. Numeric/date SQL conversion and locale rules remain the existing
API's responsibility. The subsequent [Swiss QR-bill module](SWISS_QR_BILL.md) uses this pipeline for
validated payment data and reserved payment sections.
