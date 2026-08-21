# Companion Server (portable visual-surface baseline)

Zero-dependency HTML server for showing mockups, diagrams, and options.
This is the portable default when `native-canvas` is **not** advertised,
or when the native surface is unavailable.

Start this rung only after the user accepted the visual-surface offer.
If `native-canvas` is advertised and working, use
[native-canvas.md](native-canvas.md) instead.

When-to-use (visual vs text) lives in [SKILL.md](SKILL.md). This file is
mechanics.

## How It Works

The server watches a directory for HTML files and serves the newest one.
You write HTML to `screen_dir`; the user sees it and can click to select
options. Selections are recorded to `state_dir/events` that you read on
your next turn.

**Content fragments vs full documents:** If your HTML file starts with
`<!DOCTYPE` or `<html`, the server serves it as-is (just injects the
helper script). Otherwise, the server wraps your content in the frame
template. **Write content fragments by default.**

## Starting a Session

Scripts live under `skills/brainstorming/scripts/`.

```bash
# Start AFTER the user accepts the visual surface. --open auto-opens the
# first screen; --project-dir persists mockups and enables same-port restart.
skills/brainstorming/scripts/start-server.sh --project-dir /path/to/project --open

# Returns: {"type":"server-started","port":52341,
#           "url":"http://localhost:52341/?key=ab12…",
#           "screen_dir":"/path/to/project/.supersuit/brainstorm/12345-1706000000/content",
#           "state_dir":"/path/to/project/.supersuit/brainstorm/12345-1706000000/state"}
```

Save `screen_dir` and `state_dir` from the response. With `--open`, the
browser opens when you push the first screen — still share the complete
URL as a fallback (headless/remote setups will not auto-open).

**The URL contains a session key (`?key=…`).** Always give the user the
**complete** URL from the `url` field — never strip the query string.

**Finding connection info:** The server writes startup JSON to
`$STATE_DIR/server-info`. With `--project-dir`, sessions live under
`<project>/.supersuit/brainstorm/` (leftover
`<project>/.superpowers/brainstorm/` may still exist until migrated).

Remind the user to add `.supersuit/` to `.gitignore` if it is not already
there.

Process-lifetime details (`CODEX_CI`, Windows foreground, harness-owned
backgrounding) are **not** in this primary path. The launcher auto-detects
the common cases. See [references/launch-recipes.md](references/launch-recipes.md)
only if the default launch dies between turns or the URL is unreachable.

## The Loop

1. **Check server is alive**, then **write HTML** to a new file in `screen_dir`:
   - Confirm `$STATE_DIR/server-info` exists and `$STATE_DIR/server-stopped` does not. If it has shut down, restart with `start-server.sh` using the **same `--project-dir`**. The server auto-exits after 4 hours idle (`--idle-timeout-minutes`).
   - Use semantic filenames: `platform.html`, `visual-style.html`, `layout.html`
   - **Never reuse filenames**
   - Use your file-creation tool — **never use cat/heredoc**
   - Server serves the newest file

2. **Tell the user what to expect and end your turn:**
   - Remind them of the URL (every step, not just first)
   - Brief text summary of what's on screen
   - Ask them to respond in chat: "Take a look and let me know what you think. Click to select an option if you'd like."

3. **On your next turn** — after the user responds:
   - Read `$STATE_DIR/events` if it exists (JSON lines)
   - Merge with their chat text. Chat is primary; events are structured extras

4. **Iterate or advance** — if feedback changes the current screen, write a new file (e.g., `layout-v2.html`).

5. **Unload when returning to text** — push a waiting screen so they are not staring at a resolved choice:

   ```html
   <!-- filename: waiting.html (or waiting-2.html, etc.) -->
   <div style="display:flex;align-items:center;justify-content:center;min-height:60vh">
     <p class="subtitle">Continuing in text...</p>
   </div>
   ```

6. Repeat until done.

## Writing Content Fragments

```html
<h2>Which layout works better?</h2>
<p class="subtitle">Consider readability and visual hierarchy</p>

<div class="options">
  <div class="option" data-choice="a" onclick="toggleSelect(this)">
    <div class="letter">A</div>
    <div class="content">
      <h3>Single Column</h3>
      <p>Clean, focused reading experience</p>
    </div>
  </div>
  <div class="option" data-choice="b" onclick="toggleSelect(this)">
    <div class="letter">B</div>
    <div class="content">
      <h3>Two Column</h3>
      <p>Sidebar navigation with main content</p>
    </div>
  </div>
</div>
```

No `<html>`, CSS, or `<script>` tags needed. The server provides those.

## CSS Classes Available

### Options (A/B/C choices)

```html
<div class="options">
  <div class="option" data-choice="a" onclick="toggleSelect(this)">
    <div class="letter">A</div>
    <div class="content">
      <h3>Title</h3>
      <p>Description</p>
    </div>
  </div>
</div>
```

**Multi-select:** Add `data-multiselect` to the container.

### Cards (visual designs)

```html
<div class="cards">
  <div class="card" data-choice="design1" onclick="toggleSelect(this)">
    <div class="card-image"><!-- mockup content --></div>
    <div class="card-body">
      <h3>Name</h3>
      <p>Description</p>
    </div>
  </div>
</div>
```

### Mockup container

```html
<div class="mockup">
  <div class="mockup-header">Preview: Dashboard Layout</div>
  <div class="mockup-body"><!-- your mockup HTML --></div>
</div>
```

### Split view (side-by-side)

```html
<div class="split">
  <div class="mockup"><!-- left --></div>
  <div class="mockup"><!-- right --></div>
</div>
```

### Pros/Cons

```html
<div class="pros-cons">
  <div class="pros"><h4>Pros</h4><ul><li>Benefit</li></ul></div>
  <div class="cons"><h4>Cons</h4><ul><li>Drawback</li></ul></div>
</div>
```

### Mock elements (wireframe building blocks)

```html
<div class="mock-nav">Logo | Home | About | Contact</div>
<div style="display: flex;">
  <div class="mock-sidebar">Navigation</div>
  <div class="mock-content">Main content area</div>
</div>
<button class="mock-button">Action Button</button>
<input class="mock-input" placeholder="Input field">
<div class="placeholder">Placeholder area</div>
```

### Typography and sections

- `h2` — page title
- `h3` — section heading
- `.subtitle` — secondary text below title
- `.section` — content block with bottom margin
- `.label` — small uppercase label text

## Browser Events Format

```jsonl
{"type":"click","choice":"a","text":"Option A - Simple Layout","timestamp":1706000101}
{"type":"click","choice":"c","text":"Option C - Complex Grid","timestamp":1706000108}
{"type":"click","choice":"b","text":"Option B - Hybrid","timestamp":1706000115}
```

The last `choice` event is typically the final selection. If
`$STATE_DIR/events` does not exist, use only their chat text.

## Design Tips

- Scale fidelity to the question
- Explain the question on each page
- Iterate before advancing
- 2-4 options max per screen
- Use real content when it matters
- Keep mockups simple

## File Naming

- Semantic names: `platform.html`, `visual-style.html`, `layout.html`
- Never reuse filenames
- Iterations: `layout-v2.html`
- Server serves newest file by modification time

## Cleaning Up

```bash
skills/brainstorming/scripts/stop-server.sh $SESSION_DIR
```

`--project-dir` mockups persist in `.supersuit/brainstorm/`. Only `/tmp`
sessions are deleted on stop.

## Reference

- Frame template: `skills/brainstorming/scripts/frame-template.html`
- Helper script: `skills/brainstorming/scripts/helper.js`
- Launch / process lifetime: [references/launch-recipes.md](references/launch-recipes.md)
