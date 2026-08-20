#!/usr/bin/env python3
"""Rewrite superpowers: invocations and move leftover .superpowers/ dirs.

This is a one-time Superpowers → Supersuit migration helper. It is not a
drop-in installer. It rewrites only the skill-namespace prefix
``superpowers:`` → ``supersuit:`` and optionally moves overlay/scratch
directories to the canonical ``.supersuit/`` name.

It does not rewrite:
- ``.superpowers/`` / ``~/.superpowers/`` path segments in text
- the skill folder name ``using-superpowers``
- ``SUPERPOWERS_`` environment variable names
- ``obra/superpowers`` or other upstream product references
- binary files
"""

from __future__ import annotations

import argparse
import os
import stat
import sys
from pathlib import Path

CANONICAL_DIRNAME = ".supersuit"
LEGACY_DIRNAME = ".superpowers"
OLD_PREFIX = "superpowers:"
NEW_PREFIX = "supersuit:"
SKIP_DIR_NAMES = frozenset(
    {
        ".git",
        "node_modules",
        "__pycache__",
        ".venv",
        "venv",
        ".tox",
        ".mypy_cache",
        ".ruff_cache",
        ".pytest_cache",
    }
)


def rewrite_text(text: str) -> str:
    """Replace the skill-namespace prefix only."""
    return text.replace(OLD_PREFIX, NEW_PREFIX)


def is_regular_file(path: Path) -> bool:
    """True for a non-symlink regular file. lstat so we never follow links."""
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except OSError:
        return False


def is_binary(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            chunk = handle.read(8192)
    except OSError:
        return True
    return b"\x00" in chunk


def iter_files(root: Path) -> list[Path]:
    if is_regular_file(root):
        return [root]
    if not root.is_dir():
        return []
    found: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(
            name for name in dirnames if name not in SKIP_DIR_NAMES
        )
        for name in sorted(filenames):
            candidate = Path(dirpath) / name
            if is_regular_file(candidate):
                found.append(candidate)
    return found


def plan_dir_move(src: Path, dest: Path) -> str | None:
    if not src.is_dir():
        return None
    if dest.exists():
        return f"skip-move {src} -> {dest} (destination exists; not clobbering)"
    return f"move {src} -> {dest}"


def apply_dir_move(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    src.rename(dest)


def migrate_paths(
    *,
    roots: list[Path],
    write: bool,
    migrate_user: bool,
    user_home: Path,
) -> int:
    actions: list[str] = []
    rewrite_targets: list[Path] = []
    seen: set[Path] = set()

    for root in roots:
        resolved = root.resolve()
        if not resolved.exists():
            print(f"error: path not found: {root}", file=sys.stderr)
            return 1
        for path in iter_files(resolved):
            key = path.resolve()
            if key in seen:
                continue
            seen.add(key)
            rewrite_targets.append(path)

    if migrate_user:
        for extra in (
            user_home / LEGACY_DIRNAME,
            user_home / CANONICAL_DIRNAME,
        ):
            if not extra.exists():
                continue
            for path in iter_files(extra):
                key = path.resolve()
                if key in seen:
                    continue
                seen.add(key)
                rewrite_targets.append(path)

    for path in rewrite_targets:
        if not is_regular_file(path):
            continue
        if is_binary(path):
            continue
        try:
            original = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            actions.append(f"skip-unreadable {path}")
            continue
        updated = rewrite_text(original)
        if updated == original:
            continue
        actions.append(f"rewrite {path}")
        if write:
            path.write_text(updated, encoding="utf-8")

    moves: list[tuple[Path, Path, str]] = []
    seen_moves: set[tuple[Path, Path]] = set()

    def add_move(src: Path, dest: Path) -> None:
        label = plan_dir_move(src, dest)
        if not label:
            return
        key = (src.resolve(), dest.resolve())
        if key in seen_moves:
            return
        seen_moves.add(key)
        moves.append((src, dest, label))

    for root in roots:
        if not root.is_dir():
            continue
        add_move(root / LEGACY_DIRNAME, root / CANONICAL_DIRNAME)

    if migrate_user:
        add_move(user_home / LEGACY_DIRNAME, user_home / CANONICAL_DIRNAME)

    for src, dest, label in moves:
        actions.append(label)
        if write and label.startswith("move "):
            apply_dir_move(src, dest)

    mode = "WRITE" if write else "DRY-RUN"
    rewrites = sum(1 for item in actions if item.startswith("rewrite "))
    move_count = sum(1 for item in actions if item.startswith("move "))
    if not actions:
        print(f"{mode}: no changes needed")
        return 0

    print(f"{mode}: {rewrites} rewrite(s), {move_count} move(s)")
    for item in actions:
        print(f"  {item}")
    if not write:
        print("Re-run with --write to apply.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Rewrite superpowers: skill invocations to supersuit: and move "
            "leftover .superpowers/ overlay/scratch dirs to .supersuit/."
        )
    )
    parser.add_argument(
        "-n",
        "--dry-run",
        action="store_true",
        help="Show planned changes without writing (default)",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="Apply rewrites and directory moves",
    )
    parser.add_argument(
        "--user",
        action="store_true",
        help="Also migrate ~/.superpowers/ to ~/.supersuit/",
    )
    parser.add_argument(
        "--user-home",
        help="Home directory for --user (default: HOME)",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Project roots and/or files to scan (default: current directory)",
    )
    args = parser.parse_args(argv)

    write = bool(args.write) and not bool(args.dry_run)
    user_home = Path(
        args.user_home or os.environ.get("HOME", os.path.expanduser("~"))
    )
    roots = [Path(item) for item in args.paths] or [Path.cwd()]
    return migrate_paths(
        roots=roots,
        write=write,
        migrate_user=args.user,
        user_home=user_home,
    )


if __name__ == "__main__":
    raise SystemExit(main())
