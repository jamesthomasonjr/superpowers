# Companion server — process lifetime (not the primary prompt path)

The launcher auto-detects common process-lifetime traps. Prefer
`skills/brainstorming/scripts/start-server.sh --project-dir <project> --open`
and only add flags when auto-detect is not enough.

**Auto-detect already in the launcher:**

- `CODEX_CI` set → foreground (Codex reaps detached processes)
- Windows-like shell (`msys` / `cygwin` / `MINGW` / `MSYSTEM`) → foreground

Override with `--foreground` / `--background` when you must.

## When you must own backgrounding

Keep `--foreground` so the harness, not the script, owns the process.
Mark the shell tool call background / non-blocking so the server
survives across turns. Then read `$STATE_DIR/server-info` for the URL.

Examples (not detection — use only if the default launch dies between turns):

```bash
# Harness-owned background + script foreground
scripts/start-server.sh --project-dir /path/to/project --open --foreground

# .sh launcher from a PowerShell-only tool (Windows)
bash scripts/start-server.sh --project-dir /path/to/project --open --foreground
```

If the URL is unreachable from the user's browser (remote/container),
bind a non-loopback host:

```bash
scripts/start-server.sh \
  --project-dir /path/to/project \
  --host 0.0.0.0 \
  --url-host localhost \
  --open
```

`--url-host` controls the hostname printed in the returned URL JSON.

Do not put these recipes in the user-facing offer. The offer stays
product-agnostic ("visual surface").
