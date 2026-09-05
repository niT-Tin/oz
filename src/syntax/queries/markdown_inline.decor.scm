; oz markdown_inline decorations (M4) — conceal the markup chrome when the
; cursor is elsewhere: emphasis/strong `**`/`__`/`*`/`_` delimiters, code
; span backticks, and the `[text](destination "title")` link skeleton
; (the visible link text keeps its @text.reference color).

[
  (emphasis_delimiter)
  (code_span_delimiter)
] @md.conceal

(inline_link
  [
    "["
    "]"
    "("
    ")"
  ] @md.conceal)

(inline_link
  (link_destination) @md.conceal)

(inline_link
  (link_title) @md.conceal)

(image
  [
    "!"
    "["
    "]"
    "("
    ")"
  ] @md.conceal)

(image
  (link_destination) @md.conceal)

(image
  (link_title) @md.conceal)
