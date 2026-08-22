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
    """Conservative host probes. Only claim a capability when evidence is present.

    Product-name env vars are not treated as Canvas, worktree, subagent, or
    exec-hook support. Those must be advertised via ``--capabilities`` or
    ``SUPERPOWERS_CAPABILITIES``.
    """
    env = environ if environ is not None else os.environ
    if (
        env.get("CURSOR_PLUGIN_ROOT")
        or env.get("CLAUDE_PLUGIN_ROOT")
        or env.get("COPILOT_CLI")
    ):
        return ["session-inject"]
    return []


def merge_capability_sets(*groups: list[str]) -> list[str]:
    """Merge capability lists preserving first-seen order."""
    merged: list[str] = []
    for group in groups:
        for item in group:
            if item not in merged:
                merged.append(item)
    return merged


def _when_capability_set(when: Any) -> frozenset[str] | None:
    """Return required capabilities, or None if ``when`` is absent."""
    if when is None:
        return None
    if not isinstance(when, dict):
        raise WorkflowResolveError(
            f"when must be a mapping, got {type(when).__name__}"
        )
    extra = sorted(key for key in when if key != "capabilities")
    if extra:
        raise WorkflowResolveError(
            f"when has unsupported keys: {extra}; only 'capabilities' is allowed"
        )
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


def _entry_has_when(entry: dict[str, Any]) -> bool:
    return "when" in entry and entry.get("when") is not None


def when_satisfied(when: Any, active: set[str]) -> bool:
    """Return True if when is absent or all required capabilities are active."""
    required = _when_capability_set(when)
    if required is None:
        return True
    return required.issubset(active)


def _strip_when(entry: dict[str, Any]) -> dict[str, Any]:
    cleaned = dict(entry)
    cleaned.pop("when", None)
    return cleaned


def _upsert_gated_skill(
    gated: list[dict[str, Any]], skill_id: str, entry: dict[str, Any]
) -> None:
    """Append or replace a gated skill candidate with the same when signature."""
    try:
        signature = _when_capability_set(entry.get("when"))
    except WorkflowResolveError:
        gated.append({"id": skill_id, "entry": dict(entry)})
        return
    incoming = {"id": skill_id, "entry": dict(entry)}
    for index, existing in enumerate(gated):
        if existing.get("id") != skill_id:
            continue
        existing_entry = existing.get("entry")
        if not isinstance(existing_entry, dict):
            continue
        try:
            existing_sig = _when_capability_set(existing_entry.get("when"))
        except WorkflowResolveError:
            continue
        if existing_sig == signature:
            gated[index] = incoming
            return
    gated.append(incoming)


def _pick_most_specific(
    matching: list[tuple[frozenset[str] | None, dict[str, Any]]],
    *,
    label: str,
    active: set[str],
) -> dict[str, Any]:
    """Prefer the matching candidate with the largest when.capabilities set."""
    if len(matching) == 1:
        return matching[0][1]
    gated = [item for item in matching if item[0] is not None]
    pool = gated if gated else matching
    max_size = max(len(item[0] or ()) for item in pool)
    best = [item for item in pool if len(item[0] or ()) == max_size]
    if len(best) != 1:
        raise WorkflowResolveError(
            f"ambiguous {label} with capabilities {sorted(active)}"
        )
    return best[0][1]


CANONICAL_CONFIG_DIR = ".supersuit"
LEGACY_CONFIG_DIR = ".superpowers"


def overlay_workflow_path(root: Path) -> Path | None:
    """Return workflow.yaml under root, preferring .supersuit/ over .superpowers/."""
    for dirname in (CANONICAL_CONFIG_DIR, LEGACY_CONFIG_DIR):
        candidate = root / dirname / "workflow.yaml"
        if candidate.is_file():
            return candidate
    return None


def bundled_overlay_paths(plugin_root: Path) -> list[Path]:
    """Return bundled capability overlays, sorted by filename.

    These are plugin config (always loaded, including ``--bundled-only``),
    not user/project overlays. Files must be ``*.yaml`` or ``*.yml``.
    """
    overlay_dir = plugin_root / "workflows" / "overlays"
    if not overlay_dir.is_dir():
        return []
    return sorted(
        path
        for path in overlay_dir.iterdir()
        if path.is_file() and path.suffix in {".yaml", ".yml"}
    )


def load_workflow_mapping(path: Path, *, label: str) -> dict[str, Any]:
    """Read and parse a workflow YAML mapping, or raise WorkflowResolveError."""
    try:
        doc = load_yaml(path.read_text())
    except OSError as exc:
        raise WorkflowResolveError(f"failed to read {label}: {exc}") from exc
    except YAMLError as exc:
        raise WorkflowResolveError(f"failed to parse {label}: {exc}") from exc
    if not isinstance(doc, dict):
        raise WorkflowResolveError(
            f"{label} must be a mapping, got {type(doc).__name__}"
        )
    return doc


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
    """Merge overlay onto base using replace-by-logical-id and replace-by-from rules.

    Gated overlay entries (``when`` present) are progressive enhancement:
    they accumulate as candidates and do not replace ungated baseline edges
    or registry entries.
    """
    result: dict[str, Any] = {
        "version": base.get("version", 1),
        "skills": dict(base.get("skills") or {}),
        "entries": dict(base.get("entries") or {}),
        "transitions": list(base.get("transitions") or []),
        "skills_gated": [
            {"id": item["id"], "entry": dict(item["entry"])}
            for item in (base.get("skills_gated") or [])
            if isinstance(item, dict) and "id" in item and isinstance(item.get("entry"), dict)
        ],
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
                if _entry_has_when(entry):
                    _upsert_gated_skill(result["skills_gated"], skill_id, entry)
                else:
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
            if _entry_has_when(transition):
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


def _validate_skill_entry(
    skill_id: str,
    entry: Any,
    *,
    project_root: Path,
    plugin_root: Path,
    require_when: bool = False,
) -> tuple[dict[str, Any] | None, list[str]]:
    """Normalize and validate one skills registry entry. Returns (entry, errors)."""
    errors: list[str] = []
    try:
        normalized = normalize_skill_entry(entry)
    except WorkflowResolveError as exc:
        return None, [f"skills.{skill_id}: {exc}"]

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
                plugin_root=plugin_root,
                project_root=project_root,
                allow=run_block["allow"],
            )
            normalized["run"] = run_block
        except WorkflowResolveError as exc:
            errors.append(str(exc))

    if require_when or _entry_has_when(normalized):
        when_value = normalized.get("when")
        if require_when and when_value is None:
            errors.append(
                f"skills.{skill_id}: gated skill entry must include when.capabilities"
            )
        else:
            try:
                _when_capability_set(when_value)
            except WorkflowResolveError as exc:
                errors.append(f"skills.{skill_id}: {exc}")

    return normalized, errors


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
        normalized, skill_errors = _validate_skill_entry(
            skill_id,
            entry,
            project_root=project_root,
            plugin_root=root,
        )
        errors.extend(skill_errors)
        if normalized is not None:
            normalized_skills[skill_id] = normalized

    gated_skills = doc.get("skills_gated") or []
    if gated_skills and not isinstance(gated_skills, list):
        errors.append("skills_gated must be a sequence")
        gated_skills = []

    normalized_gated: list[dict[str, Any]] = []
    for item in gated_skills:
        if not isinstance(item, dict) or "id" not in item:
            errors.append(f"skills_gated entry must be a mapping with id: {item!r}")
            continue
        skill_id = item["id"]
        if not isinstance(skill_id, str) or not skill_id.strip():
            errors.append(f"skills_gated missing valid id: {item!r}")
            continue
        normalized, skill_errors = _validate_skill_entry(
            skill_id,
            item.get("entry"),
            project_root=project_root,
            plugin_root=root,
            require_when=True,
        )
        errors.extend(skill_errors)
        if normalized is None:
            continue
        known_ids.add(skill_id)
        normalized_gated.append({"id": skill_id, "entry": normalized})

    if not errors:
        doc["skills"] = normalized_skills
        if "skills_gated" in doc or normalized_gated:
            doc["skills_gated"] = normalized_gated

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
        if _entry_has_when(transition):
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
            continue

        if to not in (None, "wait"):
            has_ungated_target = to in bundled_skills or to in normalized_skills
            if not has_ungated_target:
                trans_req = when_sig or frozenset()
                skill_reqs: list[frozenset[str]] = []
                for item in normalized_gated:
                    if item.get("id") != to:
                        continue
                    try:
                        skill_reqs.append(
                            _when_capability_set(item["entry"].get("when"))
                            or frozenset()
                        )
                    except WorkflowResolveError:
                        continue
                if not any(skill_req <= trans_req for skill_req in skill_reqs):
                    errors.append(
                        f"transition from={from_id!r} on={on!r} to={to!r} "
                        "cannot exist under the same capability set as the "
                        "gated-only target skill"
                    )

    return errors


def apply_capabilities(
    doc: dict[str, Any],
    *,
    capabilities: list[str],
    bundled_skills: set[str],
) -> dict[str, Any]:
    """Filter merged workflow to the active capability set and strip when clauses."""
    active = set(capabilities)
    candidates: dict[str, list[tuple[frozenset[str] | None, dict[str, Any]]]] = {}

    for skill_id, entry in (doc.get("skills") or {}).items():
        if not isinstance(entry, dict):
            continue
        when = entry.get("when") if _entry_has_when(entry) else None
        try:
            if not when_satisfied(when, active):
                continue
            required = _when_capability_set(when)
        except WorkflowResolveError as exc:
            raise WorkflowResolveError(f"skills.{skill_id}: {exc}") from exc
        candidates.setdefault(skill_id, []).append((required, entry))

    for item in doc.get("skills_gated") or []:
        if not isinstance(item, dict):
            continue
        skill_id = item.get("id")
        entry = item.get("entry")
        if not isinstance(skill_id, str) or not isinstance(entry, dict):
            continue
        when = entry.get("when") if _entry_has_when(entry) else None
        try:
            if not when_satisfied(when, active):
                continue
            required = _when_capability_set(when)
        except WorkflowResolveError as exc:
            raise WorkflowResolveError(f"skills.{skill_id}: {exc}") from exc
        candidates.setdefault(skill_id, []).append((required, entry))

    skills_out: dict[str, Any] = {}
    for skill_id, items in candidates.items():
        chosen = _pick_most_specific(
            items,
            label=f"skills.{skill_id}",
            active=active,
        )
        skills_out[skill_id] = _strip_when(chosen)

    for skill_id in bundled_skills:
        if skill_id not in skills_out:
            skills_out[skill_id] = {}

    grouped: dict[tuple[str, str], list[tuple[frozenset[str] | None, dict[str, Any]]]] = {}
    for transition in doc.get("transitions") or []:
        if not isinstance(transition, dict):
            continue
        when = transition.get("when") if _entry_has_when(transition) else None
        try:
            if not when_satisfied(when, active):
                continue
            required = _when_capability_set(when)
        except WorkflowResolveError as exc:
            raise WorkflowResolveError(str(exc)) from exc
        from_id = transition["from"]
        on = transition["on"]
        grouped.setdefault((from_id, on), []).append((required, transition))

    transitions_out: list[dict[str, Any]] = []
    for (from_id, on), items in grouped.items():
        chosen = _pick_most_specific(
            items,
            label=f"transitions for from={from_id!r} on={on!r}",
            active=active,
        )
        transitions_out.append(_strip_when(chosen))

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
    merged = load_workflow_mapping(default_path, label="bundled workflow")

    for overlay_path in bundled_overlay_paths(plugin_root):
        overlay_doc = load_workflow_mapping(
            overlay_path, label=f"bundled overlay {overlay_path.name}"
        )
        merged = merge_workflows(merged, overlay_doc)

    if not bundled_only:
        user_path = overlay_workflow_path(user_home)
        if user_path is not None:
            user_doc = load_workflow_mapping(user_path, label="user workflow")
            merged = merge_workflows(merged, user_doc)

        project_path = overlay_workflow_path(project_root)
        if project_path is not None:
            project_doc = load_workflow_mapping(
                project_path, label="project workflow"
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

    return apply_capabilities(
        merged,
        capabilities=list(capabilities or []),
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


def _cli_capabilities(
    args: argparse.Namespace, *, detect: bool | None = None
) -> list[str]:
    from_cli = parse_capabilities(getattr(args, "capabilities", None))
    from_env = parse_capabilities(os.environ.get("SUPERPOWERS_CAPABILITIES"))
    if detect is None:
        should_detect = bool(getattr(args, "detect_capabilities", False))
    else:
        should_detect = detect
    detected = detect_capabilities() if should_detect else []
    return merge_capability_sets(detected, from_env, from_cli)


def _add_capability_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--capabilities",
        help=(
            "Comma-separated host capabilities (known: "
            + ", ".join(sorted(KNOWN_CAPABILITIES))
            + "; also reads SUPERPOWERS_CAPABILITIES)"
        ),
    )
    parser.add_argument(
        "--detect-capabilities",
        action="store_true",
        help=(
            "Include conservative auto-detected capabilities from the environment "
            "(run-workflow-action always detects; this flag is accepted for compatibility)"
        ),
    )


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
    _add_capability_arguments(parser)
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
    _add_capability_arguments(parser)
    args = parser.parse_args(argv)
    plugin_root, project_root, user_home = _cli_paths(args)
    # Always re-probe so `run-workflow-action --id` cannot drop SessionStart's
    # session-inject. Advertised tokens still come from SUPERPOWERS_CAPABILITIES
    # or --capabilities (forward the injected map's capabilities list).
    capabilities = _cli_capabilities(args, detect=True)

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


PENDING_HANDOFF_NAME = "pending-handoff.json"
PENDING_HANDOFF_IN_PROGRESS_NAME = "pending-handoff.json.in-progress"


def pending_handoff_path(project_root: Path) -> Path:
    """Project-local durable handoff consumed by Claude Code Stop."""
    return Path(project_root) / ".supersuit" / PENDING_HANDOFF_NAME


def pending_handoff_in_progress_path(project_root: Path) -> Path:
    return Path(project_root) / ".supersuit" / PENDING_HANDOFF_IN_PROGRESS_NAME


def write_pending_handoff(project_root: Path, payload: dict[str, Any]) -> Path:
    path = pending_handoff_path(project_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    return path


def _normalize_session_id(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    sid = value.strip()
    return sid or None


def queue_session_id(explicit: str | None = None) -> str | None:
    """Session id for --queue: --session-id, else CLAUDE_SESSION_ID if already set.

    Claude Stop stdin has ``session_id``; Bash tool contexts do not reliably
    export it. We do not invent a token.
    """
    sid = _normalize_session_id(explicit)
    if sid:
        return sid
    return _normalize_session_id(os.environ.get("CLAUDE_SESSION_ID"))


def session_ids_compatible(file_sid: Any, request_sid: str | None) -> bool:
    """Fail-closed pending-handoff isolation.

    Claim only when both sides have the same id, or both have none
    (legacy project-global). A scoped Stop must not consume an unscoped
    file; an unscoped Stop must not consume a scoped file.
    """
    file_n = _normalize_session_id(file_sid)
    req_n = _normalize_session_id(request_sid)
    if file_n is None and req_n is None:
        return True
    return file_n is not None and req_n is not None and file_n == req_n


def load_pending_handoff(
    project_root: Path, session_id: str | None = None
) -> dict[str, Any] | None:
    path = pending_handoff_path(project_root)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    file_sid = data.get("session_id") or data.get("sessionId")
    if not session_ids_compatible(file_sid, session_id):
        return None
    return data


def claim_pending_handoff(
    project_root: Path, session_id: str | None = None
) -> dict[str, Any] | None:
    """Rename pending → in-progress so a second Stop cannot double-exec."""
    data = load_pending_handoff(project_root, session_id=session_id)
    if data is None:
        return None
    src = pending_handoff_path(project_root)
    dst = pending_handoff_in_progress_path(project_root)
    try:
        src.replace(dst)
    except OSError:
        return None
    return data


def restore_claimed_handoff(project_root: Path) -> None:
    """Put a failed consume back so a later Stop can retry."""
    src = pending_handoff_in_progress_path(project_root)
    dst = pending_handoff_path(project_root)
    if not src.is_file():
        return
    try:
        src.replace(dst)
    except OSError:
        pass


def consume_claimed_handoff(project_root: Path) -> None:
    """Drop the in-progress claim after auto or definitive not-run."""
    for path in (
        pending_handoff_in_progress_path(project_root),
        pending_handoff_path(project_root),
    ):
        try:
            path.unlink()
        except OSError:
            pass


def consume_pending_handoff(project_root: Path) -> None:
    consume_claimed_handoff(project_root)


def lookup_transition_to(
    resolved: dict[str, Any], from_id: str, on: str
) -> tuple[bool, Any]:
    """Return ``(found, to)`` for ``(from, on)``. Missing edges are not ``to: null``."""
    for transition in resolved.get("transitions") or []:
        if not isinstance(transition, dict):
            continue
        if transition.get("from") == from_id and transition.get("on") == on:
            return True, transition.get("to")
    return False, None


def _skill_is_run(resolved: dict[str, Any], skill_id: str) -> bool:
    skills = resolved.get("skills") or {}
    entry = skills.get(skill_id)
    if not isinstance(entry, dict):
        return False
    try:
        normalized = normalize_skill_entry(entry)
    except WorkflowResolveError:
        return False
    return "run" in normalized


def _read_stdin_payload() -> dict[str, Any] | None:
    if sys.stdin.isatty():
        return None
    raw = sys.stdin.read()
    if not raw.strip():
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def _extract_handoff(
    payload: dict[str, Any] | None,
) -> tuple[str | None, str | None, str | None]:
    """Return ``(id, from, on)`` from a hook/tool JSON payload."""
    if not payload:
        return None, None, None
    tool = payload.get("tool_input") or payload.get("toolInput") or {}
    sources: list[dict[str, Any]] = []
    if isinstance(tool, dict):
        sources.append(tool)
    sources.append(payload)
    action_id = None
    from_id = None
    on = None
    for src in sources:
        if action_id is None and isinstance(src.get("id"), str) and src["id"]:
            action_id = src["id"]
        if from_id is None and isinstance(src.get("from"), str) and src["from"]:
            from_id = src["from"]
        if on is None and isinstance(src.get("on"), str) and src["on"]:
            on = src["on"]
    return action_id, from_id, on


def _is_hook_event(payload: dict[str, Any] | None) -> bool:
    if not payload:
        return False
    return any(
        key in payload
        for key in (
            "session_id",
            "sessionId",
            "hook_event_name",
            "hookEventName",
            "stop_hook_active",
            "stopHookActive",
        )
    )


def _hook_event_output(result: dict[str, Any]) -> dict[str, Any]:
    context = (
        "<WORKFLOW_EXEC_RESULT>\n"
        + json.dumps(result)
        + "\n</WORKFLOW_EXEC_RESULT>"
    )
    if result.get("mode") == "auto":
        reason = f"workflow-exec: {result.get('id')} → {result.get('outcome')}"
    elif result.get("reason"):
        reason = f"workflow-exec: {result.get('reason')}"
    else:
        reason = "workflow-exec"
    if os.environ.get("CURSOR_PLUGIN_ROOT"):
        return {
            "additional_context": context,
            "decision": "block",
            "reason": reason,
        }
    if os.environ.get("CLAUDE_PLUGIN_ROOT") and not os.environ.get("COPILOT_CLI"):
        return {
            "decision": "block",
            "reason": reason,
            "hookSpecificOutput": {
                "hookEventName": "Stop",
                "additionalContext": context,
            },
        }
    return {
        "additionalContext": context,
        "decision": "block",
        "reason": reason,
    }


def run_workflow_exec(
    *,
    action_id: str | None = None,
    from_id: str | None = None,
    on: str | None = None,
    plugin_root: Path,
    project_root: Path,
    user_home: Path,
    bundled_only: bool = False,
    capabilities: list[str] | None = None,
) -> dict[str, Any]:
    """Host mediator for advertised exec-hook. Never bypasses run_workflow_action."""
    caps = list(capabilities or [])
    if "exec-hook" not in caps:
        return {
            "mode": "agent-mediated",
            "reason": "exec-hook not advertised",
            "capabilities": caps,
        }

    looked_up_from = from_id
    looked_up_on = on
    if not action_id and (not from_id or on is None):
        return {
            "mode": "idle",
            "reason": "no run id or from/on handoff",
            "capabilities": caps,
        }

    resolved = resolve_workflow(
        plugin_root=plugin_root,
        project_root=project_root,
        user_home=user_home,
        bundled_only=bundled_only,
        capabilities=caps,
    )
    if not action_id:
        found, target = lookup_transition_to(resolved, from_id, on)
        if not found:
            return {
                "mode": "not-run",
                "from": from_id,
                "on": on,
                "to": "wait",
                "capabilities": resolved.get("capabilities") or caps,
            }
        if target is None or target == "wait" or not _skill_is_run(
            resolved, str(target)
        ):
            return {
                "mode": "not-run",
                "from": from_id,
                "on": on,
                "to": target,
                "capabilities": resolved.get("capabilities") or caps,
            }
        action_id = str(target)

    result = run_workflow_action(
        action_id=action_id,
        plugin_root=plugin_root,
        project_root=project_root,
        user_home=user_home,
        bundled_only=bundled_only,
        capabilities=caps,
    )
    result["mode"] = "auto"
    result["capabilities"] = resolved.get("capabilities") or caps
    if looked_up_from:
        result["from"] = looked_up_from
        result["on"] = looked_up_on
    return result


def workflow_exec_main(argv: list[str] | None = None) -> int:
    """CLI / hook entry for advertised exec-hook auto-exec."""
    parser = argparse.ArgumentParser(
        description=(
            "Host mediator for workflow run/exec when exec-hook is advertised. "
            "Always delegates to the same allowlist/outcome executor as "
            "run-workflow-action."
        )
    )
    parser.add_argument("--id", help="Logical id of the run/exec registry entry")
    parser.add_argument("--from", dest="from_id", help="Completed logical id")
    parser.add_argument("--on", help="Emitted outcome for --from")
    parser.add_argument(
        "--queue",
        action="store_true",
        help=(
            "Write .supersuit/pending-handoff.json (from/on or id only) and exit. "
            "Claude Code Stop consumes it; do not pass the underlying run argv."
        ),
    )
    parser.add_argument(
        "--session-id",
        dest="session_id",
        help=(
            "Scope a queued pending-handoff to this session. Required for "
            "--queue unless CLAUDE_SESSION_ID is already set. Do not invent "
            "a token — use Stop/SessionStart session_id."
        ),
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
    _add_capability_arguments(parser)
    args = parser.parse_args(argv)
    plugin_root, project_root, user_home = _cli_paths(args)
    capabilities = _cli_capabilities(args, detect=True)

    payload = None
    claimed_pending = False
    cli_target = bool(args.id or args.from_id or args.on or args.queue)
    if not cli_target:
        payload = _read_stdin_payload()
        if payload and (
            payload.get("stop_hook_active") is True
            or payload.get("stopHookActive") is True
        ):
            # Already in a Stop continuation — do not loop.
            return 0
        extracted_id, extracted_from, extracted_on = _extract_handoff(payload)
        if extracted_id:
            args.id = extracted_id
        if extracted_from:
            args.from_id = extracted_from
        if extracted_on:
            args.on = extracted_on
        if not args.id and not args.from_id:
            session_id = None
            if payload:
                raw_sid = payload.get("session_id") or payload.get("sessionId")
                if isinstance(raw_sid, str) and raw_sid:
                    session_id = raw_sid
            pending = claim_pending_handoff(project_root, session_id=session_id)
            claimed_pending = pending is not None
            if pending:
                extracted_id, extracted_from, extracted_on = _extract_handoff(pending)
                if extracted_id:
                    args.id = extracted_id
                if extracted_from:
                    args.from_id = extracted_from
                if extracted_on:
                    args.on = extracted_on

    if args.queue:
        if "exec-hook" not in capabilities:
            print(
                json.dumps(
                    {
                        "mode": "agent-mediated",
                        "reason": "exec-hook not advertised",
                        "capabilities": capabilities,
                    },
                    indent=2 if args.pretty else None,
                )
            )
            return 2
        if args.from_id and not args.on:
            print("--from requires --on", file=sys.stderr)
            return 1
        if args.on and not args.from_id:
            print("--on requires --from", file=sys.stderr)
            return 1
        if not args.id and not (args.from_id and args.on):
            print("--queue requires --id or --from/--on", file=sys.stderr)
            return 1
        session_id = queue_session_id(args.session_id)
        if not session_id:
            print(
                "--queue requires --session-id or CLAUDE_SESSION_ID "
                "(do not invent a session token)",
                file=sys.stderr,
            )
            return 1
        queued: dict[str, Any] = {"session_id": session_id}
        if args.id:
            queued["id"] = args.id
        if args.from_id:
            queued["from"] = args.from_id
            queued["on"] = args.on
        path = write_pending_handoff(project_root, queued)
        print(
            json.dumps(
                {
                    "mode": "queued",
                    "path": str(path),
                    **queued,
                    "capabilities": capabilities,
                },
                indent=2 if args.pretty else None,
            )
        )
        return 0

    if args.from_id and not args.on and not args.id:
        if claimed_pending:
            restore_claimed_handoff(project_root)
        print("--from requires --on", file=sys.stderr)
        return 1
    if args.on and not args.from_id and not args.id:
        if claimed_pending:
            restore_claimed_handoff(project_root)
        print("--on requires --from", file=sys.stderr)
        return 1

    hook_event = _is_hook_event(payload) and not cli_target
    explicit_exec = bool(args.id or args.from_id or args.on)
    # Superpowers baseline: a normal Stop with no queued work is silent idle,
    # even when exec-hook is not advertised. Missing exec-hook is only a hook
    # failure when this Stop claimed a pending file or an explicit exec was
    # requested.
    if hook_event and not claimed_pending and not explicit_exec:
        return 0

    def _finish_pending(mode: str | None) -> None:
        if not claimed_pending:
            return
        if mode in {"auto", "not-run"}:
            consume_claimed_handoff(project_root)
        else:
            restore_claimed_handoff(project_root)

    def _hook_fail(result: dict[str, Any]) -> int:
        _finish_pending(result.get("mode"))
        print(json.dumps(_hook_event_output(result), indent=2 if args.pretty else None))
        return 0

    try:
        result = run_workflow_exec(
            action_id=args.id,
            from_id=args.from_id,
            on=args.on,
            plugin_root=plugin_root,
            project_root=project_root,
            user_home=user_home,
            bundled_only=args.bundled_only,
            capabilities=capabilities,
        )
    except WorkflowResolveError as exc:
        if hook_event:
            return _hook_fail(
                {
                    "mode": "resolve-error",
                    "reason": str(exc),
                    "capabilities": capabilities,
                }
            )
        _finish_pending(None)
        print(str(exc), file=sys.stderr)
        return 1

    if hook_event and result.get("mode") == "auto":
        _finish_pending("auto")
        print(json.dumps(_hook_event_output(result), indent=2 if args.pretty else None))
        # Claude Code drops stdout JSON when the hook process exits non-zero.
        return 0
    if hook_event and result.get("mode") == "not-run":
        _finish_pending("not-run")
        return 0
    if hook_event and result.get("mode") == "agent-mediated":
        return _hook_fail(result)
    if hook_event and result.get("mode") == "idle":
        _finish_pending("idle")
        return 0

    print(json.dumps(result, indent=2 if args.pretty else None))
    mode = result.get("mode")
    _finish_pending(mode)
    if mode == "agent-mediated":
        return 2
    if mode == "auto":
        return 0 if result.get("exit_code", 0) == 0 else 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--workflow-exec":
        raise SystemExit(workflow_exec_main(sys.argv[2:]))
    raise SystemExit(main())

