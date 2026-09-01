#!/bin/bash
# Guard: verify the agent is operating in the correct worktree.
# Usage: bash /home/leoz/sources/oz/.guard.sh <worktree-name>
#   a -> .wt-a / perf/a-piece    b -> .wt-b / perf/b-render
#   c -> .wt-c / perf/c-motion   d -> .wt-d / perf/d-syntax
#   e -> .wt-e / perf/e-startup
# Prints GUARD-OK and writes a marker on success; GUARD-FAIL otherwise.
set -u
WT=".wt-$1"
case "$1" in
  a) EXPECT_BRANCH="perf/a-piece" ;;
  b) EXPECT_BRANCH="perf/b-render" ;;
  c) EXPECT_BRANCH="perf/c-motion" ;;
  d) EXPECT_BRANCH="perf/d-syntax" ;;
  e) EXPECT_BRANCH="perf/e-startup" ;;
  *) echo "GUARD-FAIL: unknown worktree name $1"; exit 1 ;;
esac
MARKER="/home/leoz/sources/oz/$WT/.guard-marker-$1"

if [ ! -d "/home/leoz/sources/oz/$WT" ]; then
  echo "GUARD-FAIL: $WT does not exist"
  exit 1
fi
cd "/home/leoz/sources/oz/$WT" || { echo "GUARD-FAIL: cannot cd"; exit 1; }
PWD_NOW="$(pwd)"
BRANCH="$(git branch --show-current)"
if [ "$PWD_NOW" = "/home/leoz/sources/oz/$WT" ] && [ "$BRANCH" = "$EXPECT_BRANCH" ]; then
  echo "guard-ok $1 $(date +%s)" > "$MARKER"
  echo "GUARD-OK: cwd=$PWD_NOW branch=$BRANCH"
else
  echo "GUARD-FAIL: cwd=$PWD_NOW branch=$BRANCH (expected $EXPECT_BRANCH)"
  exit 1
fi
