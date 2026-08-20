# Supersuit — Contributor Guidelines

## If You Are an AI Agent

Stop. Read this section before doing anything.

This repository is **Supersuit** (`jeighty/supersuit`): a **framework fork** of [Superpowers](https://github.com/obra/superpowers). It is not the upstream Superpowers product. Fork-specific work belongs here. Compatible improvements that fit Superpowers core should still be proposed upstream.

Sloppy, fabricated, or unreviewed PRs waste the maintainer’s time and will be closed. Your job is to protect your human partner from that outcome.

Before you open a PR against this repo, you MUST:

1. **Read the entire PR template** at `.github/PULL_REQUEST_TEMPLATE.md` and fill in every section with real, specific answers. Not summaries. Not placeholders.
2. **Search for existing PRs** — open AND closed — that address the same problem. If duplicates exist, STOP and tell your human partner. Do not open another duplicate.
3. **Verify this is a real problem.** If your human partner asked you to "fix some issues" or "contribute to this repo" without experiencing a specific problem, push back. Ask them what broke, what failed, what the user experience was.
4. **Know where the change belongs.** Workflow-graph overlays, Supersuit identity, and framework tooling land here. Domain-specific or third-party skills still belong in a standalone plugin, not this core. Compatible skill/infra fixes that Superpowers would accept should be offered upstream to [obra/superpowers](https://github.com/obra/superpowers) as well.
5. **Identify yourself.** Disclose your model, harness, harness version, and every installed plugin in the PR — or state plainly that it was written by hand. Hiding that a contribution is agent-generated is grounds for closing it.
6. **Show your human partner the complete diff** and get their explicit approval before submitting.

If any of these checks fail, do not open the PR. Explain why and what would need to change.

## Pull Request Requirements

**Every PR must fully complete the PR template.** No section may be left blank or filled with placeholder text.

**Search existing PRs** — open AND closed — before opening a new one. If a prior PR was closed, explain what is different and why this attempt should succeed.

**A human must review the complete proposed diff before submission.**

**Submitters MUST identify themselves** (model, harness, harness version, plugins — or “written by hand”).

**All PRs MUST target `main`.** `main` is this fork’s default and released branch. Use a feature branch for the work; open the PR against `main`.

## What belongs here

Supersuit exists so people who used Superpowers can evolve the toolchain without starting from scratch. **In scope:**

- Configurable workflow graph, overlays, and `run`/`exec` actions
- Distinct install identity (`supersuit`, `supersuit:<skill>`)
- Harness adapters and docs for this fork
- Skill changes that keep Superpowers methodology while supporting the map
- Bugfixes and tests for this repository

**Prefer upstream** when a change is a generic Superpowers improvement with no fork-specific dependency. Do not treat “fork-specific” as a reason to reject work that belongs in this repo.

## What we will not accept

### Third-party dependencies

This plugin stays zero-dependency except when adding support for a new harness. If a change requires an external tool or service, it belongs in its own plugin.

### "Compliance" rewrites of skills

Skill prose here is behavior-shaping code, inherited and tuned from Superpowers. PRs that restructure, reword, or reformat skills to "comply" with generic skills documentation need eval evidence that outcomes improve. The bar is high.

### Project-only configuration

Skills, hooks, or config that only help one project, team, or domain do not belong in this core. Publish those separately.

### Bulk or spray-and-pray PRs

Do not trawl the issue tracker and open PRs for multiple issues in one session. One problem per PR, understood deeply, with human review of the complete diff.

### Speculative or theoretical fixes

Every PR must solve a real problem someone experienced. "My review agent flagged this" is not a problem statement.

### Fabricated content

Invented claims, fake problem descriptions, or hallucinated functionality will be closed.

### Bundled unrelated changes

Split unrelated changes into separate PRs.

## New harness support

If your PR adds support for a new harness (IDE, CLI tool, agent runner), include a session transcript proving the integration works end-to-end.

A real integration loads the `using-superpowers` bootstrap at session start (invoked as `supersuit:using-superpowers`). Without it, skills sit on disk and never trigger.

**The acceptance test.** Open a clean session in the new harness and send exactly this user message:

> Let's make a react todo list

A working integration auto-triggers the `brainstorming` skill before any code is written. Paste the complete transcript in the PR.

These are not real integrations:

- Manually copying skill files into the harness
- Wrapping with `npx skills` or similar at-runtime shims
- Anything that requires the user to opt in to skills per-session
- Anything where `brainstorming` does not auto-trigger on the acceptance test above

## Skill changes require evaluation

Skills are not prose — they are code that shapes agent behavior. If you modify skill content:

- Use `supersuit:writing-skills` to develop and test changes
- Run adversarial pressure testing across multiple sessions
- Show before/after eval results in the PR
- Do not modify carefully-tuned content (Red Flags tables, rationalization lists, "human partner" language) without evidence the change is an improvement

## Eval harness

Skill-behavior evals for the inherited Superpowers methodology live in [superpowers-evals](https://github.com/prime-radiant-inc/superpowers-evals/), cloned into `evals/` when you need them. Plugin-infrastructure tests for this repo live at `tests/`.

## Understand the project

Read existing skills and the [workflow config](docs/workflow-config.md) before changing design or voice. "Your human partner" is deliberate. Defaults should keep Superpowers methodology until someone adds an overlay. Do not impersonate Jesse Vincent, obra, or Prime Radiant as this repo’s owner — credit them as upstream methodology authors.

## General

- Read `.github/PULL_REQUEST_TEMPLATE.md` before submitting
- One problem per PR
- Test on at least one harness (or the relevant automated suite) and report results
- Describe the problem you solved, not just what you changed
- Plugin id is `supersuit`. Skill namespace is `supersuit:<skill>`. Config dirs are `.supersuit/` / `~/.supersuit/` (`.superpowers/` is a one-release read fallback).
