#!/bin/zsh
# Builds the debug binary and runs `Conch --smoke-test` against throwaway state. Prints each check, exits with its code.
set -euo pipefail

cd "${0:A:h}/.."
swift build
BIN="$(swift build --show-bin-path)/Conch"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/conch-smoke.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
RESULT="$WORK/result.json"

set +e
CONCH_STATE_PATH="$WORK/state.json" "$BIN" --smoke-test "$RESULT"
CODE=$?
set -e

if [[ -f "$RESULT" ]]; then
  /usr/bin/python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))
for c in r["checks"]:
    print(("PASS " if c["ok"] else "FAIL ") + c["name"] + (": " + c["detail"] if c.get("detail") else ""))
print("passed" if r["passed"] else "failed")
' "$RESULT"
else
  echo "No result file written"
fi
case $CODE in
  0) ;;
  2) echo "Timed out after 30 s" >&2 ;;
  *) echo "Exit code $CODE" >&2 ;;
esac
exit $CODE
