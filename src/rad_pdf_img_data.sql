-- rad_pdf_img_data.sql — schema-level object type for decoded image data.
-- Must be compiled BEFORE all pdf_* packages.
-- No TYPE BODY needed: Oracle auto-generates the positional constructor.
CREATE OR REPLACE TYPE rad_pdf_img_data FORCE AS OBJECT (
  img_type   VARCHAR2(4),   -- 'JPG', 'PNG', 'GIF'
  width      NUMBER,
  height     NUMBER,
  color_res  NUMBER,        -- bits per colour component
  nr_colors  NUMBER,        -- number of colour channels
  greyscale  NUMBER(1),     -- 1 = greyscale, 0 = colour  (BOOLEAN not valid in SQL types)
  transp_idx NUMBER,        -- transparent palette index (-1 = absent; NULL = no palette)
  pixels     BLOB,          -- pixel data / already-compressed stream for PDF
  color_tab  RAW(768)       -- RGB palette (256 x 3 bytes); NULL for non-indexed images
);
/
