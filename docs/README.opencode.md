# Supersuit for OpenCode

Complete guide for using **Supersuit** — a framework for custom Superpowers-based workflows (not a Superpowers replacement) — with [OpenCode.ai](https://opencode.ai).

## Installation

Add this repository to the `plugin` array in your `opencode.json` (global or project-level):

```json
{
  "plugin": ["supersuit@git+https://github.com/jeighty/supersuit.git"]
}
```

Restart OpenCode. The plugin installs through OpenCode's plugin manager and
registers all skills. The package id is **`supersuit`** (not upstream `superpowers`).

Verify by asking: "Tell me about your superpowers" or checking that workflow-map
bootstrap context is present after session start.

OpenCode uses its own plugin install. If you also use Claude Code, Codex, or
another harness, install Supersuit separately for each one.

### Migrating from the old symlink-based install

If you previously installed via `git clone` and symlinks, remove the old setup:

```bash
# Remove old symlinks
rm -f ~/.config/opencode/plugins/superpowers.js
rm -rf ~/.config/opencode/skills/superpowers

# Optionally remove the cloned repo
rm -rf ~/.config/opencode/superpowers

# Remove skills.paths from opencode.json if you added one for superpowers
```

Then follow the installation steps above.

## Usage

Use OpenCode's native `skill` tool:

```
use skill tool to list skills
use skill tool to load brainstorming
```

Stock behavior matches Superpowers. To rewire the pipeline, see
[workflow-config.md](workflow-config.md).

## How It Works

The OpenCode plugin:

1. **Injects bootstrap context** via the `experimental.chat.messages.transform` hook, including Supersuit/Superpowers awareness and the resolved workflow map when SessionStart/resolver support applies.
2. **Registers the skills directory** via the `config` hook, so OpenCode discovers all skills without symlinks or manual config.

### Tool Mapping

Skills speak in actions rather than naming any one runtime's tools. On OpenCode these resolve to:

- "Create a todo" / "mark complete in todo list" → `todowrite`
- `Subagent (general-purpose):` template → OpenCode's `task` tool with `subagent_type: "general"` (or `"explore"` for codebase exploration)
- "Invoke a skill" → OpenCode's native `skill` tool
- "Read a file" → `read`
- "Create a file" / "edit a file" / "delete a file" → `apply_patch`
- "Run a shell command" → `bash`
- "Search file contents" / "find files by name" → `grep`, `glob`
- "Fetch a URL" → `webfetch`

(Verified against the installed OpenCode CLI's tool inventory.)

## Troubleshooting

### Plugin not loading

1. Check OpenCode logs: `opencode run --print-logs "hello" 2>&1 | grep -iE 'supersuit|superpowers'`
2. Verify the plugin line in your `opencode.json` is correct
3. Make sure you're running a recent version of OpenCode

### Windows install issues

Some Windows OpenCode builds have upstream installer issues with git-backed
plugin specs, including cache paths for `git+https` URLs and Bun not finding
`git.exe` even when it works in a normal terminal. If OpenCode cannot install
the plugin, try installing with system npm and pointing OpenCode at the local
package:

```powershell
npm install supersuit@git+https://github.com/jeighty/supersuit.git --prefix "$HOME\.config\opencode"
```

Then use the installed package path in `opencode.json`:

```json
{
  "plugin": ["~/.config/opencode/node_modules/supersuit"]
}
```

### Skills not found

1. Use OpenCode's `skill` tool to list available skills
2. Check that the plugin is loading (see above)
3. Each skill needs a `SKILL.md` file with valid YAML frontmatter

### Bootstrap not appearing

1. Check OpenCode version supports `experimental.chat.messages.transform` hook
2. Restart OpenCode after config changes

## Getting Help

- Report issues: https://github.com/jeighty/supersuit/issues
- Main documentation: https://github.com/jeighty/supersuit
- Upstream Superpowers: https://github.com/obra/superpowers
- OpenCode docs: https://opencode.ai/docs/
