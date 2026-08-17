# Capability-Aware Workflow Overlays — Design Spec

**Status:** Design + implementation for this fork (issue #6).
**Product:** Supersuit (`jamesthomasonjr/superpowers`).
**Depends on:** Configurable workflow graph (#4); pairs with deterministic
run/exec actions (#5).
**Enables:** Canvas-vs-companion selection (#9), harness workspace management (#7).

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

## Design decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Optional `when.capabilities: […]` on transitions and skill registry entries. | Matches issue shape; progressive enhancement without new files. |
| 2 | A clause matches iff **every** listed capability is in the active set (AND). | Predictable; OR can be expressed as two transitions. |
| 3 | Active capabilities = CLI `--capabilities` ∪ `SUPERPOWERS_CAPABILITIES` env ∪ light auto-detect. | Hooks/agents can pass what they know; humans can override. |
| 4 | Auto-detect only `session-inject` when SessionStart-like env is present. | Conservative; avoid false Canvas/worktree claims. |
| 5 | Duplicate `(from, on)` allowed when `when` signatures differ. | Baseline + enhanced edge can coexist. |
| 6 | At resolve, among matching candidates for `(from, on)`, prefer the most specific `when` (largest capability set); error if tie. | Deterministic progressive enhancement. |
| 7 | Merge: ungated overlay transitions keep replace-by-`from`; **gated** overlay transitions are **appended** and never drop baseline edges. | Lets overlays add enhancement without re-listing the whole `from` node. |
| 8 | Emit resolved transitions/skills with `when` stripped; include `capabilities` list on the artifact. | Agents see a clean host-specific map. |
| 9 | Schema stays `version: 1` (additive). | Same as #5. |

## Capability tokens

| Token | Meaning |
|-------|---------|
| `session-inject` | Host injects bootstrap / workflow map at session start. |
| `native-worktree` | Host owns worktree / workspace creation. |
| `subagents` | Host supports subagent dispatch. |
| `exec-hook` | Host can run deterministic workflow actions without the chat model mediating. |
| `native-canvas` | Host provides a native visual surface (e.g. Cursor Canvas). |

Unknown tokens in `when` are allowed (forward-compatible) but will not match until advertised.

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

## CLI / SessionStart

```bash
./scripts/resolve-workflow \
  --plugin-root "$PWD" \
  --project-root "$PWD" \
  --user-home "$HOME" \
  --capabilities session-inject,exec-hook
```

Env: `SUPERPOWERS_CAPABILITIES=session-inject,exec-hook` (comma-separated).

SessionStart passes detected `session-inject` (when hook env is present) plus any env override into `resolve-workflow`.

## Testing

- Merge appends gated transitions without dropping baseline `from` edges.
- Resolve with/without capabilities selects the correct `(from, on)` target.
- Skill registry entries with unsatisfied `when` are omitted from resolved JSON.
- Ambiguous equally-specific matches fail validation/resolve.
- SessionStart still injects a map; capabilities appear in resolved JSON.

## Success criteria

- Capable hosts can opt into enhanced edges without breaking weaker hosts.
- Zero-config default graph unchanged.
- No third-party dependencies.

## Alternatives considered

| Approach | Why not |
|----------|---------|
| Per-harness full skill copies | Drift-prone. |
| Always weakest common denominator | Leaves enhancement on the table. |
| Runtime external orchestrator only | Stronger enforcement, higher cost. |
| Product-name switches only | Does not scale across forks/hosts. |
