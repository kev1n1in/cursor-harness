#!/usr/bin/env bash
# after-edit-typecheck.sh — Cursor afterFileEdit hook.
#
# IMPORTANT: afterFileEdit is a NOTIFICATION hook. Per Cursor's hook
# spec, no stdout response is expected and any returned JSON would be
# ignored. That means this hook CANNOT inject typecheck errors back
# into the agent's context directly.
#
# What we do instead (module 05 observability):
#   1. Walk up from the edited file to find the nearest package.json
#   2. Run `typecheck` if defined
#   3. Append a JSONL result line to .cursor-harness/typecheck-results.jsonl
#      so you (the human) can audit post-hoc, and so the agent — if it
#      follows module 03 — can read this file during its own verification
#      protocol to cross-check its work
#
# Module 03 still requires the agent to run typecheck itself as part of
# the verification protocol. This hook is a safety net / audit log, not
# a feedback channel.

set -o pipefail

LOG_DIR=".cursor-harness"
LOG_FILE="$LOG_DIR/typecheck-results.jsonl"
TRACE_LOG="$LOG_DIR/after-edit-trace.log"
mkdir -p "$LOG_DIR" 2>/dev/null

PY=""
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
# No python → nothing to do (hook is informational, just exit)
[ -z "$PY" ] && exit 0

PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD=$(cat)
fi

# Cursor's afterFileEdit payload shape (verified from docs):
#   {
#     "conversation_id": "...",
#     "generation_id": "...",
#     "file_path": "README.md",
#     "edits": [{"old_string": "...", "new_string": "..."}],
#     "hook_event_name": "afterFileEdit",
#     "workspace_roots": ["/abs/path"]
#   }
FILE=$(printf '%s' "$PAYLOAD" | "$PY" -c "import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('file_path') or '')
except Exception:
    pass" 2>/dev/null)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] afterFileEdit file=${FILE:-<empty>}" >> "$TRACE_LOG" 2>/dev/null

if [ -z "$FILE" ]; then
  exit 0
fi

# Walk up to find package.json (try relative first, then workspace_root + relative)
DIR=$(dirname "$FILE")
PKG_DIR=""
# Try absolute walk-up first (if FILE is absolute)
CHECK_DIR="$DIR"
while [ "$CHECK_DIR" != "/" ] && [ "$CHECK_DIR" != "." ] && [ -n "$CHECK_DIR" ]; do
  if [ -f "$CHECK_DIR/package.json" ]; then
    PKG_DIR="$CHECK_DIR"
    break
  fi
  CHECK_DIR=$(dirname "$CHECK_DIR")
done

# If not found AND FILE is relative, try under workspace_roots[0]
if [ -z "$PKG_DIR" ]; then
  WSROOT=$(printf '%s' "$PAYLOAD" | "$PY" -c "import sys,json
try:
    d=json.load(sys.stdin)
    roots=d.get('workspace_roots') or []
    print(roots[0] if roots else '')
except Exception:
    pass" 2>/dev/null)
  if [ -n "$WSROOT" ] && [ -f "$WSROOT/package.json" ]; then
    PKG_DIR="$WSROOT"
  fi
fi

[ -z "$PKG_DIR" ] && exit 0

# Detect package manager
PM="npm"
if   [ -f "$PKG_DIR/pnpm-lock.yaml" ];    then PM="pnpm"
elif [ -f "$PKG_DIR/yarn.lock" ];         then PM="yarn"
elif [ -f "$PKG_DIR/package-lock.json" ]; then PM="npm"
fi

cd "$PKG_DIR" || exit 0

HAS_TYPECHECK=$("$PY" -c "import json; d=json.load(open('package.json')); print('1' if 'typecheck' in d.get('scripts',{}) else '0')" 2>/dev/null)

if [ "$HAS_TYPECHECK" != "1" ]; then
  exit 0
fi

TC_OUTPUT=$(timeout 60 "$PM" run typecheck 2>&1)
TC_EXIT=$?

# Log result as JSONL — this is the audit trail the agent can read during
# module 03 verification if it wants a second opinion on whether its own
# typecheck run was authoritative.
export HARNESS_FILE="$FILE"
export HARNESS_PKG_DIR="$PKG_DIR"
export HARNESS_PM="$PM"
export HARNESS_EXIT="$TC_EXIT"
export HARNESS_OUTPUT_TAIL=$(printf '%s' "$TC_OUTPUT" | tail -30)
export HARNESS_LOG_FILE="$LOG_FILE"

"$PY" - <<'PY_EOF' 2>/dev/null
import os, json, datetime

line = {
    "ts": datetime.datetime.now().isoformat(timespec="seconds"),
    "event": "afterFileEdit.typecheck",
    "file_path": os.environ.get("HARNESS_FILE", ""),
    "package_dir": os.environ.get("HARNESS_PKG_DIR", ""),
    "package_manager": os.environ.get("HARNESS_PM", ""),
    "exit_code": int(os.environ.get("HARNESS_EXIT", "0") or 0),
    "status": "PASS" if os.environ.get("HARNESS_EXIT") == "0" else ("TIMEOUT" if os.environ.get("HARNESS_EXIT") == "124" else "FAIL"),
    "tail": os.environ.get("HARNESS_OUTPUT_TAIL", "")[-3000:],
}

try:
    with open(os.environ.get("HARNESS_LOG_FILE", ".cursor-harness/typecheck-results.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(line, ensure_ascii=False) + "\n")
except Exception:
    pass
PY_EOF

# afterFileEdit is a notification hook — no structured response expected.
# Exit cleanly without printing anything to stdout.
exit 0
