; From nvim-treesitter/nvim-treesitter (legacy text.* capture names —
; captureStyle() in syntax.zig maps them to heading/strong/… styles)
(atx_heading
  (inline) @text.title)

(setext_heading
  (paragraph) @text.title)

[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
] @punctuation.special

[
  (link_title)
  (indented_code_block)
] @text.literal

(fenced_code_block_delimiter) @punctuation.delimiter

; fence CONTENT is uncolored at the block level — the fence language's
; injected spans (markdown.injections.scm) own that range
(code_fence_content) @none

(link_destination) @text.uri

(link_label) @text.reference

[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
  (thematic_break)
] @punctuation.special

[
  (block_continuation)
  (block_quote_marker)
] @punctuation.special

(backslash_escape) @string.escape

; pipe tables (GFM): the |---| delimiter row goes dim, header cells stand
; out (their inline content still gets inline spans on top — later wins)
(pipe_table_delimiter_cell) @punctuation

(pipe_table_header
  (pipe_table_cell) @property)
