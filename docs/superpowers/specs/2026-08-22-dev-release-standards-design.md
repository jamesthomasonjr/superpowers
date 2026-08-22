# Dev / release standards and 0.1.0 versioning — Design Spec

**Status:** Approved design (2026-08-22). Implementation waits on review of this spec.
**Product:** Supersuit (`jeighty/supersuit`).
**Depends on:** Fork stack on `main` through PR #20 (issues #5, #6, #7, #8, #9, #12).
**Follow-up (do not implement here):** [#21](https://github.com/jeighty/supersuit/issues/21) — wider protections (`main` rulesets, close-without-review, eval-or-die, CODEOWNERS).

## Problem

Superpowers works on `dev` and releases from `main`. This fork flipped that: the PR template and `CLAUDE.md` say **MUST target `main`**, marketplace/installs follow `main`, and `.claude-plugin/plugin.json` still says `6.3.0` (inherited Superpowers version).

A leftover `dev` branch exists at `39e4562` (PR #13, 2026-08-18). `main` is at `323094b` (PR #20). `dev` is an ancestor of `main` and is stale.

There is no `.github/workflows/` CI. Plugin tests live under `tests/`; skill evals live under `evals/` and are not CI today.

## Goals

| Priority | Goal |
|----------|------|
| Primary | Feature work lands on `dev`. `main` is the released / marketplace branch. |
| Version | Stop inheriting Superpowers `6.3.0`. First release on `main` is `0.1.0`. |
| Gates | PRs into `dev` need the deterministic `tests/` suite green and a human review. |
| Track | Wider Superpowers-style protections live in #21 and stay unimplemented. |

## Non-goals

- Implementing #21 (rulesets on `main`, close-without-review automation, eval-or-die, CODEOWNERS).
- Changing GitHub **default branch** off `main` (marketplace and install docs stay pinned to released `main`).
- Running `evals/` / Drill / real-LLM sessions in PR CI.
- Restoring Superpowers contributor-pack wording wholesale.
- Shipping `0.1.0` on `main` in the same change that creates the process (release is a later `dev` → `main` PR).

## Design decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Fast-forward existing `dev` to current `main` (`323094b`). Do not recreate or rewrite history. | `dev` already exists and is a strict ancestor. FF is safe. |
| 2 | Keep GitHub default branch = `main`. | Installs and marketplace stay on released code. Agents and humans retarget via docs/template. |
| 3 | Feature PRs **MUST target `dev`**. | Superpowers model, restored. |
| 4 | A release is a PR from `dev` to `main` that ships a versioned plugin. First such release is `0.1.0`. | `main` is not a working branch. |
| 5 | On `dev`, set every declared plugin manifest version to `0.1.0-dev`. Leave `main` at current `6.3.0` until the first release PR rewrites it to `0.1.0`. | Pre-1.0 until this is more than Superpowers-as-a-base. `-dev` makes a checkout of `dev` not look released. |
| 6 | Flip contributor copy: `.github/PULL_REQUEST_TEMPLATE.md`, `CLAUDE.md`, and any other “MUST target `main`” line. | Process follows the branch, not leftover #14 wording. |
| 7 | Add one GitHub Actions workflow on PRs to `dev` (and on `push` to `dev`) that runs the deterministic plugin suites under `tests/` (workflow, hooks, migration, shell-lint, version-bump, and other non-LLM dirs that already have a runner). Skip `evals/`, `tests/claude-code` live-session files, and harness suites that need a real product. | There is no CI today; green `tests/` is the gate we can automate. |
| 8 | Human review is required on PRs to `dev` as process (template + CLAUDE.md). Do not add GitHub required-review / rulesets in this cut. | That is #21. |
| 9 | After this lands, cloud agents start from `dev` and open PRs against `dev`. | Avoids more work landing on `main` by habit. |

## Implementation order

1. Fast-forward `dev` to `main` (`git push origin main:dev` or equivalent FF). No spec or code change on this step.
2. Open the standards PR **against `dev`** (not `main`) with: version `0.1.0-dev` on declared manifests, template/docs retarget, CI workflow, a short note in `docs/testing.md` that PR CI is the deterministic subset.
3. Merge that PR to `dev`.
4. Later, separately: `dev` → `main` release PR that sets versions to `0.1.0`. Not this spec’s first PR.

This spec file may land on `main` first so the design is reviewable before `dev` is live. That one docs PR is the exception. After `dev` exists as current `main`, further work including the standards implementation PR targets `dev`.

## Files (implementation PR, after spec approval)

| Path | Change |
|------|--------|
| `.claude-plugin/plugin.json` and other declared manifests | `version`: `0.1.0-dev` on `dev` |
| `.github/PULL_REQUEST_TEMPLATE.md` | MUST target `dev`; `main` is released |
| `CLAUDE.md` | Same |
| `.github/workflows/*.yml` | New; deterministic `tests/` only |
| `docs/testing.md` | Note PR CI vs evals |
| `docs/superpowers/specs/2026-08-22-dev-release-standards-design.md` | This file |

## Success criteria

- `dev` tip equals `main` tip after the fast-forward, then moves only via PRs targeting `dev`.
- A new feature PR opened against `main` is asked to retarget (template + docs). Marketplace still installs from `main`.
- Checkout of `dev` reports plugin version `0.1.0-dev`.
- A PR to `dev` that breaks `tests/workflow` (or another CI-included suite) fails the new workflow.
- #21 remains open and untouched by the implementation PR.

## Alternatives considered

| Approach | Why not |
|----------|---------|
| Switch GitHub default to `dev` | Marketplace/installs would follow unreleased work. |
| Delete stale `dev` and recreate | Unnecessary; FF is enough. |
| Keep version `6.3.0` until 1.0 | Inherited Superpowers version; JT chose start at `0.1.0`. |
| Put `0.1.0` on `dev` immediately (no `-dev`) | A `dev` checkout would look released. |
| Ship `0.1.0` on `main` in the same PR as the process change | Mixes process bootstrap with a marketplace release. |
| Restore the full Superpowers close/eval pack now | Tracked as #21; not this cut. |
| CI includes `evals/` | Slow, keyed, not PR-shaped; `docs/testing.md` already says they are not CI. |
