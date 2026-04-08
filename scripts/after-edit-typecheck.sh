#!/usr/bin/env bash
# after-edit-typecheck.sh — Cursor afterFileEdit hook.
#
# Module 03 computational sensor. After the agent edits a file, walk up to
# the nearest package.json, detect the package manager, and run `typecheck`
# if defined. On failure, emit a user_message JSON field to push the error
# back into the agent's context.
#
# Known Cursor 1.7 bug: user_message / agent_message hook output fields are
# ignored on Windows in some versions (see forum bug #142589). Falls back to
# stderr in those cases, which is at least logged.

set -o pipefail

TRACE_LOG=".cursor-harness/after-edit-trace.log"
mkdir -p .cursor-harness 2>/dev/null

PY=""
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
[ -z "$PY" ] && { printf '{"permission": "allow"}'; exit 0; }

PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD=$(cat)
fi

# Cursor's afterFileEdit payload shape includes file_path (and potentially
# diff metadata). Parse defensively.
FILE=$(printf '%s' "$PAYLOAD" | "$PY" -c "import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('file_path') or d.get('filePath') or (d.get('tool_input') or {}).get('file_path') or '')
except Exception:
    pass" 2>/dev/null)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] edit $FILE" >> "$TRACE_LOG" 2>/dev/null

if [ -z "$FILE" ]; then
  printf '{"permission": "allow"}'
  exit 0
fi

# Walk up to find package.json
DIR=$(dirname "$FILE")
PKG_DIR=""
while [ "$DIR" != "/" ] && [ "$DIR" != "." ] && [ -n "$DIR" ]; do
  if [ -f "$DIR/package.json" ]; then
    PKG_DIR="$DIR"
    break
  fi
  DIR=$(dirname "$DIR")
done

if [ -z "$PKG_DIR" ]; then
  printf '{"permission": "allow"}'
  exit 0
fi

# Detect package manager
PM="npm"
if   [ -f "$PKG_DIR/pnpm-lock.yaml" ]; then PM="pnpm"
elif [ -f "$PKG_DIR/yarn.lock" ];      then PM="yarn"
elif [ -f "$PKG_DIR/package-lock.json" ]; then PM="npm"
fi

cd "$PKG_DIR" || { printf '{"permission": "allow"}'; exit 0; }

HAS_TYPECHECK=$("$PY" -c "import json; d=json.load(open('package.json')); print('1' if 'typecheck' in d.get('scripts',{}) else '0')" 2>/dev/null)

if [ "$HAS_TYPECHECK" != "1" ]; then
  printf '{"permission": "allow"}'
  exit 0
fi

TC_OUTPUT=$(timeout 60 "$PM" run typecheck 2>&1)
TC_EXIT=$?

if [ "$TC_EXIT" -eq 0 ] || [ "$TC_EXIT" -eq 124 ]; then
  # Pass or timeout → don't pester the agent
  printf '{"permission": "allow"}'
  exit 0
fi

# Failure — inject warning via user_message field (Cursor's mechanism for
# pushing information into the agent's next turn). Fall back to stderr for
# Windows cases where user_message is ignored.
LAST_LINES=$(printf '%s' "$TC_OUTPUT" | tail -30)

# Escape for JSON
MSG=$("$PY" -c "import sys,json; print(json.dumps(sys.stdin.read()))" <<EOF
[cursor-harness/module-03 computational sensor] typecheck FAILED after edit to $(basename "$FILE") in $(basename "$PKG_DIR"):

$LAST_LINES

Per module 03 verification protocol, you MUST investigate and fix this before proceeding. Do not ignore this warning — it is a hard sensor signal.
EOF
)

printf '{"permission": "allow", "user_message": %s}' "$MSG"

# Also emit to stderr as belt-and-suspenders for the Windows user_message bug
{
  echo "[cursor-harness/module-03] typecheck FAILED after edit to $(basename "$FILE")"
  echo "[cursor-harness/module-03] last 30 lines:"
  printf '%s\n' "$LAST_LINES"
  echo "[cursor-harness/module-03] per module 03 protocol, fix before proceeding"
} >&2

exit 0
