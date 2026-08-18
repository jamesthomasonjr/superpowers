# Supersuit for Kimi Code

Complete guide for using **Supersuit** — a framework for custom Superpowers-based workflows (not a Superpowers replacement) — with [Kimi Code](https://github.com/MoonshotAI/kimi-code).

## Installation

Install from this repository:

```text
/plugins install https://github.com/jeighty/supersuit
```

Kimi Code's marketplace entry named "Superpowers" may point at upstream. Prefer the GitHub URL above for Supersuit.

Kimi Code applies plugin changes to new sessions. After installing, updating, enabling, disabling, or reloading a plugin, start a fresh session with `/new`.

## How It Works

The Kimi plugin manifest lives at `.kimi-plugin/plugin.json`.

The manifest does three things:

1. Points Kimi Code at the existing `skills/` directory.
2. Loads `using-superpowers` at session start through `sessionStart.skill`.
3. Provides Kimi-specific tool mapping through `skillInstructions`.

Kimi Code reads skills from this repository. There are no copied skills, symlinks, hooks, or extra runtime dependencies. Pipeline handoffs use Supersuit's workflow map; paths remain under `.superpowers/`. See [workflow-config.md](workflow-config.md).

## Tool Mapping

Skills describe actions instead of hard-coding one runtime's tool names. On Kimi Code these resolve to:

- "Ask the user" / "ask clarifying questions" -> `AskUserQuestion`
- "Create a todo" / "mark complete in todo list" -> `TodoList`
- "Dispatch a subagent" -> `Agent`
- "Invoke a skill" -> Kimi Code's native `Skill` tool
- "Read a file" / "write a file" / "edit a file" -> `Read`, `Write`, `Edit`
- "Run a shell command" -> `Bash`
- "Search file contents" -> `Grep`
- "Find files by path or pattern" -> `Glob`
- "Fetch a URL" -> `FetchURL`
- "Search the web" -> `WebSearch`

## Updating

Use Kimi Code's plugin manager:

```text
/plugins
```

Select the installed plugin and update it from there, or reinstall from the GitHub URL. Start a fresh session with `/new` after updating.

## Troubleshooting

### Plugin not loading

1. Run `/plugins info supersuit` and check diagnostics.
2. Make sure the plugin is enabled.
3. Start a fresh session with `/new` after install or update.

### Direct GitHub install used an old release

Kimi Code installs the latest GitHub release for a bare repository URL when one exists. To test unreleased fork work, install a branch explicitly (replace with the branch you need):

```text
/plugins install https://github.com/jeighty/supersuit/tree/<branch-name>
```

### Skills not triggering

1. Confirm `/plugins info supersuit` shows the plugin enabled.
2. Start a fresh session with `/new`.
3. Try the acceptance prompt: `Let's make a react todo list`. A working install should load `brainstorming` before writing code.
