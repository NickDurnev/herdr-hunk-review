---
description: Refresh the session diff pane now and open it if needed
---

Determine the session id: use the `$CLAUDE_CODE_SESSION_ID` environment variable if
it is set - Claude Code exports it to every Bash tool call, and it matches the
session's state directory name exactly, which the heuristic below cannot guarantee
with several sessions running concurrently. Only if it is unset, fall back to: run
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/state-root.sh"` to get the state root, then list
directories under it - use the single one if exactly one exists, otherwise the most
recently modified. Substitute the result for `<session_id>` below.

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/refresh.sh" "<session_id>" force
```

The `force` argument makes this bypass the "user closed it deliberately" check, so a
closed pane reopens even though nothing changed since it was closed. It does NOT
override the separate empty-patch guard: if there is nothing to show at all (for
example, right after the user closed the pane and the plugin acknowledged it, or right
after `/herdr-hunk-review:hunk-baseline`), no pane opens - there would be nothing in it to show.

If the command above (or `state-root.sh`, when it had to be run) exits non-zero, the
plugin's data directory could not be found - report its stderr message verbatim and
stop; do not report "no changes to review" for a resolution failure.

Then report one line:
- If `<dir>/combined.patch` is empty or missing: say there are no changes to review
  since the last acknowledgment, and no pane was opened - closing the pane acknowledges
  its diff, so this usually just means everything so far has already been acknowledged.
- Otherwise: how many files and repos the patch contains.

If `HERDR_ENV` is not `1`, also print the command the user should run in another
terminal, with the real session directory filled in for `<dir>`:

```
hunk patch <dir>/combined.patch --agent-context <dir>/agent-context.json --agent-notes --watch
```
