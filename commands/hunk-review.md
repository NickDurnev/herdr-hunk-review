---
description: Refresh the session diff pane now and open it if needed
---

Determine the session id: run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/state-root.sh"` to get
the state root, then list directories under it. If exactly one exists, use it; otherwise
use the most recently modified one. Substitute it for `<session_id>` below.

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/refresh.sh" "<session_id>"
```

Then report one line: how many files and repos the patch contains.

If `HERDR_ENV` is not `1`, also print the command the user should run in another
terminal, with the real session directory filled in for `<dir>`:

```
hunk patch <dir>/combined.patch --agent-context <dir>/agent-context.json --agent-notes --watch
```
