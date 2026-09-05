; Injection patterns for the markdown block grammar (oz's own — the
; vendored injections.scm also covers html/yaml frontmatter, which oz
; deliberately skips).
;
; fenced code → the info_string language (child created lazily per
; language; unsupported languages are skipped):
(fenced_code_block
  (info_string
    (language) @injection.language)
  (code_fence_content) @injection.content)

; every (inline) node → markdown_inline (no @injection.language capture:
; syncInjections defaults a bare content match to "markdown_inline"):
(inline) @injection.content
