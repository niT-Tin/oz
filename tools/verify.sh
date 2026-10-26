#!/usr/bin/env bash
# Deterministic verification entry point for oz.
#
#   tools/verify.sh
#
# Runs, in order, and records each exit code independently:
#   1. git diff --check                       (whitespace / conflict markers)
#   2. zig build test --summary all           (L1 unit + L2 render snapshots)
#   3. zig build e2e --summary all            (L3 pty end-to-end)
#
# Full stdout+stderr for every command is kept under .verify/, and a
# machine-readable .verify/verify.json is written even when a command fails.
# The script never edits source or tests. Exit status is 0 only when all
# three commands succeed. `.verify/` is ignored by git.
#
# Cache directories are overridable from the environment, but default to
# in-tree paths so a local run does not depend on $HOME being writable:
#   ZIG_GLOBAL_CACHE_DIR  .zig-global-cache-verify
#   ZIG_LOCAL_CACHE_DIR   .zig-cache-verify
set -u
set -o pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || {
    echo "verify: cannot resolve the repository root" >&2
    exit 2
}
cd "$root" || {
    echo "verify: cannot cd to $root" >&2
    exit 2
}

: "${ZIG_GLOBAL_CACHE_DIR:=$root/.zig-global-cache-verify}"
: "${ZIG_LOCAL_CACHE_DIR:=$root/.zig-cache-verify}"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR

verify_dir="$root/.verify"
mkdir -p "$verify_dir" || {
    echo "verify: cannot create $verify_dir" >&2
    exit 2
}

now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

sha256_of() {
    sha256sum "$1" | cut -d' ' -f1
}

parse_passed() {
    # `zig build test --summary all` prints a build-summary line such as
    #   +- run test 343 pass (343 total) 1s
    # (the child test runner's "All N tests passed." line is swallowed on
    # success). Accept either form so running a test binary directly also
    # works.
    local n
    n=$(sed -n 's/^All \([0-9][0-9]*\) tests passed\.$/\1/p' "$1" | tail -n 1)
    if [ -z "$n" ]; then
        n=$(sed -n 's/.*run test \([0-9][0-9]*\) pass.*(\([0-9][0-9]*\) total).*/\1/p' "$1" | tail -n 1)
    fi
    printf '%s' "$n"
}

parse_failed() {
    # Failure summary is either the build summary's "N pass, M fail" or the
    # test runner's "N passed; M skipped; K failed.".
    local n
    n=$(sed -n 's/.*run test .* \([0-9][0-9]*\) fail.*/\1/p' "$1" | tail -n 1)
    if [ -z "$n" ]; then
        n=$(sed -n 's/^[0-9][0-9]* passed;.* \([0-9][0-9]*\) failed\.$/\1/p' "$1" | tail -n 1)
    fi
    printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# git state
# ---------------------------------------------------------------------------
git_commit=$(git rev-parse --verify HEAD 2>/dev/null || true)
[ -n "${git_commit:-}" ] || git_commit="unknown"
dirty=false
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    dirty=true
fi

# ---------------------------------------------------------------------------
# run every command, even after a failure
# ---------------------------------------------------------------------------
diff_code=0
unit_code=0
e2e_code=0
diff_start=$(now); diff_end=$diff_start
unit_start=$(now); unit_end=$unit_start
e2e_start=$(now); e2e_end=$e2e_start
diff_sha=""; unit_sha=""; e2e_sha=""

diff_start=$(now)
git diff --check >"$verify_dir/diff-check.log" 2>&1
diff_code=$?
diff_end=$(now)
diff_sha=$(sha256_of "$verify_dir/diff-check.log")

unit_start=$(now)
zig build test --summary all >"$verify_dir/unit.log" 2>&1
unit_code=$?
unit_end=$(now)
unit_sha=$(sha256_of "$verify_dir/unit.log")

e2e_start=$(now)
zig build e2e --summary all >"$verify_dir/e2e.log" 2>&1
e2e_code=$?
e2e_end=$(now)
e2e_sha=$(sha256_of "$verify_dir/e2e.log")

unit_passed=$(parse_passed "$verify_dir/unit.log")
unit_failed=$(parse_failed "$verify_dir/unit.log")
e2e_passed=$(parse_passed "$verify_dir/e2e.log")
e2e_failed=$(parse_failed "$verify_dir/e2e.log")
[ -n "${unit_passed:-}" ] || unit_passed=null
[ -n "${unit_failed:-}" ] || unit_failed=null
[ -n "${e2e_passed:-}" ] || e2e_passed=null
[ -n "${e2e_failed:-}" ] || e2e_failed=null
# A successful Zig test summary ("N pass (N total)") implies zero failures
# even though it does not print a failure count. Record that inference
# explicitly rather than leaving a confusing null.
if [ "$unit_passed" != null ] && [ "$unit_failed" = null ]; then unit_failed=0; fi
if [ "$e2e_passed" != null ] && [ "$e2e_failed" = null ]; then e2e_failed=0; fi

# A failed CI run is otherwise just a count in the job summary; print the
# captured runner's failure lines (and the tail) so the job log identifies
# the failing test without downloading the artifact.
if [ "$unit_code" -ne 0 ]; then
    echo "=== unit failure log ==="
    grep -E "^error:|failed|FAIL|panic|expected" "$verify_dir/unit.log" | tail -n 40 || true
    tail -n 80 "$verify_dir/unit.log" || true
fi
if [ "$e2e_code" -ne 0 ]; then
    echo "=== e2e failure log ==="
    grep -E "^error:|failed|FAIL|panic|expected" "$verify_dir/e2e.log" | tail -n 40 || true
    tail -n 120 "$verify_dir/e2e.log" || true
fi


overall=passed
if [ "$diff_code" -ne 0 ] || [ "$unit_code" -ne 0 ] || [ "$e2e_code" -ne 0 ]; then
    overall=failed
fi
generated_at=$(now)
zig_version=$(zig version 2>/dev/null || true)
[ -n "${zig_version:-}" ] || zig_version=unknown

cat >"$verify_dir/verify.json" <<EOF
{
  "schema_version": 1,
  "generated_at": "$generated_at",
  "git": {
    "commit": "$git_commit",
    "dirty": $dirty
  },
  "environment": {
    "zig_version": "$zig_version",
    "zig_global_cache_dir": "$ZIG_GLOBAL_CACHE_DIR",
    "zig_local_cache_dir": "$ZIG_LOCAL_CACHE_DIR"
  },
  "status": "$overall",
  "commands": [
    {
      "name": "diff-check",
      "command": "git diff --check",
      "started_at": "$diff_start",
      "finished_at": "$diff_end",
      "exit_code": $diff_code,
      "log": ".verify/diff-check.log",
      "log_sha256": "$diff_sha"
    },
    {
      "name": "unit",
      "command": "zig build test --summary all",
      "started_at": "$unit_start",
      "finished_at": "$unit_end",
      "exit_code": $unit_code,
      "log": ".verify/unit.log",
      "log_sha256": "$unit_sha"
    },
    {
      "name": "e2e",
      "command": "zig build e2e --summary all",
      "started_at": "$e2e_start",
      "finished_at": "$e2e_end",
      "exit_code": $e2e_code,
      "log": ".verify/e2e.log",
      "log_sha256": "$e2e_sha"
    }
  ],
  "tests": {
    "unit": { "passed": $unit_passed, "failed": $unit_failed },
    "e2e": { "passed": $e2e_passed, "failed": $e2e_failed }
  }
}
EOF

# ---------------------------------------------------------------------------
# concise summary
# ---------------------------------------------------------------------------
echo
if [ "$overall" = passed ]; then
    echo "verify: PASS"
else
    echo "verify: FAIL"
fi
printf '  %-12s exit %-3s %s\n' "diff-check" "$diff_code" ".verify/diff-check.log"
unit_count=""
[ "$unit_passed" = null ] || unit_count=" ($unit_passed passed)"
printf '  %-12s exit %-3s %s%s\n' "unit" "$unit_code" ".verify/unit.log" "$unit_count"
e2e_count=""
[ "$e2e_passed" = null ] || e2e_count=" ($e2e_passed passed)"
printf '  %-12s exit %-3s %s%s\n' "e2e" "$e2e_code" ".verify/e2e.log" "$e2e_count"
echo "  json         $verify_dir/verify.json"

if [ "$overall" = passed ]; then
    exit 0
fi
exit 1
