#!/bin/sh
# Fetch the large vendored dependency that is not committed to git.
# vaxis is small and committed under vendor/vaxis; tree-sitter (with its
# ~90 grammar sources) is a ~50 MB download that expands to ~1 GB, so it is
# downloaded into vendor/ and ignored by git. Run this once after cloning
# (CI does it as a step).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dest="$root/vendor/tree-sitter"
url="https://github.com/neurocyte/tree-sitter/releases/download/master-aedd101b85db8d91ad8b900e9cc5fe096e299c6e/source.tar.gz"

if [ -f "$dest/build.zig" ]; then
    echo "vendor/tree-sitter already present"
    exit 0
fi

mkdir -p "$root/vendor"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "downloading tree-sitter source..."
curl -fL --retry 5 --retry-all-errors "$url" -o "$tmp/ts.tar.gz"
tar -xzf "$tmp/ts.tar.gz" -C "$root/vendor"
test -f "$dest/build.zig" || {
    echo "unexpected tree-sitter archive layout (expected vendor/tree-sitter/build.zig)" >&2
    exit 1
}
echo "vendor/tree-sitter ready"
