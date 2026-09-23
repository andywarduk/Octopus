#!/bin/bash
# Runs --selftest and compares its output with SelfTest.expected, failing on any difference.
#
#   ./selftest.sh            # check (builds first if there is no build)
#   ./selftest.sh --update   # accept the current output, after reading the diff
#
# --selftest only prints, so on its own it can't fail: a regression showed only to someone who
# read every line. The expected output is committed, and a change to it is a change to review.
set -euo pipefail
cd "$(dirname "$0")"

BIN="build/OctopusMenuBar.app/Contents/MacOS/OctopusMenuBar"
[ -x "$BIN" ] || ./build.sh

if [ "${1:-}" = "--update" ]; then
  "$BIN" --selftest > SelfTest.expected
  echo "Updated SelfTest.expected"
  exit 0
fi

ACTUAL="$(mktemp "${TMPDIR:-/tmp}/selftest.XXXXXX")"
trap 'rm -f "$ACTUAL"' EXIT
"$BIN" --selftest > "$ACTUAL"
if diff -u SelfTest.expected "$ACTUAL"; then
  echo "selftest: output matches SelfTest.expected"
else
  echo "selftest: output differs from SelfTest.expected (above). If the change is intended, run ./selftest.sh --update" >&2
  exit 1
fi
