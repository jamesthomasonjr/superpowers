---
name: visual-surface
description: Use when the user has accepted a visual surface during brainstorming, or when choosing native canvas versus companion server versus text-only for mockups, diagrams, or visual comparisons
---

# Visual Surface

One logical visual surface for mockups, diagrams, and visual comparisons.
Not a per-harness brainstorming fork. Accepting the surface means it is
available for questions that benefit from seeing; it does not mean every
question goes through it.

**Core principle:** Prefer an advertised native surface. Fall back to the
portable companion server. Use text-only if declined or nothing works.
Never infer a native surface from a product or harness name.

## Capability ladder

Read the resolved workflow map's `capabilities` list (already filtered).
Do **not** re-interpret overlay `when:` clauses. Do **not** treat Cursor,
Claude, Codex, Gemini, Copilot, or `CURSOR_PLUGIN_ROOT` /
`CLAUDE_PLUGIN_ROOT` / `COPILOT_CLI` as evidence of `native-canvas`.

`session-inject` is the only auto-detected capability. Advertise
`native-canvas` the same way as `native-worktree` / `subagents` /
`exec-hook`:

```bash
export SUPERPOWERS_CAPABILITIES=native-canvas
# and/or
./scripts/resolve-workflow --plugin-root "$PWD" --project-root "$PWD" \
  --user-home "$HOME" --capabilities native-canvas
```

If the registry entry has `run`, execute
`run-workflow-action --id visual-surface` and forward the map's
`capabilities` list. Otherwise apply the same ladder with
`scripts/select-visual-surface` (or the table below).

| Rung | When | Then |
|------|------|------|
| 1. native | `native-canvas` is advertised and the surface works | Read [native-canvas.md](native-canvas.md) |
| 2. companion-server | No `native-canvas`, or native unavailable | Read [companion-server.md](companion-server.md) — portable default |
| 3. text-only | User declined, or neither surface works | Stay in chat. Do not offer again unless they raise it. |

After the user accepts, you MAY name the chosen surface once in
operational chat ("I'll use the native visual surface" / "I'll use the
companion server"). The offer itself stays product-agnostic.

## When to use the surface (per question)

Decide per-question, not per-session. The test: **would the user
understand this better by seeing it than reading it?**

**Use the visual surface** when the content itself is visual:

- UI mockups — wireframes, layouts, navigation, component designs
- Architecture diagrams — components, data flow, relationship maps
- Side-by-side visual comparisons
- Design polish — look and feel, spacing, visual hierarchy
- Spatial relationships — state machines, flowcharts, entity maps

**Use text** when the content is text or tabular:

- Requirements and scope
- Conceptual A/B/C choices described in words
- Tradeoff lists and comparison tables
- Technical decisions — API design, data modeling
- Clarifying questions whose answer is words

A question *about* a UI topic is not automatically a visual question.
"What kind of wizard do you want?" is conceptual — use text. "Which of
these wizard layouts feels right?" is visual — use the surface.

## References

- Companion server (portable baseline): [companion-server.md](companion-server.md)
- Native surface: [native-canvas.md](native-canvas.md)
- Harness process lifetime (not the primary path): [references/launch-recipes.md](references/launch-recipes.md)
