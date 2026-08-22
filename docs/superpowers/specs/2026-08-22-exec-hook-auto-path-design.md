# Exec-hook Host Auto-path — Design Spec

**Status:** Design + implementation for this fork (issue #12).
**Product:** Supersuit (`jeighty/supersuit`).
**Depends on:** Deterministic run/exec (#5 / PR #10); capability-aware
overlays (#6 / PR #17). Native-worktree (#7 / PR #18) and visual-surface
(#8 / #9 / PR #19) stay independent — they are not gated on `exec-hook`.
**Does not implement:** A new capability token; product-name detection;
bundled default-graph run nodes.

## Problem

PR #10 landed schema + CLI + agent instructions for deterministic
`run` / `exec`. Execution is not automatic: SessionStart injects rules
telling the model to call `scripts/run-workflow-action` when the map
lands on a run id. There is no hook or injected tool that fires the
action.

That leaves a gap:

1. If the agent skips the CLI, invents argv, or claims success without
   running it, behavior collapses to ignoring a checklist.
2. Capability overlays already model `exec-hook` as a token, but
   nothing consumed it to auto-run actions.

## Goals

| Priority | Goal |
|----------|------|
| Primary | When `exec-hook` is **advertised**, a host mediator executes the next run id without the model choosing argv. |
| Fallback | Without that token, behavior matches #10 (agent instructed to call the CLI). |
| Safety | Never infer `exec-hook` from product/harness names or SessionStart env. Always go through `run-workflow-action`. |
| Overlays | Enhanced edges may use `when.capabilities: [exec-hook]`; baseline skill edges stay elsewhere. |
| Round-trip | Forward the resolved map's `capabilities` list into the mediator so advertised tokens cannot drop. |

## Non-goals

- Inferring `exec-hook` from Cursor, Claude, Codex, Copilot, or
  SessionStart running.
- A second capability token.
- Gating `native-worktree` / `native-canvas` on `exec-hook`.
- Putting `run` nodes in `workflows/default.yaml`.
- Rewriting Red Flags / "human partner" tables.

## Design decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | One mediator: `hooks/workflow-exec` (`scripts/workflow-exec`). | Hosts invoke a hook/tool; tests call the same script. |
| 2 | Gate execution on advertised `exec-hook` only. Missing token returns `mode: agent-mediated` and does not run. | Absence must be usable so overlays can choose wait / thin skill / agent-run. |
| 3 | Always delegate to `run_workflow_action()`. | Same allowlist and outcome contract as #10. |
| 4 | Accept `--id` or `--from` / `--on` (and the same fields on hook/tool JSON stdin). | The model already emits `(from, on)`; the host looks up `to` and must not invent argv. |
| 5 | Claude Code Stop stdin is `session_id` / `transcript_path` / `stop_hook_active` — not `from`/`on`. Auto-exec uses a durable `.supersuit/pending-handoff.json` written by `--queue --from/--on` (no run argv). Stop **claims** that file (rename to `.in-progress`), runs `run_workflow_action`, then unlinks only on `auto` or definitive `not-run`. Resolve errors and `agent-mediated` restore the file and emit block JSON (process exit 0). Idle Stop (no queue) returns `mode: idle` **before** `resolve_workflow`. Transcript parsing is not the path. | Real Stop auto-exec that matches Claude stdin and does not drop a queue on a failed consume. |
| 6 | Cursor `sessionStart` is not `exec-hook`. Document Cursor auto as an injected tool calling the same mediator. | Do not overclaim a hook event Cursor does not ship. |
| 7 | SessionStart header is capability-conditional (`HOST_EXEC` vs today's agent-mediated `run-workflow-action` text). | Fallback hosts keep #10 guidance. |
| 8 | No bundled overlay for `exec-hook`. | The token is an execution mode, not a graph feature. Tests use a project overlay fixture. |
| 9 | Probe rules unchanged. | Only `session-inject` is auto-detected. |

## CLI / hook contract

```bash
# Capable host (token advertised + forwarded):
./hooks/workflow-exec --id ensure-fixture \
  --plugin-root "$PLUGIN_ROOT" --project-root "$PWD" --user-home "$HOME" \
  --capabilities session-inject,exec-hook

# Same lookup without naming the run id:
./hooks/workflow-exec --from brainstorming --on approved-architectural \
  --capabilities session-inject,exec-hook

# Claude Code: queue from/on only, then stop. Stop consumes the file.
./hooks/workflow-exec --queue --from brainstorming --on approved-architectural \
  --capabilities session-inject,exec-hook
```

Stdout JSON includes `mode`:

| `mode` | Meaning | Exit |
|--------|---------|------|
| `auto` | Ran the allowlisted argv via `run-workflow-action`. | CLI: 0 if child 0, else 1. Hook event: always 0 after emitting block JSON. |
| `queued` | Wrote `.supersuit/pending-handoff.json`; did not execute. | 0 |
| `agent-mediated` | `exec-hook` not advertised; did not execute. | 2 |
| `not-run` | Next `to` is a skill / `null` / `wait`. | 0 |
| `idle` | Hook fired with no id, from/on, or pending handoff. Does not resolve overlays. | 0 |

## Success criteria

- Advertised `exec-hook` executes a fixture overlay run without model argv.
- Missing token stays agent-mediated; `run-workflow-action` still works.
- Product names / SessionStart env never invent `exec-hook`.
- Allowlist is enforced on the auto path.
- Two-call SessionStart → mediator `--id` with forwarded capabilities.
- `default.yaml` stays ungated / no `run` keys.

## Alternatives considered

| Approach | Why not |
|----------|---------|
| Leave agent-only (#10 as-is) | Weak determinism; the problem statement. |
| Always require a harness orchestrator | Excludes hosts without hooks. |
| Infer exec-hook from Claude/Cursor env | Overclaim; forbidden by #6. |
| Transcript-parsing Stop hook as the only path | Fragile; harness-specific. Durable `--queue` + pending-handoff is the Stop contract. |
| Second token (`auto-exec`) | Forbidden. |
| Bypass `run-workflow-action` | Splits allowlist/outcome contracts. |
| Gate native-worktree / native-canvas on exec-hook | Those PRs explicitly decoupled workspace/visual ownership from auto-exec. |
| Bundled overlay adding run nodes | `default.yaml` must stay Superpowers-shaped; exec-hook is not a graph feature. |
