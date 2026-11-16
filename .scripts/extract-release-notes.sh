#!/usr/bin/env bash
# Emit exactly one version's human-written release body; fail before publishing
# if the tag has no nonempty changelog entry.
set -euo pipefail

if [[ $# -ne 1 ]] || [[ ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  printf 'usage: %s vMAJOR.MINOR.PATCH\n' "$0" >&2
  exit 1
fi

release_tag=$1
release_version=${release_tag#v}
release_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

if ! release_notes=$(awk -v wanted="## [$release_version] - " '
  /^## \[/ {
    if (found) exit
    if (index($0, wanted) == 1) found = 1
    next
  }
  found {
    if (!started && $0 ~ /^[[:space:]]*$/) next
    started = 1
    print
  }
  END { if (!found || !started) exit 1 }
' "$release_repo_root/CHANGELOG.md"); then
  printf 'No nonempty changelog entry for %s\n' "$release_tag" >&2
  exit 1
fi

printf '%s\n' "$release_notes"
