# Supersuit

**Supersuit** is a fork of [Superpowers](https://github.com/obra/superpowers): the same composable skills and coding-agent workflow, with an optional **configurable workflow graph** so you can rewire handoffs or replace individual skills without forking skill prose.

With no overrides, behavior matches Superpowers. Add a user or project workflow file only when you want something different.

> **Name note:** Unrelated to Farama Foundation’s deprecated RL library also called SuperSuit. This project is for coding-agent skills and workflows.

## Table of Contents

- [What is Supersuit?](#what-is-supersuit)
- [Identity model (what changes vs what stays)](#identity-model-what-changes-vs-what-stays)
- [Relationship to Superpowers](#relationship-to-superpowers)
- [How it works](#how-it-works)
- [Getting Started](#installation)
  - [Claude Code](#claude-code)
  - [Antigravity](#antigravity)
  - [Codex App](#codex-app)
  - [Codex CLI](#codex-cli)
  - [Cursor](#cursor)
  - [Devin CLI](#devin-cli)
  - [Factory Droid](#factory-droid)
  - [Gemini CLI](#gemini-cli)
  - [GitHub Copilot CLI](#github-copilot-cli)
  - [Grok Build CLI](#grok-build-cli)
  - [Kimi Code](#kimi-code)
  - [OpenCode](#opencode)
  - [Pi](#pi)
  - [Hermes Agent](#hermes-agent)
- [The Basic Workflow](#the-basic-workflow)
- [Customizing the workflow](#customizing-the-workflow)
- [Upstream & community](#upstream--community)
- [What's Inside](#whats-inside)
- [Philosophy](#philosophy)
- [Contributing](#contributing)
- [Updating](#updating)
- [License](#license)
- [Visual companion telemetry](#visual-companion-telemetry)

## What is Supersuit?

Supersuit keeps Superpowers’ methodology — brainstorm before coding, plan in detail, TDD, systematic debugging, subagent-driven execution, finish the branch — and makes the **pipeline** data-driven:

- Skills emit stable **outcomes** instead of hard-coding the next skill.
- A **workflow map** decides what runs next (`to: <skill>`, `null`, or `wait`).
- You can **alias or path-override** individual skills by logical id.
- Config layers: bundled defaults → `~/.superpowers/workflow.yaml` → `.superpowers/workflow.yaml`.

## Identity model (what changes vs what stays)

Keeping the install id as `superpowers` while shipping a fork is confusing for users and awkward toward upstream. Supersuit uses a **split identity**:

| Layer | Choice | Why |
|-------|--------|-----|
| Plugin / package id | **`supersuit`** | Distinct install; can sit beside docs about Superpowers without impersonating the upstream plugin |
| Author / maintainer | **This fork’s maintainer** | Upstream author credited in descriptions; manifests must not claim to be Jesse Vincent / obra |
| Display name | **Supersuit** | What humans see in marketplaces |
| Skill namespace | **`supersuit:<skill>`** | Matches plugin id (e.g. `supersuit:brainstorming`) |
| Bootstrap skill folder | `using-superpowers` | Still teaches the Superpowers methodology; invoked as `supersuit:using-superpowers` |
| Config dirs | **`.superpowers/`** / `~/.superpowers/` | Workflow overlays stay compatible with the design already documented; no forced migration |
| Env telemetry flag | `SUPERPOWERS_DISABLE_TELEMETRY` | Inherited from upstream; logo `?v=` is tagged `+supersuit` when enabled |

**Do not enable upstream Superpowers and Supersuit in the same harness profile.** They overlap in skills and will fight over triggers.

## Relationship to Superpowers

| | Superpowers (`obra/superpowers`) | Supersuit (this fork) |
|--|----------------------------------|------------------------|
| Plugin id | `superpowers` | `supersuit` |
| Skills & methodology | Opinionated, proven chain | Same by default |
| Pipeline handoffs | Encoded in skill prose | Resolved workflow map |
| Rewire / replace skills | Edit skill files | Optional YAML overlays |
| Upstream fit | Core product | Fork-specific; may not match maintainer vision |

Contributing the configurable graph **upstream is preferred** when it fits. This fork exists because workflow customization is explicitly outside Superpowers’ acceptance criteria today. See the [design spec](docs/superpowers/specs/2026-08-16-configurable-workflow-graph-design.md).

## How it works

It starts from the moment you fire up your coding agent. As soon as it sees that you're building something, it *doesn't* just jump into trying to write code. Instead, it steps back and asks you what you're really trying to do.

Once it's teased a spec out of the conversation, it shows it to you in chunks short enough to actually read and digest.

After you've signed off on the design, your agent puts together an implementation plan that's clear enough for an enthusiastic junior engineer with poor taste, no judgement, no project context, and an aversion to testing to follow. It emphasizes true red/green TDD, YAGNI (You Aren't Gonna Need It), and DRY.

Next up, once you say "go", it launches a *subagent-driven-development* process, having agents work through each engineering task, inspecting and reviewing their work, and continuing forward. It's not uncommon for your agent to work autonomously for a couple hours at a time without deviating from the plan you put together.

There's a bunch more to it, but that's the core of the system. And because the skills trigger automatically, you don't need to do anything special. Your coding agent just has Supersuit — wearing Superpowers by default.

## Installation

Installation differs by harness. If you use more than one, install Supersuit separately for each one.

Official marketplaces often still ship **upstream** Superpowers. To get **this** fork (configurable workflow map), install from this repository as shown below.

### Claude Code

Install from this repository (not the official marketplace plugin, which is upstream Superpowers):

```bash
# From a local clone, or register this fork as a marketplace / plugin source
# per your Claude Code plugin workflow, pointing at:
#   https://github.com/jamesthomasonjr/superpowers
```

If you only need stock Superpowers without workflow overlays, you can still use the [official Claude plugin marketplace](https://claude.com/plugins/superpowers) or `obra/superpowers-marketplace`.

### Antigravity

Install Supersuit as a plugin from this repository:

```bash
agy plugin install https://github.com/jamesthomasonjr/superpowers
```

Antigravity runs the plugin's session-start hook, so Supersuit is active from
the first message. Reinstall with the same command to update.

### Codex App

Official Codex marketplace listings may install upstream Superpowers. For Supersuit, install or point the plugin at this repository: [https://github.com/jamesthomasonjr/superpowers](https://github.com/jamesthomasonjr/superpowers).

### Codex CLI

Same as Codex App: use this repository when you want Supersuit’s workflow map. Searching marketplace `superpowers` alone may resolve to upstream.

### Cursor

Install from this repository (for example via a git-based or local plugin install pointing at [jamesthomasonjr/superpowers](https://github.com/jamesthomasonjr/superpowers)). Marketplace `/add-plugin superpowers` may install upstream Superpowers instead of this fork.

### Devin CLI

- Install the plugin from this repository:

  ```bash
  devin plugins install jamesthomasonjr/superpowers
  ```

- Update to the latest version with:

  ```bash
  devin plugins update superpowers
  ```

### Factory Droid

- Register the marketplace:

  ```bash
  droid plugin marketplace add https://github.com/jamesthomasonjr/superpowers
  ```

- Install the plugin:

  ```bash
  droid plugin install supersuit@supersuit
  ```

### Gemini CLI

- Install the extension:

  ```bash
  gemini extensions install https://github.com/jamesthomasonjr/superpowers
  ```

- Update later:

  ```bash
  gemini extensions update superpowers
  ```

### GitHub Copilot CLI

Install from this repository / a marketplace entry that points at [jamesthomasonjr/superpowers](https://github.com/jamesthomasonjr/superpowers). The `obra/superpowers-marketplace` entry is upstream Superpowers.

### Grok Build CLI

Official Grok marketplace `superpowers` is likely upstream. For Supersuit, install from [this repository](https://github.com/jamesthomasonjr/superpowers) when your harness supports a git URL.

### Kimi Code

- Install directly from this repository:

  ```text
  /plugins install https://github.com/jamesthomasonjr/superpowers
  ```

- Detailed docs: [docs/README.kimi.md](docs/README.kimi.md)

### OpenCode

OpenCode uses its own plugin install; install Supersuit separately even if you
already use Superpowers in another harness.

- Tell OpenCode:

  ```
  Fetch and follow instructions from https://raw.githubusercontent.com/jamesthomasonjr/superpowers/refs/heads/main/.opencode/INSTALL.md
  ```

- Or add to `opencode.json`:

  ```json
  {
    "plugin": ["supersuit@git+https://github.com/jamesthomasonjr/superpowers.git"]
  }
  ```

- Detailed docs: [docs/README.opencode.md](docs/README.opencode.md)

### Pi

Install Supersuit as a Pi package from this repository:

```bash
pi install git:github.com/jamesthomasonjr/superpowers
```

For local development, run Pi with this checkout loaded as a temporary package:

```bash
pi -e /path/to/superpowers
```

The Pi package loads the skills and a small extension that injects the `using-superpowers` bootstrap at session startup and again after compaction. Pi has native skills, so no compatibility `Skill` tool is required. Subagent and task-list tools remain optional Pi companion packages.

### Hermes Agent

Install Supersuit as a Hermes plugin from this repository:

```bash
hermes plugins install jamesthomasonjr/superpowers --enable
```

Restart any active Hermes sessions after installing. Note: Hermes has no
post-compaction hook, so a very long session that compacts over its first
turn loses the bootstrap — start a fresh session if skills stop triggering.

## The Basic Workflow

1. **brainstorming** - Activates before writing code. Refines rough ideas through questions, explores alternatives, presents design in sections for validation. Saves design document.

2. **using-git-worktrees** - Activates after design approval. Creates isolated workspace on new branch, runs project setup, verifies clean test baseline.

3. **writing-plans** - Activates with approved design. Breaks work into bite-sized tasks (2-5 minutes each). Every task has exact file paths, complete code, verification steps.

4. **subagent-driven-development** or **executing-plans** - Activates with plan. Dispatches fresh subagent per task with two-stage review (spec compliance, then code quality), or executes in batches with human checkpoints.

5. **test-driven-development** - Activates during implementation. Enforces RED-GREEN-REFACTOR: write failing test, watch it fail, write minimal code, watch it pass, commit. Deletes code written before tests.

6. **requesting-code-review** - Activates between tasks. Reviews against plan, reports issues by severity. Critical issues block progress.

7. **finishing-a-development-branch** - Activates when tasks complete. Verifies tests, presents options (merge/PR/keep/discard), cleans up worktree.

**The agent checks for relevant skills before any task.** Mandatory workflows, not suggestions. Pipeline continuations follow the resolved workflow map (see below).

## Customizing the workflow

No config required for stock Superpowers behavior.

To rewire handoffs or replace a skill, add:

- User defaults: `~/.superpowers/workflow.yaml`
- Per-project: `.superpowers/workflow.yaml`

Full reference and examples: [docs/workflow-config.md](docs/workflow-config.md).

Overlays may also declare deterministic **`run` / `exec`** actions (allowlisted argv) for mechanical steps, and **`when.capabilities`** gates for progressive enhancement — see the workflow config docs. The bundled default graph does not include run actions or capability gates.

Inspect the merged map:

```bash
./scripts/resolve-workflow --plugin-root "$PWD" --project-root "$PWD" --user-home "$HOME" --pretty
```

## Upstream & community

Supersuit builds on **Superpowers** by [Jesse Vincent](https://blog.fsck.com) and [Prime Radiant](https://primeradiant.com).

- **This fork (issues & PRs):** https://github.com/jamesthomasonjr/superpowers
- **Upstream Superpowers:** https://github.com/obra/superpowers
- **Upstream Discord:** [Join](https://discord.gg/35wsABTejz) for Superpowers community support
- **Upstream commercial support:** sales@primeradiant.com (Prime Radiant / Superpowers — not this fork)

## What's Inside

### Skills Library

**Testing**
- **test-driven-development** - RED-GREEN-REFACTOR cycle (includes testing anti-patterns reference)

**Debugging**
- **systematic-debugging** - 4-phase root cause process (includes root-cause-tracing, defense-in-depth, condition-based-waiting techniques)
- **verification-before-completion** - Ensure it's actually fixed

**Collaboration**
- **brainstorming** - Socratic design refinement
- **writing-plans** - Detailed implementation plans
- **executing-plans** - Batch execution with checkpoints
- **dispatching-parallel-agents** - Concurrent subagent workflows
- **requesting-code-review** - Pre-review checklist
- **receiving-code-review** - Responding to feedback
- **using-git-worktrees** - Parallel development branches
- **finishing-a-development-branch** - Merge/PR decision workflow
- **subagent-driven-development** - Fast iteration with two-stage review (spec compliance, then code quality)

**Meta**
- **writing-skills** - Create new skills following best practices (includes testing methodology)
- **using-superpowers** - Introduction to the skills system and workflow map rules

**Workflow**
- **`workflows/default.yaml`** - Bundled Superpowers-compatible pipeline graph
- **`scripts/resolve-workflow`** - Merge and validate overlays
- **`scripts/run-workflow-action`** - Execute a deterministic `run`/`exec` registry entry

## Philosophy

- **Test-Driven Development** - Write tests first, always
- **Systematic over ad-hoc** - Process over guessing
- **Complexity reduction** - Simplicity as primary goal
- **Evidence over claims** - Verify before declaring success
- **Defaults first, overrides optional** - Stock chain unless you configure otherwise

Read [the original Superpowers release announcement](https://blog.fsck.com/2025/10/09/superpowers/).

## Contributing

This is a fork. Prefer proposing compatible improvements upstream to [obra/superpowers](https://github.com/obra/superpowers) when they fit core. Fork-specific work (workflow graph, Supersuit docs) lands here.

1. Fork or branch from this repository
2. Prefer the branch that carries active fork work (see open PRs / `cursor/modular-functionality-*`)
3. Create a branch for your change
4. Follow `writing-skills` for skill content changes; keep behavior-shaping edits evidence-backed
5. Open a PR against this fork and describe whether the change is fork-specific or a candidate for upstream

Plugin-infrastructure tests live at `tests/`. Skill-behavior evals for upstream Superpowers use [superpowers-evals](https://github.com/prime-radiant-inc/superpowers-evals/).

See `skills/writing-skills/SKILL.md` for the complete skills guide.

## Updating

Updates are harness-dependent. For git installs, pull or reinstall from [jamesthomasonjr/superpowers](https://github.com/jamesthomasonjr/superpowers).

## License

MIT License - see LICENSE file for details (same as upstream Superpowers).

## Visual companion telemetry

Because skills and plugins don't provide any feedback to creators, upstream Superpowers includes optional visual-companion logo telemetry from Prime Radiant. By default, the Prime Radiant logo on brainstorming's optional visual companion feature is loaded from their website. It includes the version of the plugin in use. **Supersuit appends `+supersuit` to that version** (for example `6.3.0+supersuit`) so Prime Radiant can tell fork traffic from upstream Superpowers. It does not include any details about your project, prompt, or coding agent. It's 100% optional. To disable this, set the environment variable `SUPERPOWERS_DISABLE_TELEMETRY` to any true value. The plugin also honors Claude Code's `DISABLE_TELEMETRY` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` opt-outs.
