---
description: Acknowledge everything the pane currently shows and reset the diff baseline, without closing the pane
---

Determine the session id: use the `$CLAUDE_CODE_SESSION_ID` environment variable if
it is set - Claude Code exports it to every Bash tool call, and it matches the
session's state directory name exactly, which the heuristic below cannot guarantee
with several sessions running concurrently. Only if it is unset, fall back to: run
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/state-root.sh"` to get the state root, then list
directories under it - use the single one if exactly one exists, otherwise the most
recently modified. Substitute the result for `<session_id>` below.

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/baseline.sh" "<session_id>"
```

If the command above (or `state-root.sh`, when it had to be run) exits non-zero, the
plugin's data directory could not be found - report its stderr message verbatim and
stop; do not report the baseline as reset when it was not.

This is the same acknowledgment that happens automatically when the user closes the
pane (see the README's "Closing the pane" section) - this command does it explicitly,
on demand, without requiring the pane to be closed first.

Report in one line that the baseline was reset: everything shown so far has been
acknowledged and won't reappear in the pane, but nothing was discarded - the changes
themselves are still in the working tree and in git, and can always be diffed by hand.
