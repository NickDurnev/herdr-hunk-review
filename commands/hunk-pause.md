---
description: Toggle automatic refreshing of the session diff pane
---

Determine the session id: use the `$CLAUDE_CODE_SESSION_ID` environment variable if
it is set - Claude Code exports it to every Bash tool call, and it matches the
session's state directory name exactly, which the heuristic below cannot guarantee
with several sessions running concurrently. Only if it is unset, fall back to: run
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/state-root.sh"` to get the state root, then list
directories under it - use the single one if exactly one exists, otherwise the most
recently modified. Substitute the result for `<session_id>` below, then toggle its
pause marker:

```bash
ROOT="$(sh "${CLAUDE_PLUGIN_ROOT}/scripts/state-root.sh")" || exit 1
D="$ROOT/<session_id>"
if [ -e "$D/paused" ]; then rm -f "$D/paused"; echo "resumed"; else touch "$D/paused"; echo "paused"; fi
```

If that exits non-zero, `state-root.sh` could not find the plugin's data directory -
report its stderr message verbatim and stop; do not report "paused" or "resumed" for a
resolution failure.

Report whether refreshing is now paused or resumed, in one line.
