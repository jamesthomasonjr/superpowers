# Prefer Harness/External Workspace Management — Design Spec

**Status:** Design + implementation for this fork (issue #7).
**Product:** Supersuit (`jeighty/supersuit`).
**Depends on:** Configurable workflow graph (#4); deterministic run/exec
actions (#5 / PR #10); capability-aware overlays (#6 / PR #17). Config dirs
are `.supersuit/` / `~/.supersuit/` with one-release `.superpowers/` read
fallback (#16).
**Does not implement:** Canvas selection (#8 / #9), auto-exec hooks (#12).

## Problem

Default Superpowers leans on agent-driven `using-git-worktrees` (native tool
when the model thinks one exists, else `git worktree`). That burns context
and is nondeterministic. Preference: the harness or an external app owns
workspace management. The agent should not invent worktree steps when the
host can do it.

Creation of a worktree (or other workspace) after brainstorming / before
implementation is still a reasonable *graph position* — it should not have
to be an LLM skill.

## Goals

| Priority | Goal |
|----------|------|
| Primary | When `native-worktree` is **advertised**, the resolved graph prefers a deterministic `ensure-worktree` run over agent-driven `using-git-worktrees`. |
| Compatibility | Zero user/project overlay and no advertised `native-worktree` keeps Superpowers-shaped behavior (agent-mediated worktree skill still available). |
| Safety | Do not auto-detect `native-worktree` from product names. Same conservative probe as #6: only `session-inject` is auto-detected. |
| Round-trip | New run ids work the same SessionStart → `run-workflow-action --id` path as #6 (forward the map's `capabilities` list). |

## Non-goals

- Auto-exec hooks (#12). The agent (or a host exec hook the user already has)
  still invokes `run-workflow-action --id`; this change does not add a
  SessionStart-triggered executor.
- Canvas / visual-surface selection (#8 / #9).
- Rewriting `using-git-worktrees` persuasion content (Red Flags,
  rationalizations, "human partner" language).
- Renaming `using-superpowers` or `SUPERPOWERS_*` environment variables.
- Inferring `native-worktree` from `CURSOR_PLUGIN_ROOT`, Cursor, Claude Code,
  or any other product name.

## Design decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Keep `workflows/default.yaml` ungated and free of `run` actions. | Existing #5 / #6 contract: the Superpowers file stays Superpowers. |
| 2 | Ship a **bundled capability overlay** at `workflows/overlays/native-worktree.yaml`, always merged after `default.yaml` and before user/project overlays. | Advertising `native-worktree` is enough; users should not have to copy an overlay to get the preference. `--bundled-only` still loads it (it is plugin config, not a user overlay). |
| 3 | Gate the overlay on `when.capabilities: [native-worktree]` only. | `exec-hook` would couple this to #12. A host can own workspaces without auto-exec. |
| 4 | Insert `ensure-worktree` on `brainstorming / approved-architectural` (complete → `writing-plans`; failed → `wait`). | Graph position after brainstorm / before implementation, without losing the writing-plans vs SDD/exec split. |
| 5 | Remap `using-git-worktrees` to the same `run` when the capability matches. `complete` → `null`, `failed` → `wait`. | SDD / executing-plans still say "use using-git-worktrees". The registry makes that a handshake, not an LLM skill. Bounded/spike paths that skip the architectural edge still hit this remap if the skill is invoked. |
| 6 | Bundled `scripts/ensure-worktree` never runs `git worktree add`. | The host owns creation. The script is an idempotent handshake: report isolation if present, otherwise say the host owns the workspace, always `complete` unless the process itself errors. |
| 7 | Hosts override the script with a gated overlay of the same `when` signature (later layer upserts). | Project/user can ship a stricter check without forking the graph. |
| 8 | Probe rules unchanged from #6. | A missing probe yields `[]`; gated overlay stays off. |

## Config shape

`workflows/overlays/native-worktree.yaml`:

```yaml
version: 1

skills:
  ensure-worktree:
    run:
      argv:
        - scripts/ensure-worktree
      allow:
        - plugin
    when:
      capabilities:
        - native-worktree
  using-git-worktrees:
    run:
      argv:
        - scripts/ensure-worktree
      allow:
        - plugin
    when:
      capabilities:
        - native-worktree

transitions:
  - from: brainstorming
    on: approved-architectural
    to: ensure-worktree
    when:
      capabilities:
        - native-worktree
  - from: ensure-worktree
    on: complete
    to: writing-plans
    when:
      capabilities:
        - native-worktree
  - from: ensure-worktree
    on: failed
    to: wait
    when:
      capabilities:
        - native-worktree
  - from: using-git-worktrees
    on: complete
    to: null
    when:
      capabilities:
        - native-worktree
  - from: using-git-worktrees
    on: failed
    to: wait
    when:
      capabilities:
        - native-worktree
```

Without `native-worktree`, resolve keeps bundled
`approved-architectural → writing-plans` and `using-git-worktrees` as an
identity skill. With it, the gated edge and both run entries win
(most-specific `when`).

## Layer precedence (updated)

1. Bundled defaults — `workflows/default.yaml`
2. Bundled capability overlays — `workflows/overlays/*.yaml` (sorted by name)
3. User overlay — `~/.supersuit/workflow.yaml` (fallback `~/.superpowers/`)
4. Project overlay — `.supersuit/workflow.yaml` (fallback `.superpowers/`)

`--bundled-only` skips 3–4 only.

## How to advertise `native-worktree`

Not probed. Product name is not evidence. Set one of:

```bash
export SUPERPOWERS_CAPABILITIES=native-worktree
# and/or
./scripts/resolve-workflow --plugin-root "$PWD" --project-root "$PWD" \
  --user-home "$HOME" --capabilities native-worktree
```

SessionStart already honors `SUPERPOWERS_CAPABILITIES` and passes
`--detect-capabilities`. After inject, forward the map's `capabilities` list
into `run-workflow-action --id ensure-worktree --capabilities …` so the
advertised token cannot drop (same round-trip as #6).

## Testing

- Missing capability / missing probe / Cursor env alone: Superpowers
  baseline (identity `using-git-worktrees`, architectural → writing-plans,
  no `ensure-worktree` run).
- Advertised `native-worktree`: architectural → `ensure-worktree` run;
  `using-git-worktrees` remaps to the same run.
- `scripts/ensure-worktree` never contains or executes `git worktree add`.
- Two-call: SessionStart-style resolve then `run-workflow-action --id`
  with forwarded capabilities executes the bundled script; without
  forwarding, detect alone does not invent `native-worktree` (unknown id).
- Same-signature project overlay can replace the script argv.

## Success criteria

- Capable hosts that advertise `native-worktree` get a deterministic
  workspace handshake instead of an LLM worktree skill.
- Zero-overlay hosts that do not advertise it keep Superpowers-shaped
  worktree skill behavior.
- No third-party dependencies. No Canvas. No auto-exec.

## Alternatives considered

| Approach | Why not |
|----------|---------|
| Put gated runs in `default.yaml` | Breaks the #5 / #6 "bundled default stays ungated / no run keys" tests and the Superpowers-shaped file. |
| Require a user/project overlay to opt in | Advertising the capability would not be enough; contradicts the done-when. |
| Gate on `exec-hook` as well | Couples workspace ownership to auto-exec (#12). |
| Thin "defer to harness" skill | Agent still mediates; still nondeterministic (#5 rejected this). |
| `to: wait` only | Works, but capable hosts cannot chain. |
| Delete `using-git-worktrees` | Harms users without external workspace tools. |
| Auto-detect from Cursor/Claude env | Product-name detection; over-claims isolation the host may not own. |
