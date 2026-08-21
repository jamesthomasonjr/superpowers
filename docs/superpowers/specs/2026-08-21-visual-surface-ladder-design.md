# Visual-Surface Capability Ladder — Design Spec

**Status:** Design + implementation for this fork (issues #8 and #9).
**Product:** Supersuit (`jeighty/supersuit`).
**Depends on:** Configurable workflow graph (#4); deterministic run/exec
actions (#5 / PR #10); capability-aware overlays (#6 / PR #17);
native-worktree preference (#7 / PR #18). Config dirs are `.supersuit/` /
`~/.supersuit/` with one-release `.superpowers/` read fallback (#16).
**Does not implement:** Auto-exec hooks (#12). Canvas-only installs.

## Problem

`brainstorming` policy is mostly harness-neutral, but `visual-companion.md`
enumerates Claude Code / Codex / Gemini / Copilot launch recipes and tells
the agent to start the HTML server. That couples the skill to brand names
and makes progressive enhancement (a native visual surface such as Cursor
Canvas) hard to express without a `brainstorming.cursor.md` fork.

The portable companion server remains valuable. It is not always the best
host UI. When a host advertises a native surface, brainstorming should
prefer that rung — without hardcoding “always start the HTML server” and
without inferring Canvas from a product name.

## Goals

| Priority | Goal |
|----------|------|
| Primary | One logical `visual-surface` (skill path / registry / detect ladder). Not a per-harness brainstorming skill. |
| Policy | JIT offer, own-message offer, per-question visual vs text stay in `brainstorming/SKILL.md`. User-facing offer is product-agnostic (“visual surface”). |
| Ladder | 1. native visual surface when `native-canvas` is advertised 2. companion-server (portable default) 3. text-only if declined or nothing works. |
| Safety | Do not auto-detect `native-canvas` from product names. Same conservative probe as #6 / #7: only `session-inject` is auto-detected. |
| Compatibility | Zero overlay match and no advertised `native-canvas` keeps the companion server as the portable default. |

## Non-goals

- Auto-exec hooks (#12).
- Canvas-only (breaks non-Cursor harnesses).
- Per-harness `brainstorming.cursor.md` (drift).
- Rewriting brainstorming Red Flags, rationalizations, or “human partner”
  language.
- Renaming `using-superpowers` or `SUPERPOWERS_*` environment variables.
- Inferring `native-canvas` from `CURSOR_PLUGIN_ROOT`, Cursor, Claude Code,
  Codex, Gemini, Copilot, or any other product name.

## Design decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Keep **policy** in `brainstorming/SKILL.md`. Move **mechanics** to `supersuit:visual-surface` + refs. | Same split as issue #8. Offer / per-question rules stay in the process skill. |
| 2 | Keep `workflows/default.yaml` ungated and free of `run` actions. | Existing #5 / #6 / #7 contract. |
| 3 | Ship a **bundled capability overlay** at `workflows/overlays/native-canvas.yaml`. | Same plugin-layer pattern as `native-worktree.yaml`. Advertising `native-canvas` is enough. |
| 4 | Gate the overlay on `when.capabilities: [native-canvas]` only. | `exec-hook` would couple this to #12. A host can own a visual surface without auto-exec. |
| 5 | Do **not** insert `visual-surface` on `brainstorming / approved-*` transitions. | Visual selection is mid-skill (JIT during questions), not a pipeline node after approval. Graph-hijacking would break writing-plans / SDD. |
| 6 | Remap `visual-surface` to `scripts/select-visual-surface` (`run`) when the token matches. Outcomes: `0` native, `10` companion, `20` text. Continue-session (`to: null`) for each. | Path remapping is resolved against `project_root`, so a bundled plugin path breaks `--bundled-only` on a temp project. `run` + plugin `allow` matches #7. |
| 7 | Overlay argv includes `--capabilities native-canvas`. | `run-workflow-action` does not forward CLI capabilities into child argv. The gate already requires the token; the argv makes the child see it. |
| 8 | Without the token, `visual-surface` stays the identity skill (`skills/visual-surface/SKILL.md`) — companion-first ladder. | Portable default. Agent reads the skill; no run. |
| 9 | User-facing offer never names the HTML server or Canvas. Operational chat MAY name the chosen surface once after accept. | Issue #9. |
| 10 | Harness process-lifetime details (`CODEX_CI`, Windows foreground, launch recipes) live in `references/launch-recipes.md` and in launcher auto-detect. | Not in the primary prompt path. |
| 11 | Probe rules unchanged from #6 / #7. | A missing probe yields `[]`; gated overlay stays off. |

## Discarded shapes

| Approach | Why not |
|----------|---------|
| `brainstorming.cursor.md` / per-harness skill forks | Drift; issues #8 / #9 reject this. |
| Canvas-only | Breaks non-Cursor harnesses. Companion stays the portable baseline. |
| Put gated runs in `default.yaml` | Breaks the Superpowers-shaped file. |
| Graph transition after `approved-architectural` | Visual offer is JIT during questions, not after spec approval. |
| Remap `visual-surface` via `path:` to a native-only SKILL.md | `path` is resolved against `project_root`; bundled plugin paths fail `--bundled-only` on empty projects. Two SKILL.md files would also drift. |
| Auto-detect from Cursor / Claude env | Product-name detection; over-claims Canvas the host may not own. |
| Require a user/project overlay to opt in | Advertising the capability would not be enough. |

## Config shape

`workflows/overlays/native-canvas.yaml`:

```yaml
version: 1

skills:
  visual-surface:
    run:
      argv:
        - scripts/select-visual-surface
        - --capabilities
        - native-canvas
      allow:
        - plugin
      outcomes:
        0: native
        10: companion
        20: text
    when:
      capabilities:
        - native-canvas

transitions:
  - from: visual-surface
    on: native
    to: null
    when:
      capabilities:
        - native-canvas
  - from: visual-surface
    on: companion
    to: null
    when:
      capabilities:
        - native-canvas
  - from: visual-surface
    on: text
    to: null
    when:
      capabilities:
        - native-canvas
```

Without `native-canvas`, resolve keeps identity `visual-surface` and the
bundled `approved-architectural → writing-plans` edge. With it, the gated
run and continue-session edges win (most-specific `when`). `when` is
stripped from resolved JSON.

## How to advertise `native-canvas`

Not probed. Product name is not evidence. Set one of:

```bash
export SUPERPOWERS_CAPABILITIES=native-canvas
# and/or
./scripts/resolve-workflow --plugin-root "$PWD" --project-root "$PWD" \
  --user-home "$HOME" --capabilities native-canvas
```

SessionStart already honors `SUPERPOWERS_CAPABILITIES` and passes
`--detect-capabilities`. After inject, forward the map's `capabilities`
list into `run-workflow-action --id visual-surface --capabilities …` so the
advertised token cannot drop (same round-trip as #6 / #7).

## `scripts/select-visual-surface`

Deterministic ladder (same capability union as resolve: detect ∪
`SUPERPOWERS_CAPABILITIES` ∪ `--capabilities`). Detect never invents
`native-canvas`.

| Condition | `surface` | Exit |
|-----------|-----------|------|
| `--accepted no` | `text` | 20 |
| `native-canvas` advertised and `--available` is not `no` | `native` | 0 |
| `native-canvas` advertised and `--available no` | `companion` | 10 |
| No `native-canvas` and `--available` is not `no` | `companion` | 10 |
| No `native-canvas` and `--available no` | `text` | 20 |

Prints `{"surface":"…"}` on stdout.

## Testing

- Advertised `native-canvas` + accepted → native.
- No advertisement + accepted → companion.
- Declined → text. Native unavailable → companion. Nothing available → text.
- Cursor / Claude / Copilot env and product-name `--capabilities` never
  select native.
- Resolver: missing token / missing probe / Cursor env alone keep identity
  `visual-surface` (no run). Advertised token remaps to the select run;
  `when` stripped; architectural edge unchanged.
- Two-call: SessionStart-style resolve then `run-workflow-action --id`
  with forwarded capabilities executes native; without forwarding, detect
  alone does not invent a run.
- Same-signature project overlay can replace the script argv.
- Brainstorming offer does not name the HTML server or Canvas.

## Success criteria

- Capable hosts that advertise `native-canvas` get the native visual
  surface after the user accepts the offer.
- Everyone else keeps the companion server as the portable default.
- Declined or unavailable is text-only.
- No third-party dependencies. No exec-hook. No per-harness brainstorming.
