#!/usr/bin/env bash
# Ensure a checkout of jamesthomasonjr/skills, then run its Cloud Agent installer.
# Intended for Cursor Cloud Agent environment setup. Safe to re-run.
set -euo pipefail

SKILLS_SLUG="jamesthomasonjr/skills"
SKILLS_URL="https://github.com/jamesthomasonjr/skills"
SKILLS_REF="${SKILLS_REF:-main}"
SKILLS_SRC="${HOME}/.cursor/skill-src/skills"
INSTALLER="${SKILLS_SRC}/scripts/install-cloud-agent-skills.sh"

mkdir -p "$(dirname "${SKILLS_SRC}")"

clone_skills() {
  if command -v gh >/dev/null 2>&1; then
    if gh repo clone "${SKILLS_SLUG}" "${SKILLS_SRC}" -- --depth 1 --branch "${SKILLS_REF}"; then
      return 0
    fi
    rm -rf "${SKILLS_SRC}"
  fi
  git clone --depth 1 --branch "${SKILLS_REF}" "${SKILLS_URL}.git" "${SKILLS_SRC}"
}

if [[ -d "${SKILLS_SRC}/.git" ]]; then
  git -C "${SKILLS_SRC}" fetch --depth 1 origin "${SKILLS_REF}"
  git -C "${SKILLS_SRC}" reset --hard "origin/${SKILLS_REF}"
else
  rm -rf "${SKILLS_SRC}"
  clone_skills
fi

if [[ ! -f "${INSTALLER}" ]]; then
  echo "error: ${INSTALLER} is missing." >&2
  echo "It lands on ${SKILLS_SLUG} main after https://github.com/jamesthomasonjr/skills/pull/9 merges." >&2
  exit 1
fi

exec bash "${INSTALLER}"
