# Native Visual Surface

Use this rung when `native-canvas` is **advertised** (via
`SUPERPOWERS_CAPABILITIES` or `--capabilities`) and the user accepted the
visual-surface offer.

Do **not** infer this rung from a product name. Cursor Canvas is one
example of a native surface, not a detection signal.

## After accept

You MAY name the chosen surface once ("I'll use the native visual
surface" — or the host's name if you already know it from tools, not
from guessing). Then use the host's native visual-surface tool.

Typical host tools: a Canvas / docs-canvas command, a design preview
panel, or another in-product visual editor the harness exposes. Follow
that tool's own skill if one is installed.

Do **not** start the companion HTML server first. Native is the preferred
rung.

## Per-question

The parent [SKILL.md](SKILL.md) when-to-use rules still apply. Native
availability does not make every question visual.

## Fallback

If the native surface is missing, errors, or the user cannot see it, fall
back:

1. Run `scripts/select-visual-surface --accepted yes --capabilities native-canvas --available no` (or treat the run outcome as `companion`)
2. Read [companion-server.md](companion-server.md)
3. If the companion server also fails, stay text-only

Do not silently keep retrying a broken native surface.
