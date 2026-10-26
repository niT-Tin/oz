; oz markdown decorations (M4) — consumed by decorInRange in syntax.zig;
; these captures never become highlight spans (captureStyle folds "@md.*"
; to .default).

; heading band + level (counted from the marker text in Zig)
(atx_heading) @md.heading

; the "#"…"######" markers conceal (with the one following space)
[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
] @md.heading_marker

; fence band, delimiter lines and optional language/info string
(fenced_code_block) @md.fence
(fenced_code_block_delimiter) @md.fence_delimiter
(info_string) @md.fence_info

; pipe tables are laid out as a block, not as independent source rows
(pipe_table) @md.table
(pipe_table_delimiter_row) @md.table_delimiter
(pipe_table_cell) @md.table_cell
(pipe_table_delimiter_cell) @md.table_align

; task list checkboxes → Nerd Font icons
(task_list_marker_checked) @md.checkbox_on
(task_list_marker_unchecked) @md.checkbox_off
