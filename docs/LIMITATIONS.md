# LIMITATIONS — Honest Delta vs cc-harness

> This document exists because a harness that lies about what it enforces is worse than one that admits its gaps.

## TL;DR

Cursor 1.7 (released October 2025) added a hook system for agent lifecycle events. Most of the hooks work as advertised. **One critical hook — `stop` — is observation-only in the beta**: it fires when the agent finishes, but Cursor does not read its output JSON, which means you cannot block the agent from replying, cannot inject context into the agent's next step, and cannot implement the "auto-evaluation before reply" pattern at hook level.

This is the single biggest difference between cursor-harness and its Claude Code sister project [cc-harness](https://github.com/kev1n1in/cc-harness). Everything else is a direct port; this module is a workaround.

## The Specific Limitation

### What Cursor's `stop` hook does

Cursor 1.7's hooks documentation ([cursor.com/docs/hooks](https://cursor.com/docs/hooks)) lists the following lifecycle events:
- `beforeShellExecution` — pre-gate shell commands
- `beforeMCPExecution` — pre-gate MCP tool calls
- `beforeReadFile` — pre-gate file reads
- `afterFileEdit` — post-process file edits
- `stop` — fires when the agent finishes a response

Of these, the first four **respect output JSON fields** like `permission: "allow" | "deny" | "ask"` and can influence what happens next. The `stop` hook fires reliably, but:

> "in the beta version, you cannot do much here other than record this information — Cursor doesn't respect any output json here currently, such as stopping the task or adding context."
>
> — [GitButler — Deep Dive into the new Cursor Hooks](https://blog.gitbutler.com/cursor-hooks-deep-dive)

This is corroborated by multiple forum bug reports:
- [Hook ASK output not stopping agent](https://forum.cursor.com/t/hook-ask-output-not-stopping-agent/149002) — even `beforeShellExecution` ASK responses sometimes fail to interrupt
- [Hook response fields user_message / agent_message still ignored in Windows v2.0.77](https://forum.cursor.com/t/regression-hook-response-fields-user-message-agent-message-still-ignored-in-windows-v2-0-77/142589) — the mechanism for injecting context back into the agent is flaky on Windows

### What cc-harness does (that cursor-harness cannot)

On Claude Code, the Stop hook supports two mechanisms cursor-harness cannot replicate:

1. **`{"decision": "block", "reason": "..."}`** — the hook returns block and Claude Code re-prompts the main agent with `reason` as a synthetic user message. This is how you force a fix-and-retry loop
2. **`type: "agent"` hook entries** — the hook itself spawns a subagent (in isolated context, reads transcript, runs its own tools). The main agent only sees the subagent's terse result, not its full reasoning

Together, these let cc-harness run the entire verification protocol **outside the main agent's context**, so a successful write task pays only ~300 tokens for evaluation and the agent doesn't even know the eval happened.

Cursor's stop hook can't block, and Cursor doesn't have first-class subagents spawnable from hooks. Neither mechanism is available.

## How cursor-harness Compensates

### 1. Rules-level enforcement of the verification protocol

`.cursor/rules/03-verification.mdc` defines the full critic→fix→re-verify protocol as a **mandatory rule the agent must follow**. This is prompt engineering, not hook enforcement. Consequences:

| Property | cc-harness | cursor-harness |
|---|---|---|
| Enforcement | Hook — cannot be skipped | Rule — model must remember |
| Main context cost (successful write task) | ~300 tokens | ~1500+ tokens |
| Read-only turn detection | Bash transcript scan, zero main cost | Rule text: "skip if read-only" — trusts the agent |
| Escape from loop | Code: `stop_hook_active` flag, 3-round cap | Rule text: "after 3 rounds, escalate" — trusts the agent |
| Robustness under distraction | Model cannot opt out | Model can forget |

### 2. `afterFileEdit` as a computational sensor

`scripts/after-edit-typecheck.sh` runs typecheck after every edit. Where it works, output is injected via the `user_message` field (Cursor's documented way to push information into the agent's next step).

**Known bug**: `user_message` / `agent_message` fields are ignored on Windows in some 2.0.x versions ([forum issue #142589](https://forum.cursor.com/t/regression-hook-response-fields-user-message-agent-message-still-ignored-in-windows-v2-0-77/142589)). cursor-harness also writes the error to stderr as a belt-and-suspenders fallback — at least it gets logged somewhere.

### 3. `stop` hook for observation only

`scripts/stop-logger.sh` appends every stop event to `.cursor-harness/stop-log.jsonl`. Since the hook can't block, all it can do is observe. But observation is the foundation of module 05 (observability), and this log lets you audit *post hoc* whether the agent actually ran the verification protocol.

### 4. `beforeShellExecution` and `beforeReadFile` for module 06

Good news: these hooks *do* respect the `permission: "deny"` field (with the caveat from the ASK bug above). `scripts/sensitive-file-guard.sh` denies access to files matching the denylist for both of these events. This is mostly equivalent to cc-harness's PreToolUse guard.

## Honest Failure Modes

Given the above, here is what cursor-harness can and cannot catch:

| Failure mode | cc-harness | cursor-harness |
|---|---|---|
| Agent says "done" without running typecheck | Blocked by hook | Rule — model must comply |
| Agent ignores typecheck failure from `afterFileEdit` | Blocked by hook injection | Works where `user_message` works; stderr fallback on Windows |
| Agent edits `.env` | Blocked by PreToolUse | Blocked by `beforeReadFile` / shell guard (with ASK beta caveat) |
| Agent force-pushes without confirmation | Blocked by PreToolUse | Blocked by `beforeShellExecution` (same caveat) |
| Agent gets stuck in a fix loop | 3-round hard cap in code | 3-round cap in rules — agent must count |
| Eval burns main context | Subagent isolation (~300 tok) | In main context (~1500+ tok) |

## When Will This Be Fixed?

Cursor's hook system is in beta and shipping improvements. Watch the [Cursor changelog](https://cursor.com/changelog) and the [hooks documentation](https://cursor.com/docs/hooks) for:

1. `stop` hook output JSON being respected — enables block/inject semantics
2. `user_message` / `agent_message` field reliability on Windows
3. First-class subagent dispatch from hooks — enables isolated-context evaluation

Once any of these land, migrate corresponding rules → hooks. Track progress in `docs/MIGRATION-FROM-CC.md`.

## If You Need Hook-level Enforcement Now

Use Claude Code with [cc-harness](https://github.com/kev1n1in/cc-harness). Same architecture, same six modules, but enforcement at hook level where it cannot be opted out of.

Cursor's hook surface is catching up quickly, but as of Cursor 1.7 beta (April 2026), the Stop hook gap is real and cursor-harness is the best you can do on Cursor alone.

## Sources

- [Cursor — Hooks documentation](https://cursor.com/docs/hooks)
- [GitButler — Deep Dive into the new Cursor Hooks](https://blog.gitbutler.com/cursor-hooks-deep-dive)
- [Cursor Forum — Hook ASK output not stopping agent](https://forum.cursor.com/t/hook-ask-output-not-stopping-agent/149002)
- [Cursor Forum — Hook response fields user_message / agent_message still ignored on Windows v2.0.77](https://forum.cursor.com/t/regression-hook-response-fields-user-message-agent-message-still-ignored-in-windows-v2-0-77/142589)
- [Cursor 1.7 Adds Hooks for Agent Lifecycle Control — InfoQ](https://www.infoq.com/news/2025/10/cursor-hooks/)
- [Claude Code — Hooks reference](https://code.claude.com/docs/en/hooks)
