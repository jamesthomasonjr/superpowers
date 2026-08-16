"""Workflow graph merge, validation, and resolution."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from workflow_yaml import YAMLError, load_yaml


class WorkflowResolveError(Exception):
    """Raised when workflow configuration cannot be resolved."""


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
        for skill_id, entry in overlay["skills"].items():
            if entry is None:
                result["skills"][skill_id] = {}
            elif isinstance(entry, dict):
                result["skills"][skill_id] = dict(entry)
            else:
                result["skills"][skill_id] = entry

    if "entries" in overlay:
        for key, value in overlay["entries"].items():
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
) -> list[str]:
    """Validate a merged workflow document. Empty list means valid."""
    errors: list[str] = []

    version = doc.get("version")
    if version != 1:
        errors.append(f"unsupported version: {version!r}")

    skills = doc.get("skills") or {}
    if not isinstance(skills, dict):
        errors.append("skills must be a mapping")
        skills = {}

    known_ids = bundled_skills | set(skills.keys())

    for skill_id, entry in skills.items():
        if entry is None:
            entry = {}
        if not isinstance(entry, dict):
            errors.append(f"skills.{skill_id}: must be a mapping")
            continue

        has_skill = "skill" in entry
        has_path = "path" in entry
        if has_skill and has_path:
            errors.append(f"skills.{skill_id}: cannot set both skill and path")

        if has_skill:
            alias = entry["skill"]
            if not isinstance(alias, str) or not alias.strip():
                errors.append(f"skills.{skill_id}.skill: must be a non-empty string")

        if has_path:
            path_value = entry["path"]
            if not isinstance(path_value, str) or not path_value.strip():
                errors.append(f"skills.{skill_id}.path: must be a non-empty string")
                continue
            resolved = _resolve_skill_path(path_value, project_root)
            skill_md = resolved / "SKILL.md"
            if not skill_md.is_file():
                errors.append(
                    f"skills.{skill_id}.path: SKILL.md not found at {resolved}"
                )

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
        to = transition.get("to") if "to" in transition else None

        if not isinstance(from_id, str) or not from_id.strip():
            errors.append(f"transition missing valid from: {transition!r}")
            continue
        if not isinstance(on, str) or not on.strip():
            errors.append(f"transition missing valid on: {transition!r}")
            continue

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
        user_path = user_home / ".superpowers" / "workflow.yaml"
        if user_path.is_file():
            try:
                user_doc = load_yaml(user_path.read_text())
            except YAMLError as exc:
                raise WorkflowResolveError(
                    f"failed to parse user workflow: {exc}"
                ) from exc
            if isinstance(user_doc, dict):
                merged = merge_workflows(merged, user_doc)

        project_path = project_root / ".superpowers" / "workflow.yaml"
        if project_path.is_file():
            try:
                project_doc = load_yaml(project_path.read_text())
            except YAMLError as exc:
                raise WorkflowResolveError(
                    f"failed to parse project workflow: {exc}"
                ) from exc
            if isinstance(project_doc, dict):
                merged = merge_workflows(merged, project_doc)

    bundled_skills = set(discover_known_skills(plugin_root))
    errors = validate_workflow(
        merged,
        project_root=project_root,
        bundled_skills=bundled_skills,
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


if __name__ == "__main__":
    raise SystemExit(main())
