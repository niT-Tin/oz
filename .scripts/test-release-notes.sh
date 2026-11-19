#!/usr/bin/env bash
set -euo pipefail

release_script_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
release_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/oz-release-notes.XXXXXX")
trap 'rm -rf "$release_test_dir"' EXIT
mkdir -p "$release_test_dir/.scripts"
cp "$release_script_root/extract-release-notes.sh" "$release_test_dir/.scripts/"
release_extract="$release_test_dir/.scripts/extract-release-notes.sh"

cat > "$release_test_dir/CHANGELOG.md" <<'EOF'
# Changelog

## [0.5.0-rc.1] - 2026-12-01

预发布正文。

## [0.4.1.1] - 2026-11-19

后续修订。

## [0.4.0] - 2026-11-16

### 新增

- 可直接阅读的中文说明与 `K` 文档。

[完整对比](https://example.com/compare)

## [0.3.0] - 2026-10-24

旧版本正文。
EOF
cat > "$release_test_dir/expected" <<'EOF'
### 新增

- 可直接阅读的中文说明与 `K` 文档。

[完整对比](https://example.com/compare)
EOF

# Run from another cwd: extraction must use the script's repository root.
(cd "$release_test_dir/.scripts" && bash "$release_extract" v0.4.0) > "$release_test_dir/actual"
diff -u "$release_test_dir/expected" "$release_test_dir/actual"
[[ $(bash "$release_extract" v0.5.0-rc.1) == '预发布正文。' ]]
[[ $(bash "$release_extract" v0.4.1.1) == '后续修订。' ]]
[[ $(bash "$release_extract" v0.3.0) == '旧版本正文。' ]]

for release_bad_tag in v9.9.9 0.4.0 'v0.4.0;echo bad' $'v0.4.0\nv0.3.0'; do
  if bash "$release_extract" "$release_bad_tag" > "$release_test_dir/out" 2> "$release_test_dir/err"; then
    printf 'unexpected success for %q\n' "$release_bad_tag" >&2
    exit 1
  fi
  [[ ! -s "$release_test_dir/out" && -s "$release_test_dir/err" ]]
done
if bash "$release_extract" > "$release_test_dir/out" 2> "$release_test_dir/err"; then
  exit 1
fi

printf '## [0.4.0] - 2026-11-16\n\n  \n## [0.3.0] - 2026-10-24\nold\n' > "$release_test_dir/CHANGELOG.md"
if bash "$release_extract" v0.4.0 > "$release_test_dir/out" 2> "$release_test_dir/err"; then
  exit 1
fi
[[ ! -s "$release_test_dir/out" && -s "$release_test_dir/err" ]]

for ((release_line=0; release_line<2048; release_line++)); do
  printf -- '- Large release body line %04d: keep the entire entry and Unicode 文档.\n' "$release_line"
done > "$release_test_dir/large-body"
{
  printf '## [0.4.0] - 2026-11-16\n\n'
  cat "$release_test_dir/large-body"
} > "$release_test_dir/CHANGELOG.md"
bash "$release_extract" v0.4.0 > "$release_test_dir/actual"
diff -u "$release_test_dir/large-body" "$release_test_dir/actual"

printf 'release notes: version boundaries, Unicode, cwd, prereleases, large bodies and failure cases passed\n'
