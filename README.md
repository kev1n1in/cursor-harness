# cursor-harness — Harness Engineering for Cursor IDE

> Six-module harness architecture for the Cursor agent, adapted to Cursor 1.7's hook constraints. Sister project of [cc-harness](https://github.com/kev1n1in/cc-harness) (the Claude Code version).

**Read first:** [docs/LIMITATIONS.md](./docs/LIMITATIONS.md) — Cursor's Stop hook is informational-only in beta, which fundamentally changes how parts of this harness work vs. the Claude Code version. This repo is honest about that.

---

## Why This Exists

Cursor agents drift, just like any coding agent. The [Harness Engineering](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html) discipline defines a framework for closing the gaps between raw model capability and reliable agent behavior: Guides (feedforward) + Sensors (feedback) + Steering + Safety. cursor-harness is one implementation of that framework adapted to Cursor's extension points.

The architecture is shared with cc-harness. The **enforcement mechanisms** differ because Cursor and Claude Code expose different hook capabilities.

## Architecture: Six Modules

| # | Module | Role | Cursor mechanism |
|---|---|---|---|
| 01 | **Context Engineering** | Feedforward — what the agent sees before it acts | `.cursor/rules/01-*.mdc` + AGENTS.md |
| 02 | **Tool Orchestration** | Capability surface, role separation, retry policy | Rules + `beforeShellExecution` hook |
| 03 | **Verification & Self-Repair** | Sensors + critic→fix→re-verify | **Rules-level protocol** (Cursor can't hook this — see LIMITATIONS.md) + `afterFileEdit` computational sensors |
| 04 | **State & Memory** | Working / episodic / procedural memory | Rules + `AGENTS.md` + external memory dir |
| 05 | **Observability** | Tracing, drift monitoring, meta-evaluation | `stop` hook logs + golden task scripts |
| 06 | **Human Override** | Safety boundary, destructive-action gate | `beforeShellExecution` + `beforeReadFile` denylists + rules |

Rule files live in `.cursor/rules/0N-<name>.mdc` — Cursor's first-class per-rule format. Module 03 is the headline — read [`.cursor/rules/03-verification.mdc`](./.cursor/rules/03-verification.mdc) first.

## Install

Clone into your project root (or merge `.cursor/` into an existing one):

```bash
cd your-project/
git clone --depth 1 https://github.com/kev1n1in/cursor-harness .cursor-harness-tmp
cp -r .cursor-harness-tmp/.cursor .cursor
cp .cursor-harness-tmp/AGENTS.md AGENTS.md
cp -r .cursor-harness-tmp/scripts .cursor-harness-scripts
cp .cursor-harness-tmp/hooks.json hooks.json
rm -rf .cursor-harness-tmp
```

Cursor automatically loads `.cursor/rules/*.mdc` and `AGENTS.md`. `hooks.json` is loaded if placed at the project root or `~/.cursor/hooks.json` for global.

## The Hard Truth About Cursor's Stop Hook

Cursor 1.7 (October 2025) added a `stop` hook. Unlike Claude Code's Stop hook:

- Cursor's stop hook **cannot return JSON to block or inject context back into the agent**. The beta documentation and community reports ([GitButler deep dive](https://blog.gitbutler.com/cursor-hooks-deep-dive), [forum bug reports](https://forum.cursor.com/t/hook-ask-output-not-stopping-agent/149002)) confirm it's an observation point only
- This means the "auto-evaluation before reply + self-correction" pattern that cc-harness implements *cannot* be done at hook level in Cursor

cursor-harness compensates by:
1. **Rules-level enforcement** (`.cursor/rules/03-verification.mdc`): a mandatory protocol the agent must follow — runs self-eval in its own context, at the cost of more tokens than cc-harness's subagent-isolated version
2. **`afterFileEdit` computational sensors**: typecheck/lint run automatically after each edit, with warnings surfaced via Cursor's hook output fields (flaky on Windows per existing bug reports — see LIMITATIONS.md)
3. **`stop` hook as observability**: logs every stop event to `.cursor-harness/stop-log.jsonl` for post-hoc review of whether the agent actually ran verification

The cost: higher main-context usage than the equivalent cc-harness flow, and an honest "the model might forget" failure mode that cc-harness doesn't have.

## Directory Layout

```
cursor-harness/
├── .cursor/
│   └── rules/
│       ├── 00-harness-protocol.mdc    — meta rule (alwaysApply: true)
│       ├── 01-context-engineering.mdc
│       ├── 02-tool-orchestration.mdc
│       ├── 03-verification.mdc        ⭐ read this first
│       ├── 04-state-memory.mdc
│       ├── 05-observability.mdc
│       └── 06-human-override.mdc
├── AGENTS.md                          — top-level contract (loaded by Cursor)
├── hooks.json                         — afterFileEdit + beforeShellExecution + stop
├── scripts/
│   ├── after-edit-typecheck.sh        — computational sensor, injects warnings via user_message
│   ├── stop-logger.sh                 — appends stop events to JSONL for observability
│   └── sensitive-file-guard.sh        — denylist for beforeReadFile / beforeShellExecution
├── docs/
│   ├── LIMITATIONS.md                 — honest delta vs cc-harness
│   └── MIGRATION-FROM-CC.md           — mapping cc-harness concepts → cursor-harness
└── README.md
```

## How It Differs From cc-harness

| Concern | cc-harness (Claude Code) | cursor-harness (Cursor) |
|---|---|---|
| Pre-reply self-evaluation | Stop hook `type:"agent"` spawns evaluator subagent, blocks on FAIL | Rules-level protocol — agent must run `/evaluate` before responding; no hook enforcement |
| Computational sensors after edit | PostToolUse with stderr injection | `afterFileEdit` hook with `user_message` field (Windows-flaky per issue #142589) |
| Read-only turn detection | stop-gate.sh parses transcript for zero-cost short-circuit | Rules-level: "only run verification when you made writes this turn" |
| Context cost on successful write task | ~300 tokens (subagent returns short JSON) | ~1500+ tokens (eval runs in main context) |
| Escape hatch on repeated FAIL | `stop_hook_active` flag, hard-coded 3-round cap | Rule text: "after 3 rounds, escalate to user" — trusts the agent to count |
| Sensitive-file guard | PreToolUse hook, cannot be bypassed | `beforeReadFile` / `beforeShellExecution` hook — works where ASK/DENY is respected, still beta-flaky |

**Bottom line:** where Cursor respects hook output, cursor-harness uses it. Where Cursor's hook output is ignored (notably the Stop hook and the `user_message` field on Windows), cursor-harness falls back to rules. This is the best possible on Cursor 1.7 beta. Watch the Cursor changelog — as more hooks become non-advisory, migrate rules → hooks.

## License

MIT
