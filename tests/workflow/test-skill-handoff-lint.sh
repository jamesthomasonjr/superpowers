#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILURES=0
# Forbidden *directive* patterns in pipeline skills (allow Outcomes descriptive text via careful patterns)
for f in brainstorming writing-plans executing-plans subagent-driven-development; do
  if rg -n "REQUIRED SUB-SKILL: Use superpowers:(writing-plans|subagent-driven-development|executing-plans|finishing-a-development-branch)" \
      "$REPO_ROOT/skills/$f/SKILL.md"; then
    echo "FAIL: $f still has pipeline REQUIRED SUB-SKILL"
    FAILURES=$((FAILURES+1))
  fi
done
if rg -n "invoke writing-plans skill|Invoke writing-plans skill" "$REPO_ROOT/skills/brainstorming/SKILL.md"; then
  echo "FAIL: brainstorming still invokes writing-plans"
  FAILURES=$((FAILURES+1))
fi
exit "$FAILURES"
