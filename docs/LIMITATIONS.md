# LIMITATIONS — Honest Delta vs cc-harness

> This document exists because a harness that lies about what it enforces is worse than one that admits its gaps.

## TL;DR

Cursor 1.7 (released October 2025) added a hook system for agent lifecycle events. Some hooks are genuinely able to block or inject context; **others are notification-only** — they fire, but Cursor ignores any JSON you return, so you cannot use them to enforce anything.

Of the six hook events, **three are notification-only**:
- `stop` — can't block the agent from replying or inject evaluation results back
- `afterFileEdit` — can't surface typecheck/lint errors back to the agent
- `beforeSubmitPrompt` — can't inspect or modify the prompt

And **three can actually enforce policy**:
- `beforeShellExecution` — can deny/ask + inject `agentMessage` / `userMessage`
- `beforeMCPExecution` — same enforcement surface
- `beforeReadFile` — can deny file reads with a message

The combination means the two enforcement patterns cursor-harness most wants — **"auto-evaluate before reply"** and **"inject typecheck errors after edit"** — both land on notification-only hooks. cursor-harness has to work around both.

This is the core difference between cursor-harness and its Claude Code sister project [cc-harness](https://github.com/kev1n1in/cc-harness). Everything else is a direct port; these are the workarounds.

## The Three Notification-Only Hooks

### 1. `stop` — informational only

> "in the beta version, you cannot do much here other than record this information — Cursor doesn't respect any output json here currently, such as stopping the task or adding context."
>
> — [GitButler — Deep Dive into the new Cursor Hooks](https://blog.gitbutler.com/cursor-hooks-deep-dive)

Means the "auto-evaluate before reply, block on FAIL" pattern can't be hook-enforced on Cursor.

### 2. `afterFileEdit` — notification only

Confirmed by multiple sources:
- [GitButler deep dive](https://blog.gitbutler.com/cursor-hooks-deep-dive): *"Like the `beforeSubmitPrompt` hook, this is informational only — you cannot communicate to the user, agent or stop the agent with json output here."*
- [johnlindquist/cursor-hooks type definitions](https://github.com/johnlindquist/cursor-hooks): `afterFileEdit` → *"Response: None (this is a notification hook)"*

Means "after edit → run typecheck → inject error to agent" is **not possible at hook level** on Cursor. This is the one I missed in the initial release and have now documented.

### 3. `beforeSubmitPrompt` — notification only

Fires when the user sends a prompt, but Cursor ignores the output. Means "filter / rewrite the user's prompt before the agent sees it" is not available.

## The Workaround for Each

### For `stop` (verification gate)

cursor-harness moves the verification protocol from a hook into `.cursor/rules/03-verification.mdc` with `alwaysApply: true`. The rule text mandates the agent itself runs the critic → fix → re-verify loop before replying. This is **prompt-level enforcement** — less reliable than cc-harness's hook-level, but the best available on Cursor 1.7 beta.

Consequences:
- The protocol runs in the main agent's context, costing more tokens than cc-harness's subagent-isolated version
- If the model is distracted, context-rotted, or given contradictory instructions, it might skip the protocol. There is no hook catching that. cc-harness does not have this failure mode

### For `afterFileEdit` (computational sensors)

Since the hook can't feed errors back to the agent, cursor-harness's `after-edit-typecheck.sh` is **observability-only**: it runs the typecheck and writes the result as a line in `.cursor-harness/typecheck-results.jsonl`. The hook never tries to return `agentMessage` — that would be ignored.

Module 03's verification protocol (in `.cursor/rules/03-verification.mdc`) instructs the agent to **run typecheck itself** during its own pre-reply checks. The hook's JSONL log is a **cross-check / audit trail** the agent can read if it wants a second opinion, and a post-hoc log the human can inspect.

In other words: on Cursor, the agent does the typecheck in-band. The hook just records what it saw in the background.

### For `beforeSubmitPrompt`

Not used by cursor-harness. Listed here for completeness.

## The Forum Bug Reports (context ambiguity for the `before*` hooks)

Even the hooks that *are* supposed to respect output have issues:
- [Hook ASK output not stopping agent](https://forum.cursor.com/t/hook-ask-output-not-stopping-agent/149002) — `beforeShellExecution` ASK responses sometimes fail to interrupt
- [Hook response fields user_message / agent_message still ignored in Windows v2.0.77](https://forum.cursor.com/t/regression-hook-response-fields-user-message-agent-message-still-ignored-in-windows-v2-0-77/142589) — historical regression; note the correct field names are `userMessage` / `agentMessage` (camelCase) — snake_case is a forum-thread typo

### What cc-harness does (that cursor-harness cannot)

On Claude Code, the Stop hook supports two mechanisms cursor-harness cannot replicate:

1. **`{"decision": "block", "reason": "..."}`** — the hook returns block and Claude Code re-prompts the main agent with `reason` as a synthetic user message. This is how you force a fix-and-retry loop
2. **`type: "agent"` hook entries** — the hook itself spawns a subagent (in isolated context, reads transcript, runs its own tools). The main agent only sees the subagent's terse result, not its full reasoning

Together, these let cc-harness run the entire verification protocol **outside the main agent's context**, so a successful write task pays only ~300 tokens for evaluation and the agent doesn't even know the eval happened.

Cursor's stop hook can't block, and Cursor doesn't have first-class subagents spawnable from hooks. Neither mechanism is available.

## What Works (the two enforceable patterns)

### `beforeShellExecution` + `beforeReadFile` for module 06

These hooks **do** respect output JSON. `scripts/sensitive-file-guard.sh` wired to both events can return:

```json
{
  "permission": "deny",
  "agentMessage": "why the agent should stop trying this",
  "userMessage": "what to show the human"
}
```

This is roughly equivalent to cc-harness's PreToolUse guard. Caveat: the ASK interrupt bug ([forum #149002](https://forum.cursor.com/t/hook-ask-output-not-stopping-agent/149002)) can affect the ASK verb — DENY is reliable, ASK is historically flaky.

### `beforeMCPExecution` for MCP tools

Same enforcement surface as the shell hook but applied to MCP tool calls. cursor-harness doesn't ship a script for this yet (no MCP servers assumed in the base install), but the hook is available if you add one.

## Honest Failure Modes

Given the above, here is what cursor-harness can and cannot catch:

| Failure mode | cc-harness | cursor-harness |
|---|---|---|
| Agent says "done" without running typecheck | Hook blocks at Stop | **Rule** — model must comply. If model forgets, nothing catches it |
| Agent ignores typecheck failure after edit | Hook injects error via stderr | **Rule** — model must run typecheck in-band per module 03 protocol. Hook logs to JSONL as audit trail only |
| Agent edits `.env` | Hook blocks at PreToolUse | Hook blocks at `beforeReadFile` (DENY reliable) |
| Agent force-pushes without confirmation | Hook blocks at PreToolUse | Hook blocks at `beforeShellExecution` (DENY reliable) |
| Agent gets stuck in a fix loop | 3-round hard cap in code | 3-round cap in rules — agent must count |
| Eval burns main context | Subagent isolation (~300 tok) | In main context (~1500+ tok) |

**The common thread:** whenever enforcement lands on a `before*` hook, cursor-harness and cc-harness are roughly equivalent. Whenever it lands on `stop` or `afterFileEdit` (both notification-only), cursor-harness falls back to rules and loses hook-level guarantees.

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
