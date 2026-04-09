#!/usr/bin/env bash
# sensitive-file-guard.sh — Cursor beforeShellExecution / beforeReadFile hook.
#
# Module 06 human override. Refuses access to files matching the sensitive
# denylist. Output JSON uses Cursor's permission field ("allow" | "deny" | "ask").
#
# Denylist:
#   .env, .env.local, .env.production, .env.staging, .env.development
#   credentials.json, service-account.json, secrets.json
#   .netrc, .pgpass
#   *.pem, *.key, *.pfx, *.p12, *.jks, *.keystore, *.crt
#   id_rsa, id_ed25519 (SSH keys)
#   Anything with 'credentials' or 'secret' in the basename

set -o pipefail

PY=""
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
# Fail open if no python — better to let through than block everything
[ -z "$PY" ] && { printf '{"permission": "allow"}'; exit 0; }

PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD=$(cat)
fi
[ -z "$PAYLOAD" ] && { printf '{"permission": "allow"}'; exit 0; }

export HARNESS_PAYLOAD="$PAYLOAD"
"$PY" - <<'PY_EOF'
import json, os, re, sys

raw = os.environ.get("HARNESS_PAYLOAD", "")
try:
    d = json.loads(raw) if raw else {}
except Exception:
    print(json.dumps({"permission": "allow"}))
    sys.exit(0)

# Extract the path or command from any of several payload shapes.
# beforeReadFile: {"file_path": "..."}
# beforeShellExecution: {"command": "rm .env"}
# Generic fallback: tool_input.file_path
candidates = []

fp = d.get("file_path") or d.get("filePath") or ""
if fp:
    candidates.append(fp)

ti = d.get("tool_input") or {}
if ti.get("file_path"):
    candidates.append(ti["file_path"])

cmd = d.get("command") or ti.get("command") or ""

# Denylist configuration
denied_exact = {
    ".env", ".env.local", ".env.production", ".env.staging", ".env.development",
    "credentials.json", "service-account.json", "secrets.json",
    ".netrc", ".pgpass",
    "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
}
denied_suffixes = (".pem", ".key", ".pfx", ".p12", ".jks", ".keystore", ".crt")
denied_patterns = [
    re.compile(r"\.env\."),
    re.compile(r"credentials", re.IGNORECASE),
    re.compile(r"secret", re.IGNORECASE),
    re.compile(r"\.key$"),
]

def check_path(path):
    if not path:
        return None
    base = os.path.basename(path)
    if base in denied_exact:
        return f"exact match: {base}"
    if base.endswith(denied_suffixes):
        return f"suffix match: {base}"
    for pat in denied_patterns:
        if pat.search(base):
            return f"pattern match ({pat.pattern}): {base}"
    return None

# Check direct file paths
for c in candidates:
    reason = check_path(c)
    if reason:
        # Use agentMessage (sent to the AI) + userMessage (shown to human)
        # per Cursor hook response schema (camelCase field names).
        print(json.dumps({
            "permission": "deny",
            "agentMessage": f"[cursor-harness/module-06] blocked sensitive file access ({reason}). You are forbidden from reading or editing files matching the cursor-harness denylist (.env*, keys, credentials, secrets). If this is wrong, escalate to the human — do not work around it.",
            "userMessage": f"cursor-harness blocked agent from sensitive file — {reason}"
        }))
        sys.exit(0)

# Check shell commands for sensitive file references
if cmd:
    tokens = re.split(r"[\s;&|<>]+", cmd)
    for tok in tokens:
        tok_clean = tok.strip("\"'")
        reason = check_path(tok_clean)
        if reason:
            print(json.dumps({
                "permission": "deny",
                "agentMessage": f"[cursor-harness/module-06] blocked shell command that touches a sensitive file ({reason}). Full command: {cmd[:200]}. You are forbidden from running shell commands that read, write, or delete files matching the cursor-harness denylist. Do not work around this.",
                "userMessage": f"cursor-harness blocked shell command — {reason}"
            }))
            sys.exit(0)

print(json.dumps({"permission": "allow"}))
PY_EOF

exit 0
