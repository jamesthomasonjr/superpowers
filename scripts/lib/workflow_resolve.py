"""Workflow graph merge, validation, and resolution."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

from workflow_yaml import YAMLError, load_yaml

ALLOWED_RUN_ROOTS = frozenset({"plugin", "project"})
DEFAULT_RUN_OUTCOMES: dict[str, str] = {"0": "complete", "nonzero": "failed"}
KNOWN_CAPABILITIES = frozenset(
    {
        "session-inject",
        "native-worktree",
        "subagents",
        "exec-hook",
        "native-canvas",
    }
)


class WorkflowResolveError(Exception):
    """Raised when workflow configuration cannot be resolved."""


def parse_capabilities(value: str | list[str] | None) -> list[str]:
    """Parse capability tokens from CLI/env list forms into a de-duplicated list."""
    if value is None:
        return []
    if isinstance(value, str):
        parts = [part.strip() for part in value.split(",")]
    else:
        parts = [str(part).strip() for part in value]
    result: list[str] = []
    for part in parts:
        if not part:
            continue
        if part not in result:
            result.append(part)
    return result


def detect_capabilities(environ: dict[str, str] | None = None) -> list[str]:
    """Conservative auto-detect of host capabilities from environment."""
    env = environ if environ is not None else os.environ
    caps: list[str] = []
    if (
        env.get("CURSOR_PLUGIN_ROOT")
        or env.get("CLAUDE_PLUGIN_ROOT")
        or env.get("COPILOT_CLI")
    ):
        caps.append("session-inject")
    return caps


def merge_capability_sets(*groups: list[str]) -> list[str]:
    """Merge capability lists preserving first-seen order."""
    merged: list[str] = []
    for group in groups:
        for item in group:
            if item not in merged:
                merged.append(item)
    return merged


def _when_capability_set(when: Any) -> frozenset[str] | None:
    """Return required capabilities frozenset, empty frozenset for when:{}, or None if absent."""
    if when is None:
        return None
    if not isinstance(when, dict):
        raise WorkflowResolveError(f"when must be a mapping, got {type(when).__name__}")
    if "capabilities" not in when:
        raise WorkflowResolveError("when.capabilities is required when when is set")
    caps = when["capabilities"]
    if not isinstance(caps, list) or not caps:
        raise WorkflowResolveError("when.capabilities must be a non-empty list")
    normalized: list[str] = []
    for item in caps:
        if not isinstance(item, str) or not item.strip():
            raise WorkflowResolveError(
                "when.capabilities entries must be non-empty strings"
            )
        if item not in normalized:
            normalized.append(item)
    return frozenset(normalized)


def _transition_has_when(transition: dict[str, Any]) -> bool:
    return "when" in transition and transition.get("when") is not None


def when_satisfied(when: Any, active: set[str]) -> bool:
    """Return True if when is absent or all required capabilities are active."""
    required = _when_capability_set(when) if when is not None else None
    if required is None:
        return True
    return required.issubset(active)

def discover_known_skills(plugin_root: Path) -> list[str]:
    """Return bundled skill directory names that contain SKILL.md."""
    skills_dir = plugin_root / "skills"
    if not skills_dir.is_dir():
        return []
    return sorted(
        path.parent.name
        for path in skills_dir.glob("*/SKILL.md")
        if path.is_file()
    )


_PLUGIN_ROOT = Path(__file__).resolve().parents[2]
KNOWN_SKILLS: list[str] = discover_known_skills(_PLUGIN_ROOT)


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def normalize_skill_entry(entry: Any) -> dict[str, Any]:
    """Normalize a skills registry entry; map exec → run."""
    if entry is None:
        return {}
    if not isinstance(entry, dict):
        raise WorkflowResolveError(
            f"skill entry must be a mapping, got {type(entry).__name__}"
        )
    normalized = dict(entry)
    if "exec" in normalized:
        if "run" in normalized:
            raise WorkflowResolveError("skill entry cannot set both run and exec")
        normalized["run"] = normalized.pop("exec")
    return normalized


def _normalize_run_block(run: Any, *, skill_id: str) -> dict[str, Any]:
    if not isinstance(run, dict):
        raise WorkflowResolveError(
            f"skills.{skill_id}.run: must be a mapping, got {type(run).__name__}"
        )
    if "argv" not in run:
        raise WorkflowResolveError(f"skills.{skill_id}.run: missing argv")
    argv = run["argv"]
    if not isinstance(argv, list) or not argv:
        raise WorkflowResolveError(
            f"skills.{skill_id}.run.argv: must be a non-empty list"
        )
    if not all(isinstance(item, str) and item.strip() for item in argv):
        raise WorkflowResolveError(
            f"skills.{skill_id}.run.argv: every item must be a non-empty string"
        )

    allow = run.get("allow", ["plugin", "project"])
    if not isinstance(allow, list) or not allow:
        raise WorkflowResolveError(
            f"skills.{skill_id}.run.allow: must be a non-empty list"
        )
    allow_norm: list[str] = []
    for item in allow:
        if not isinstance(item, str) or item not in ALLOWED_RUN_ROOTS:
            raise WorkflowResolveError(
                f"skills.{skill_id}.run.allow: entries must be 'plugin' or 'project'"
            )
        if item not in allow_norm:
            allow_norm.append(item)

    cwd = run.get("cwd", "project")
    if cwd not in ("project", "plugin"):
        raise WorkflowResolveError(
            f"skills.{skill_id}.run.cwd: must be 'project' or 'plugin'"
        )

    outcomes_raw = run.get("outcomes", DEFAULT_RUN_OUTCOMES)
    if not isinstance(outcomes_raw, dict) or not outcomes_raw:
        raise WorkflowResolveError(
            f"skills.{skill_id}.run.outcomes: must be a non-empty mapping"
        )
    outcomes: dict[str, str] = {}
    for key, value in outcomes_raw.items():
        key_str = str(key)
        if not isinstance(value, str) or not value.strip():
            raise WorkflowResolveError(
                f"skills.{skill_id}.run.outcomes.{key_str}: must be a non-empty string"
            )
        if key_str != "nonzero" and not key_str.isdigit() and not (
            key_str.startswith("-") and key_str[1:].isdigit()
        ):
            raise WorkflowResolveError(
                f"skills.{skill_id}.run.outcomes: keys must be exit codes or 'nonzero'"
            )
        outcomes[key_str] = value

    return {
        "argv": list(argv),
        "allow": allow_norm,
        "cwd": cwd,
        "outcomes": outcomes,
    }


def resolve_run_program(
    program: str,
    *,
    plugin_root: Path,
    project_root: Path,
    allow: list[str],
) -> Path:
    """Resolve argv[0] to an absolute path under an allowed root."""
    expanded = Path(os.path.expanduser(program))
    candidates: list[Path] = []
    if expanded.is_absolute():
        candidates.append(expanded)
    else:
        if "project" in allow:
            candidates.append(project_root / expanded)
        if "plugin" in allow:
            candidates.append(plugin_root / expanded)

    for candidate in candidates:
        resolved = candidate.resolve()
        allowed = False
        if "project" in allow and _is_relative_to(resolved, project_root):
            allowed = True
        if "plugin" in allow and _is_relative_to(resolved, plugin_root):
            allowed = True
        if not allowed:
            continue
        if resolved.is_file():
            return resolved

    raise WorkflowResolveError(
        f"run program not found under allow roots {allow}: {program}"
    )


def outcome_for_exit_code(outcomes: dict[str, str], exit_code: int) -> str:
    """Map a process exit code to a workflow outcome string."""
    key = str(exit_code)
    if key in outcomes:
        return outcomes[key]
    if exit_code != 0 and "nonzero" in outcomes:
        return outcomes["nonzero"]
    return "failed"


def merge_workflows(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    """Merge overlay onto base using replace-by-logical-id and replace-by-from rules."""
    result: dict[str, Any] = {
        "version": base.get("version", 1),
        "skills": dict(base.get("skills") or {}),
        "entries": dict(base.get("entries") or {}),
        "transitions": list(base.get("transitions") or []),
    }

    if "version" in overlay:
        result["version"] = overlay["version"]

    if "skills" in overlay:
        skills_overlay = overlay["skills"]
        if not isinstance(skills_overlay, dict):
            raise WorkflowResolveError(
                f"overlay skills must be a mapping, got {type(skills_overlay).__name__}"
            )
        for skill_id, entry in skills_overlay.items():
            if entry is None:
                result["skills"][skill_id] = {}
            elif isinstance(entry, dict):
                result["skills"][skill_id] = dict(entry)
            else:
                result["skills"][skill_id] = entry

    if "entries" in overlay:
        entries_overlay = overlay["entries"]
        if not isinstance(entries_overlay, dict):
            raise WorkflowResolveError(
                f"overlay entries must be a mapping, got {type(entries_overlay).__name__}"
            )
        for key, value in entries_overlay.items():
            result["entries"][key] = value

    if "transitions" in overlay:
        overlay_transitions = overlay["transitions"]
        if not isinstance(overlay_transitions, list):
            raise WorkflowResolveError("overlay transitions must be a sequence")
        ungated: list[dict[str, Any]] = []
        gated: list[dict[str, Any]] = []
        for transition in overlay_transitions:
            if not isinstance(transition, dict):
                raise WorkflowResolveError(
                    f"overlay transition must be a mapping: {transition!r}"
                )
            from_id = transition.get("from")
            if not isinstance(from_id, str) or not from_id.strip():
                raise WorkflowResolveError(
                    f"overlay transition missing valid from: {transition!r}"
                )
            if _transition_has_when(transition):
                gated.append(transition)
            else:
                ungated.append(transition)
        overlay_froms = {transition["from"] for transition in ungated}
        result["transitions"] = [
            transition
            for transition in result["transitions"]
            if transition.get("from") not in overlay_froms
        ]
        result["transitions"].extend(ungated)
        result["transitions"].extend(gated)

    return result


def _resolve_skill_path(path_value: str, project_root: Path) -> Path:
    expanded = Path(os.path.expanduser(path_value))
    if expanded.is_absolute():
        return expanded.resolve()
    return (project_root / expanded).resolve()


def validate_workflow(
    doc: dict[str, Any],
    *,
    project_root: Path,
    bundled_skills: set[str],
    plugin_root: Path | None = None,
) -> list[str]:
    """Validate a merged workflow document. Empty list means valid."""
    errors: list[str] = []
    root = plugin_root or project_root

    version = doc.get("version")
    if version != 1:
        errors.append(f"unsupported version: {version!r}")

    skills = doc.get("skills") or {}
    if not isinstance(skills, dict):
        errors.append("skills must be a mapping")
        skills = {}

    known_ids = bundled_skills | set(skills.keys())
    normalized_skills: dict[str, dict[str, Any]] = {}

    for skill_id, entry in skills.items():
        try:
            normalized = normalize_skill_entry(entry)
        except WorkflowResolveError as exc:
            errors.append(f"skills.{skill_id}: {exc}")
            continue

        has_skill = "skill" in normalized
        has_path = "path" in normalized
        has_run = "run" in normalized
        modes = sum(bool(flag) for flag in (has_skill, has_path, has_run))
        if modes > 1:
            errors.append(
                f"skills.{skill_id}: cannot combine skill, path, and run/exec"
            )

        if has_skill:
            alias = normalized["skill"]
            if not isinstance(alias, str) or not alias.strip():
                errors.append(f"skills.{skill_id}.skill: must be a non-empty string")

        if has_path:
            path_value = normalized["path"]
            if not isinstance(path_value, str) or not path_value.strip():
                errors.append(f"skills.{skill_id}.path: must be a non-empty string")
            else:
                resolved = _resolve_skill_path(path_value, project_root)
                skill_md = resolved / "SKILL.md"
                if not skill_md.is_file():
                    errors.append(
                        f"skills.{skill_id}.path: SKILL.md not found at {resolved}"
                    )

        if has_run:
            try:
                run_block = _normalize_run_block(normalized["run"], skill_id=skill_id)
                resolve_run_program(
                    run_block["argv"][0],
                    plugin_root=root,
                    project_root=project_root,
                    allow=run_block["allow"],
                )
                normalized["run"] = run_block
            except WorkflowResolveError as exc:
                errors.append(str(exc))

        if "when" in normalized and normalized["when"] is not None:
            try:
                _when_capability_set(normalized["when"])
            except WorkflowResolveError as exc:
                errors.append(f"skills.{skill_id}: {exc}")

        normalized_skills[skill_id] = normalized

    if not errors:
        doc["skills"] = normalized_skills

    transitions = doc.get("transitions") or []
    if not isinstance(transitions, list):
        errors.append("transitions must be a sequence")
        return errors

    seen: set[tuple[str, str, frozenset[str] | None]] = set()
    for transition in transitions:
        if not isinstance(transition, dict):
            errors.append("transition entries must be mappings")
            continue

        from_id = transition.get("from")
        on = transition.get("on")

        if not isinstance(from_id, str) or not from_id.strip():
            errors.append(f"transition missing valid from: {transition!r}")
            continue
        if not isinstance(on, str) or not on.strip():
            errors.append(f"transition missing valid on: {transition!r}")
            continue
        if "to" not in transition:
            errors.append(f"transition missing to: {transition!r}")
            continue

        to = transition.get("to")

        when_sig: frozenset[str] | None
        if "when" in transition and transition.get("when") is not None:
            try:
                when_sig = _when_capability_set(transition.get("when"))
            except WorkflowResolveError as exc:
                errors.append(f"transition from={from_id!r} on={on!r}: {exc}")
                continue
        else:
            when_sig = None

        key = (from_id, on, when_sig)
        if key in seen:
            errors.append(
                f"duplicate transition: from={from_id!r} on={on!r} when={when_sig!r}"
            )
        seen.add(key)

        if to not in (None, "wait") and to not in known_ids:
            errors.append(f"transition to unknown logical id: {to!r}")

    return errors


def _strip_when(entry: dict[str, Any]) -> dict[str, Any]:
    cleaned = dict(entry)
    cleaned.pop("when", None)
    return cleaned


def apply_capabilities(
    doc: dict[str, Any],
    *,
    capabilities: list[str],
    bundled_skills: set[str],
) -> dict[str, Any]:
    """Filter merged workflow to the active capability set and strip when clauses."""
    active = set(capabilities)
    skills_in = doc.get("skills") or {}
    skills_out: dict[str, Any] = {}
    for skill_id, entry in skills_in.items():
        if not isinstance(entry, dict):
            continue
        when = entry.get("when")
        try:
            if not when_satisfied(when, active):
                if skill_id in bundled_skills:
                    skills_out[skill_id] = {}
                continue
        except WorkflowResolveError as exc:
            raise WorkflowResolveError(f"skills.{skill_id}: {exc}") from exc
        skills_out[skill_id] = _strip_when(entry)

    # Group matching transitions by (from, on), prefer most specific when.
    grouped: dict[tuple[str, str], list[tuple[frozenset[str] | None, dict[str, Any]]]] = {}
    for transition in doc.get("transitions") or []:
        if not isinstance(transition, dict):
            continue
        when = transition.get("when")
        try:
            if not when_satisfied(when, active):
                continue
            required = _when_capability_set(when) if when is not None else None
        except WorkflowResolveError as exc:
            raise WorkflowResolveError(str(exc)) from exc
        from_id = transition["from"]
        on = transition["on"]
        grouped.setdefault((from_id, on), []).append((required, transition))

    transitions_out: list[dict[str, Any]] = []
    for (from_id, on), candidates in grouped.items():
        if len(candidates) == 1:
            transitions_out.append(_strip_when(candidates[0][1]))
            continue
        # Prefer gated (non-None) with the largest requirement set.
        gated = [item for item in candidates if item[0] is not None]
        pool = gated if gated else candidates
        max_size = max(len(item[0] or ()) for item in pool)
        best = [item for item in pool if len(item[0] or ()) == max_size]
        if len(best) != 1:
            raise WorkflowResolveError(
                f"ambiguous transitions for from={from_id!r} on={on!r} "
                f"with capabilities {sorted(active)}"
            )
        transitions_out.append(_strip_when(best[0][1]))

    known_ids = bundled_skills | set(skills_out.keys())
    for transition in transitions_out:
        to = transition.get("to")
        if to not in (None, "wait") and to not in known_ids:
            raise WorkflowResolveError(
                f"capability filter left transition to unknown logical id: {to!r}"
            )

    return {
        "version": doc.get("version", 1),
        "capabilities": list(capabilities),
        "skills": skills_out,
        "entries": dict(doc.get("entries") or {}),
        "transitions": transitions_out,
        "ok": True,
    }


def resolve_workflow(
    *,
    plugin_root: Path,
    project_root: Path,
    user_home: Path,
    bundled_only: bool = False,
    capabilities: list[str] | None = None,
) -> dict[str, Any]:
    """Load, merge, validate, and return the resolved workflow graph."""
    default_path = plugin_root / "workflows" / "default.yaml"
    try:
        merged = load_yaml(default_path.read_text())
    except OSError as exc:
        raise WorkflowResolveError(f"failed to read bundled workflow: {exc}") from exc
    except YAMLError as exc:
        raise WorkflowResolveError(f"failed to parse bundled workflow: {exc}") from exc

    if not isinstance(merged, dict):
        raise WorkflowResolveError("bundled workflow must be a mapping")

    if not bundled_only:
        user_path = user_home / ".superpowers" / "workflow.yaml"
        if user_path.is_file():
            try:
                user_doc = load_yaml(user_path.read_text())
            except OSError as exc:
                raise WorkflowResolveError(
                    f"failed to read user workflow: {exc}"
                ) from exc
            except YAMLError as exc:
                raise WorkflowResolveError(
                    f"failed to parse user workflow: {exc}"
                ) from exc
            if not isinstance(user_doc, dict):
                raise WorkflowResolveError(
                    f"user workflow must be a mapping, got {type(user_doc).__name__}"
                )
            merged = merge_workflows(merged, user_doc)

        project_path = project_root / ".superpowers" / "workflow.yaml"
        if project_path.is_file():
            try:
                project_doc = load_yaml(project_path.read_text())
            except OSError as exc:
                raise WorkflowResolveError(
                    f"failed to read project workflow: {exc}"
                ) from exc
            except YAMLError as exc:
                raise WorkflowResolveError(
                    f"failed to parse project workflow: {exc}"
                ) from exc
            if not isinstance(project_doc, dict):
                raise WorkflowResolveError(
                    f"project workflow must be a mapping, got {type(project_doc).__name__}"
                )
            merged = merge_workflows(merged, project_doc)

    bundled_skills = set(discover_known_skills(plugin_root))
    errors = validate_workflow(
        merged,
        project_root=project_root,
        bundled_skills=bundled_skills,
        plugin_root=plugin_root,
    )
    if errors:
        raise WorkflowResolveError("; ".join(errors))

    active_caps = list(capabilities or [])
    return apply_capabilities(
        merged,
        capabilities=active_caps,
        bundled_skills=bundled_skills,
    )


def run_workflow_action(
    *,
    action_id: str,
    plugin_root: Path,
    project_root: Path,
    user_home: Path,
    bundled_only: bool = False,
    capabilities: list[str] | None = None,
) -> dict[str, Any]:
    """Execute a resolved run/exec registry entry and return outcome JSON fields."""
    resolved = resolve_workflow(
        plugin_root=plugin_root,
        project_root=project_root,
        user_home=user_home,
        bundled_only=bundled_only,
        capabilities=capabilities,
    )
    skills = resolved.get("skills") or {}
    if action_id not in skills:
        raise WorkflowResolveError(f"unknown logical id: {action_id}")

    try:
        entry = normalize_skill_entry(skills[action_id])
    except WorkflowResolveError as exc:
        raise WorkflowResolveError(f"skills.{action_id}: {exc}") from exc

    if "run" not in entry:
        raise WorkflowResolveError(
            f"logical id {action_id!r} is not a run/exec action"
        )

    run_block = _normalize_run_block(entry["run"], skill_id=action_id)
    program = resolve_run_program(
        run_block["argv"][0],
        plugin_root=plugin_root,
        project_root=project_root,
        allow=run_block["allow"],
    )
    argv = [str(program), *run_block["argv"][1:]]
    cwd = plugin_root if run_block["cwd"] == "plugin" else project_root

    # Capture child streams so they cannot corrupt the JSON result on stdout.
    completed = subprocess.run(
        argv,
        cwd=str(cwd),
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.stdout:
        sys.stderr.write(completed.stdout)
        if not completed.stdout.endswith("\n"):
            sys.stderr.write("\n")
    if completed.stderr:
        sys.stderr.write(completed.stderr)
        if not completed.stderr.endswith("\n"):
            sys.stderr.write("\n")
    exit_code = int(completed.returncode)
    outcome = outcome_for_exit_code(run_block["outcomes"], exit_code)
    return {
        "id": action_id,
        "outcome": outcome,
        "exit_code": exit_code,
        "argv": argv,
        "cwd": str(cwd.resolve()),
    }


def _cli_paths(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    script_dir = Path(__file__).resolve().parent
    default_plugin_root = script_dir.parent.parent
    plugin_root = Path(
        args.plugin_root
        or os.environ.get("SUPERPOWERS_PLUGIN_ROOT", str(default_plugin_root))
    )
    project_root = Path(args.project_root or os.getcwd())
    user_home = Path(
        args.user_home or os.environ.get("HOME", os.path.expanduser("~"))
    )
    return plugin_root, project_root, user_home


def _cli_capabilities(args: argparse.Namespace) -> list[str]:
    from_cli = parse_capabilities(getattr(args, "capabilities", None))
    from_env = parse_capabilities(os.environ.get("SUPERPOWERS_CAPABILITIES"))
    detected = detect_capabilities() if getattr(args, "detect_capabilities", False) else []
    return merge_capability_sets(detected, from_env, from_cli)


def main(argv: list[str] | None = None) -> int:
    """Resolve workflow config and print JSON to stdout."""
    parser = argparse.ArgumentParser(
        description="Resolve layered workflow configuration to JSON."
    )
    parser.add_argument(
        "--plugin-root",
        help="Superpowers plugin root (default: SUPERPOWERS_PLUGIN_ROOT or script location)",
    )
    parser.add_argument(
        "--project-root",
        help="Project root for overlay and path resolution (default: cwd)",
    )
    parser.add_argument(
        "--user-home",
        help="User home for ~/.superpowers/workflow.yaml (default: HOME)",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON output",
    )
    parser.add_argument(
        "--bundled-only",
        action="store_true",
        help="Skip user and project overlays; resolve bundled defaults only",
    )
    parser.add_argument(
        "--capabilities",
        help="Comma-separated host capabilities (also reads SUPERPOWERS_CAPABILITIES)",
    )
    parser.add_argument(
        "--detect-capabilities",
        action="store_true",
        help="Include conservative auto-detected capabilities from the environment",
    )
    args = parser.parse_args(argv)
    plugin_root, project_root, user_home = _cli_paths(args)
    capabilities = _cli_capabilities(args)

    try:
        resolved = resolve_workflow(
            plugin_root=plugin_root,
            project_root=project_root,
            user_home=user_home,
            bundled_only=args.bundled_only,
            capabilities=capabilities,
        )
    except WorkflowResolveError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    output = {
        "version": resolved["version"],
        "capabilities": resolved.get("capabilities") or [],
        "skills": resolved["skills"],
        "entries": resolved["entries"],
        "transitions": resolved["transitions"],
    }
    print(json.dumps(output, indent=2 if args.pretty else None))
    return 0


def run_action_main(argv: list[str] | None = None) -> int:
    """CLI entry for executing a workflow run/exec action."""
    parser = argparse.ArgumentParser(
        description="Execute a deterministic workflow run/exec action by logical id."
    )
    parser.add_argument(
        "--id",
        required=True,
        help="Logical id of the run/exec registry entry",
    )
    parser.add_argument(
        "--plugin-root",
        help="Plugin root (default: SUPERPOWERS_PLUGIN_ROOT or repository root)",
    )
    parser.add_argument(
        "--project-root",
        help="Project root (default: cwd)",
    )
    parser.add_argument(
        "--user-home",
        help="User home for overlays (default: HOME)",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON output",
    )
    parser.add_argument(
        "--bundled-only",
        action="store_true",
        help="Skip user and project overlays",
    )
    parser.add_argument(
        "--capabilities",
        help="Comma-separated host capabilities (also reads SUPERPOWERS_CAPABILITIES)",
    )
    parser.add_argument(
        "--detect-capabilities",
        action="store_true",
        help="Include conservative auto-detected capabilities from the environment",
    )
    args = parser.parse_args(argv)
    plugin_root, project_root, user_home = _cli_paths(args)
    capabilities = _cli_capabilities(args)

    try:
        result = run_workflow_action(
            action_id=args.id,
            plugin_root=plugin_root,
            project_root=project_root,
            user_home=user_home,
            bundled_only=args.bundled_only,
            capabilities=capabilities,
        )
    except WorkflowResolveError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2 if args.pretty else None))
    return 0 if result["exit_code"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
