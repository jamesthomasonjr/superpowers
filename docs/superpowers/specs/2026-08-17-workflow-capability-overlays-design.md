# Capability-Aware Workflow Overlays — Design Spec

**Status:** Design + implementation for this fork (issue #6).
**Product:** Supersuit (`jeighty/supersuit`).
**Depends on:** Configurable workflow graph (#4); pairs with deterministic
run/exec actions (#5 / PR #10). Config dirs are `.supersuit/` /
`~/.supersuit/` with one-release `.superpowers/` read fallback (#16).
**Enables later (not this change):** Canvas-vs-companion selection (#9),
harness workspace preference (#7). Those issues stay follow-ups.

## Problem

Harnesses differ (SessionStart injection, native worktrees, subagents, exec
hooks, Canvas). One static graph either underserves capable hosts or assumes
tools that are missing. Brand-specific skill forks (`*.cursor.md`) do not scale.

## Goals

| Priority | Goal |
|----------|------|
| Primary | Apply enhanced transitions / registry entries only when the host advertises matching **capabilities**. |
| Secondary | Prefer capability tokens over product names (`session-inject`, `native-worktree`, `subagents`, `exec-hook`, `native-canvas`). |
| Compatibility | Baseline (no `when`) remains valid everywhere; bundled default stays ungated. |
| Portability | Resolver filters at resolve-time; injected map is already host-specific. |

## Non-goals

- Full feature-probe framework inside every harness.
- Auto-claiming `native-canvas` / `native-worktree` / `subagents` / `exec-hook` from product env alone (too easy to overclaim).
- Replacing description-triggered skill discovery with capability graphs.
- Implementing #7, #8, #9, or #12 in this change.
- Renaming `using-superpowers` or `SUPERPOWERS_*` environment variables.

## Design decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Optional `when.capabilities: […]` on transitions and skill registry entries. | Matches issue shape; progressive enhancement without new files. |
| 2 | A clause matches iff **every** listed capability is in the active set (AND). | Predictable; OR can be expressed as two transitions. |
| 3 | Active capabilities = `--detect-capabilities` ∪ `SUPERPOWERS_CAPABILITIES` ∪ `--capabilities`. | Hooks/agents can pass what they know; humans can override. |
| 4 | Auto-detect only `session-inject` when SessionStart-like env is present. | Conservative; avoid false Canvas/worktree/subagent/exec claims. |
| 5 | Duplicate `(from, on)` allowed when `when` signatures differ. | Baseline + enhanced edge can coexist. |
| 6 | At resolve, among matching candidates, prefer the most specific `when` (largest capability set); error if tie. | Deterministic progressive enhancement. |
| 7 | Merge: ungated overlay transitions keep replace-by-`from`; **gated** overlay transitions are **appended** and never drop baseline edges. | Lets overlays add enhancement without re-listing the whole `from` node. |
| 8 | Gated overlay **skills** accumulate as candidates; they do not replace a lower-layer ungated remap. | A Canvas-only path must not wipe a user alias when Canvas is absent. |
| 9 | Emit resolved transitions/skills with `when` stripped; include `capabilities` list on the artifact. | Agents see a clean host-specific map. |
| 10 | `when` accepts only `capabilities`. Other keys fail closed. | Prevents silent product-name switches (`harness: cursor`). |
| 11 | Schema stays `version: 1` (additive). | Same as #5. Unknown capability tokens are allowed but do not match until advertised. |

## Capability tokens

| Token | Meaning | Detected how |
|-------|---------|--------------|
| `session-inject` | Host injects bootstrap / workflow map at session start. | Probe: `CURSOR_PLUGIN_ROOT`, `CLAUDE_PLUGIN_ROOT`, or `COPILOT_CLI` is set. |
| `native-worktree` | Host owns worktree / workspace creation. | Not probed. Advertise via CLI or `SUPERPOWERS_CAPABILITIES`. |
| `subagents` | Host supports subagent dispatch. | Not probed. Advertise explicitly. |
| `exec-hook` | Host can run deterministic workflow actions without the chat model mediating. | Not probed. SessionStart ≠ exec hook. |
| `native-canvas` | Host provides a native visual surface (e.g. Cursor Canvas). | Not probed. Do not infer from Cursor env. |

A missing probe (no SessionStart-like env, no env/CLI advertisement) yields an
empty capability set. Gated overlays stay inactive. That is the required
**missing-capability-probe** behavior: fail toward the Superpowers baseline.

## Config shape

```yaml
version: 1

skills:
  ensure-worktree:
    run:
      argv:
        - scripts/ensure-worktree.sh
      allow:
        - project
    when:
      capabilities:
        - exec-hook

transitions:
  # Progressive enhancement: gated edge appended; baseline remains.
  - from: brainstorming
    on: approved-architectural
    to: ensure-worktree
    when:
      capabilities:
        - exec-hook
```

Without `exec-hook`, resolve keeps bundled `approved-architectural → writing-plans`.
With `exec-hook`, resolve selects the gated edge (and includes the run registry entry).

Canonical overlay path is `.supersuit/workflow.yaml` (user: `~/.supersuit/workflow.yaml`).
Leftover `.superpowers/` still loads for one release when the canonical file is absent.

## CLI / SessionStart

```bash
./scripts/resolve-workflow \
  --plugin-root "$PWD" \
  --project-root "$PWD" \
  --user-home "$HOME" \
  --capabilities session-inject,exec-hook
```

Env: `SUPERPOWERS_CAPABILITIES=session-inject,exec-hook` (comma-separated).

SessionStart passes `--detect-capabilities` (currently auto-detects
`session-inject` when hook env is present) plus any env override into
`resolve-workflow`.

`run-workflow-action --id` **always** runs the same conservative probe, then
unions `SUPERPOWERS_CAPABILITIES` and `--capabilities`. The documented
`--id` invocation cannot drop SessionStart-detected `session-inject`. Forward
the resolved map's `capabilities` list via `--capabilities` so advertised
tokens cannot drift.

## Testing

- Merge appends gated transitions without dropping baseline `from` edges.
- Resolve **match**: advertised capability selects the gated `(from, on)` target.
- Resolve **miss**: absent capability keeps the baseline edge.
- **Missing-capability-probe**: `--detect-capabilities` with a clean env invents
  no tokens and does not apply gated overlays.
- Gated skill miss keeps a lower-layer remap; match selects the gated entry.
- Ambiguous equally-specific matches fail closed.
- SessionStart still injects a map; `capabilities` includes `session-inject`
  and does not claim `native-canvas` from Cursor env alone.
- Two-call: SessionStart-style resolve (`--detect-capabilities`) then
  `run-workflow-action --id` without `--detect-capabilities` executes the
  gated script for a gated-only run id and for a gated run with an ungated
  fallback (does not unknown-id or silently run the fallback).

## Success criteria

- Capable hosts can opt into enhanced edges without breaking weaker hosts.
- Zero-config default graph unchanged.
- No third-party dependencies.
- #7 / #8 / #9 / #12 remain unimplemented.

## Alternatives considered

| Approach | Why not |
|----------|---------|
| Per-harness full skill copies | Drift-prone. |
| Always weakest common denominator | Leaves enhancement on the table. |
| Runtime external orchestrator only | Stronger enforcement, higher cost. |
| Product-name switches only | Does not scale across forks/hosts. |
| Replace-by-id for gated skills (PR #11 stacked attempt) | A gated project remap would wipe a user alias on hosts that lack the capability. Accumulation is the honest progressive-enhancement merge. |
