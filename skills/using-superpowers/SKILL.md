---
name: using-superpowers
description: Use when starting any conversation - establishes how to find and use skills, requiring skill invocation before ANY response including clarifying questions
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, ignore this skill.
</SUBAGENT-STOP>

<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, you ABSOLUTELY MUST invoke the skill.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

This is not negotiable. You cannot rationalize your way out of this.
</EXTREMELY-IMPORTANT>

## The Rule

**Invoke relevant or requested skills BEFORE any response or action** — including clarifying questions, exploring the codebase, or checking files. If it turns out wrong for the situation, you don't have to use it.

**Before entering plan mode:** if you haven't already brainstormed, invoke the brainstorming skill first.

Then announce "Using [skill] to [purpose]" and follow the skill exactly. If it has a checklist, create a todo per item.

## Workflow map

Superpowers handoffs are owned by a resolved workflow map (bundled defaults,
optional `~/.supersuit/workflow.yaml`, optional `.supersuit/workflow.yaml`).
`.supersuit/` is canonical. Leftover `~/.superpowers/workflow.yaml` and
`.superpowers/workflow.yaml` still load for one release when the canonical
file is absent.

When SessionStart did not inject a `<WORKFLOW_MAP>` block, run
`resolve-workflow` from the plugin (or read its JSON stdout) before the first
skill handoff and whenever overlays may have changed.

Rules:
1. Skills are terminal units — do not invent pipeline handoffs from memory.
2. When a skill finishes, emit its declared outcome, then select `to` from the
   map for `(from=<logical id>, on=<outcome>)`.
3. `to: <id>` — invoke that logical id. Resolve via the map's skills registry:
   `run`/`exec` → `path` → `skill` alias → same name.
4. If the registry entry has `run` (or `exec`), do **not** load a skill. If
   `exec-hook` is in the map's `capabilities`, do **not** invent argv: the
   host executes `hooks/workflow-exec --id <id>` (or `--from` / `--on`) and
   forwards this map's capabilities. SessionStart running is not `exec-hook`.
   Without that token, execute with `run-workflow-action --id <id>` (or an
   equivalent harness exec that uses the same argv/allow rules). The
   executor always re-probes host capabilities (same conservative detect as
   SessionStart) and reads `SUPERPOWERS_CAPABILITIES` / `--capabilities`.
   When the map lists `capabilities`, pass them through: `--capabilities`
   plus those tokens — so advertised tokens cannot drift off
   `session-inject`. Read the JSON `outcome`, then continue the map for
   `(from=<id>, on=<outcome>)`.
   If `native-worktree` is in the map's `capabilities`, `using-git-worktrees`
   and `ensure-worktree` are `run` actions. Do not load the worktree skill
   and do not invent `git worktree` steps — the host owns workspace setup.
   If `native-canvas` is in the map's `capabilities`, `visual-surface` is a
   `run` action after the user accepts the visual-surface offer. Do not infer
   Canvas from the product name. Outcome `native` → read
   `skills/visual-surface/native-canvas.md`; `companion` →
   `companion-server.md`; `text` → stay in chat. Without that token, load
   `supersuit:visual-surface` (companion server is the portable default).
5. `to: null` — no pipeline handoff; continue the session. Description-triggered
   skills (TDD, debugging, verification, etc.) still apply.
6. `to: wait` — stop and ask your human partner what to do next.
7. If the outcome is missing from the map, treat it as `wait`.
8. The injected map is already filtered for this host's **capabilities**. Do not
   re-interpret `when:` clauses from overlays — follow the resolved JSON.
9. User instructions still take precedence over skills and the workflow map.

## Skill Priority

When multiple skills apply, process skills come first — they set the approach, then implementation skills (frontend-design, etc.) carry it out. Brainstorming and systematic-debugging are Superpowers' most common process skills, but the rule holds for any of them.

- "Let's build X" → supersuit:brainstorming first, then implementation skills.
- "Fix this bug" → supersuit:systematic-debugging first, then domain skills.

## Red Flags

These thoughts mean STOP—you're rationalizing:

| Thought | Reality |
|---------|---------|
| "This is just a simple question" | Questions are tasks. Check for skills. |
| "I need more context first" | Skill check comes BEFORE clarifying questions. |
| "Let me explore the codebase first" | Skills tell you HOW to explore. Check first. |
| "I can check git/files quickly" | Files lack conversation context. Check for skills. |
| "Let me gather information first" | Skills tell you HOW to gather information. |
| "This doesn't need a formal skill" | If a skill exists, use it. |
| "I remember this skill" | Skills evolve. Read current version. |
| "This doesn't count as a task" | Action = task. Check for skills. |
| "The skill is overkill" | Simple things become complex. Use it. |
| "I'll just do this one thing first" | Check BEFORE doing anything. |
| "This feels productive" | Undisciplined action wastes time. Skills prevent this. |
| "I know what that means" | Knowing the concept ≠ using the skill. Invoke it. |

## Platform Adaptation

If your harness appears here, read its reference file for special instructions:

- Codex: `references/codex-tools.md`
- Pi: `references/pi-tools.md`
- Antigravity: `references/antigravity-tools.md`
- Hermes Agent: `references/hermes-tools.md`

## User Instructions

User instructions (CLAUDE.md, AGENTS.md, GEMINI.md, etc, direct requests) take precedence over skills, which in turn override default behavior. Only skip skill workflows or instructions when your human partner has explicitly told you to.
