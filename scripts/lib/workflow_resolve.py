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


class WorkflowResolveError(Exception):
    """Raised when workflow configuration cannot be resolved."""


CANONICAL_CONFIG_DIR = ".supersuit"
LEGACY_CONFIG_DIR = ".superpowers"


def overlay_workflow_path(root: Path) -> Path | None:
    """Return workflow.yaml under root, preferring .supersuit/ over .superpowers/."""
    for dirname in (CANONICAL_CONFIG_DIR, LEGACY_CONFIG_DIR):
        candidate = root / dirname / "workflow.yaml"
        if candidate.is_file():
            return candidate
    return None


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
        overlay_froms: set[str] = set()
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
            overlay_froms.add(from_id)
        result["transitions"] = [
            transition
            for transition in result["transitions"]
            if transition.get("from") not in overlay_froms
        ]
        result["transitions"].extend(overlay_transitions)

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

        normalized_skills[skill_id] = normalized

    if not errors:
        doc["skills"] = normalized_skills

    transitions = doc.get("transitions") or []
    if not isinstance(transitions, list):
        errors.append("transitions must be a sequence")
        return errors

    seen: set[tuple[str, str]] = set()
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

        key = (from_id, on)
        if key in seen:
            errors.append(f"duplicate transition: from={from_id!r} on={on!r}")
        seen.add(key)

        if to not in (None, "wait") and to not in known_ids:
            errors.append(f"transition to unknown logical id: {to!r}")

    return errors


def resolve_workflow(
    *,
    plugin_root: Path,
    project_root: Path,
    user_home: Path,
    bundled_only: bool = False,
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
        user_path = overlay_workflow_path(user_home)
        if user_path is not None:
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

        project_path = overlay_workflow_path(project_root)
        if project_path is not None:
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

    return {
        "version": merged["version"],
        "skills": merged.get("skills") or {},
        "entries": merged.get("entries") or {},
        "transitions": merged.get("transitions") or [],
        "ok": True,
    }


def run_workflow_action(
    *,
    action_id: str,
    plugin_root: Path,
    project_root: Path,
    user_home: Path,
    bundled_only: bool = False,
) -> dict[str, Any]:
    """Execute a resolved run/exec registry entry and return outcome JSON fields."""
    resolved = resolve_workflow(
        plugin_root=plugin_root,
        project_root=project_root,
        user_home=user_home,
        bundled_only=bundled_only,
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
        help="User home for ~/.supersuit/workflow.yaml (fallback ~/.superpowers/; default: HOME)",
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
    args = parser.parse_args(argv)

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

    try:
        resolved = resolve_workflow(
            plugin_root=plugin_root,
            project_root=project_root,
            user_home=user_home,
            bundled_only=args.bundled_only,
        )
    except WorkflowResolveError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    output = {
        "version": resolved["version"],
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
    args = parser.parse_args(argv)

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

    try:
        result = run_workflow_action(
            action_id=args.id,
            plugin_root=plugin_root,
            project_root=project_root,
            user_home=user_home,
            bundled_only=args.bundled_only,
        )
    except WorkflowResolveError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2 if args.pretty else None))
    return 0 if result["exit_code"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
