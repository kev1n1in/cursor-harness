#!/usr/bin/env bash
# stop-logger.sh — Cursor stop hook.
#
# Module 05 observability. Cursor 1.7 beta ignores stop hook output JSON, so
# we cannot block or inject context here. What we CAN do is log every stop
# event to JSONL for post-hoc analysis.
#
# This is intentionally minimal: timestamp, session id if present, file
# count (if payload contains it), and the trailing few tool calls.

set -o pipefail

LOG_DIR=".cursor-harness"
LOG_FILE="$LOG_DIR/stop-log.jsonl"
mkdir -p "$LOG_DIR" 2>/dev/null

PY=""
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done

PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD=$(cat)
fi

TS=$(date '+%Y-%m-%dT%H:%M:%S%z')

if [ -z "$PY" ] || [ -z "$PAYLOAD" ]; then
  # Degraded: write timestamp only and exit (stop is informational-only)
  echo "{\"ts\":\"$TS\",\"note\":\"degraded: no python or empty payload\"}" >> "$LOG_FILE" 2>/dev/null
  exit 0
fi

# Append a normalized log line via python. Payload via env var to avoid
# argv escaping; explicit `-` so python reads the script from stdin (heredoc).
export HARNESS_PAYLOAD="$PAYLOAD"
export HARNESS_TS="$TS"
export HARNESS_LOG_FILE="$LOG_FILE"
"$PY" - <<'PY_EOF' 2>/dev/null
import os, json

raw = os.environ.get("HARNESS_PAYLOAD", "")
ts = os.environ.get("HARNESS_TS", "")
log_file = os.environ.get("HARNESS_LOG_FILE", "")

try:
    d = json.loads(raw) if raw else {}
except Exception as e:
    d = {"_parse_error": str(e)}

line = {
    "ts": ts,
    "session_id": d.get("session_id", "unknown"),
    "event": "stop",
    "payload_keys": sorted(list(d.keys()))[:20],
}

recent = d.get("recent_tool_calls") or d.get("tool_calls") or []
if isinstance(recent, list):
    line["recent_tool_count"] = len(recent)
    line["recent_tools"] = [
        t.get("name") or t.get("tool_name")
        for t in recent if isinstance(t, dict)
    ][-10:]

try:
    with open(log_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(line, ensure_ascii=False) + "\n")
except Exception:
    pass
PY_EOF

# stop is a notification hook — no structured response expected. Exit cleanly.
exit 0
