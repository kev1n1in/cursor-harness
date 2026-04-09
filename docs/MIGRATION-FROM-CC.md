# Migration From cc-harness

Concept-by-concept mapping between cc-harness (Claude Code) and cursor-harness (Cursor).

## Overall Architecture

The six modules are identical in intent. The *mechanisms* enforcing them differ because Cursor and Claude Code expose different hook capabilities. See `LIMITATIONS.md` for the underlying reason.

## Side-by-side

| Concept | cc-harness path | cursor-harness path |
|---|---|---|
| Plugin/project metadata | `.claude-plugin/plugin.json` + `marketplace.json` | None — cursor-harness installs as files into your project |
| Top-level agent contract | `CLAUDE.md` (project) / plugin-scoped | `AGENTS.md` (repo root) |
| Meta-protocol | `skills/` (implicit — each skill loaded contextually) | `.cursor/rules/00-harness-protocol.mdc` (`alwaysApply: true`) |
| Module 01 — Context Engineering | `skills/01-context-engineering/SKILL.md` | `.cursor/rules/01-context-engineering.mdc` |
| Module 02 — Tool Orchestration | `skills/02-tool-orchestration/SKILL.md` | `.cursor/rules/02-tool-orchestration.mdc` |
| Module 03 — Verification (headline) | `skills/03-verification/SKILL.md` + Stop hook agents | `.cursor/rules/03-verification.mdc` (rules-level only) |
| Module 04 — State & Memory | `skills/04-state-memory/SKILL.md` | `.cursor/rules/04-state-memory.mdc` |
| Module 05 — Observability | `skills/05-observability/SKILL.md` + (planned) bench | `.cursor/rules/05-observability.mdc` + `scripts/stop-logger.sh` |
| Module 06 — Human Override | `skills/06-human-override/SKILL.md` + PreToolUse guard | `.cursor/rules/06-human-override.mdc` + `scripts/sensitive-file-guard.sh` |

## Hook-by-hook

| Intent | cc-harness (hooks.json) | cursor-harness (hooks.json) | Notes |
|---|---|---|---|
| Refuse sensitive file edits | `PreToolUse` matcher `Write\|Edit\|MultiEdit` → `scripts/sensitive-file-guard.sh` | `beforeReadFile` + `beforeShellExecution` → `scripts/sensitive-file-guard.sh` | Cursor's hook respects `permission: "deny"` — mostly equivalent |
| Thrashing sensor | `PostToolUse` matcher `Edit\|Write\|MultiEdit` → `scripts/edit-thrashing.sh` | Not implemented at hook level | Cursor doesn't have a PostToolUse equivalent that reliably sees tool input. Moved to rule text in `02-tool-orchestration.mdc` |
| Typecheck after edit | `PostToolUse` → `scripts/auto-test-runner.sh`, injects to stderr (reaches the agent) | `afterFileEdit` → `scripts/after-edit-typecheck.sh`, writes to `.cursor-harness/typecheck-results.jsonl` **only** (hook is notification-only; agent must run typecheck itself per module 03) | Fundamentally different — cursor hook can't feed results back to the agent |
| Auto-evaluate before reply | `Stop` hook 2-entry: command gate + agent subagent. Returns `{"decision": "block"}` on FAIL | **No equivalent** — Cursor's `stop` hook ignores output JSON. Enforcement moved to rules (`03-verification.mdc`) | This is the main delta. See LIMITATIONS.md |
| Observability of stop events | Implicit in the agent dispatch | `stop` hook → `scripts/stop-logger.sh` writes JSONL | Observation-only on Cursor, still useful for post-hoc audit |

## Agent roles

cc-harness has first-class agent files (`agents/evaluator.md`, `agents/planner.md`) because Claude Code supports dispatching a named subagent with its own tool whitelist via the `Agent` tool and via `type: "agent"` hook entries.

Cursor has MCP tools and background agents, but no direct equivalent of "subagent with a frontmatter-defined tool whitelist". cursor-harness therefore:

- Encodes the **planner** role as a section in `AGENTS.md` + advice in `02-tool-orchestration.mdc` ("when planning, use read-only tools only, don't edit")
- Encodes the **evaluator** role as the mandatory protocol in `03-verification.mdc` ("step into evaluator mode: read only, judge only, no edits until after verdict")
- Both run in the main agent's context — giving up the context isolation cc-harness gets for free

## Sentinel protocol

- cc-harness uses `[CC-HARNESS-EVAL:PASS]` / `[CC-HARNESS-EVAL:FAIL]` in assistant text, detected by `stop-gate.sh`
- cursor-harness doesn't need a sentinel — there is no hook re-reading the output. The rule text says "only reply after PASS", and that's the enforcement

## What you lose by being on Cursor

1. **Zero-cost read-only gating.** On cc-harness, a read-only turn has literally zero main-agent cost (the hook decides in bash without touching the agent). On cursor-harness, the agent itself has to remember to skip verification on read-only turns, burning attention to do the check
2. **Isolated evaluator context.** cc-harness's evaluator can burn 5000 tokens on a review without the main agent seeing any of it. cursor-harness's rule-based eval runs in the main context
3. **Hook-level escape hatch on loops.** cc-harness uses `stop_hook_active` + counter file. cursor-harness trusts the agent to count to 3
4. **Unopt-outable enforcement.** If the model is distracted / context-rotted / given contradictory instructions, cc-harness still blocks at hook level. cursor-harness's protocol is in the prompt surface, same as any rule the model could, in theory, forget

## What you gain

- Cursor-native workflow integration (background agents, Composer, inline edits)
- Simpler install — just copy `.cursor/rules/` + `AGENTS.md` + `hooks.json` into your project
- No plugin cache layer to work around (cc-harness has the "source dir vs cached install" gotcha)

## Forward-compat plan

There are **two** notification-only hooks we want Cursor to promote to enforceable:

### If `stop` starts respecting output JSON

1. Port `scripts/stop-gate.sh` from cc-harness (adjust stdin field names for Cursor's payload shape: `conversation_id` / `generation_id` / `workspace_roots` instead of Claude Code's `session_id` / `transcript_path`)
2. Update `.cursor/hooks.json` to add a second `stop` entry that runs the evaluator agent
3. Relax `.cursor/rules/03-verification.mdc` from "MUST run" to "hook runs this, you fix FAIL results"

### If `afterFileEdit` starts respecting output JSON

1. Update `scripts/after-edit-typecheck.sh` to return `{"agentMessage": "..."}` on typecheck failure
2. Relax module 03's "run typecheck yourself" to "investigate any typecheck warning you see from the hook"
3. Keep the JSONL log as a backup / audit trail

### Watch list

- [cursor.com/changelog](https://cursor.com/changelog) — Cursor release notes
- [cursor.com/docs/hooks](https://cursor.com/docs/hooks) — hook spec updates
- [forum.cursor.com — Hooks category](https://forum.cursor.com/tag/hooks) — community reports of beta → stable promotions

The migration is intentionally small — rules and hooks are isomorphic in intent; we're just moving where the enforcement lives when Cursor lets us.
