---
description: Acknowledge everything the pane currently shows and reset the diff baseline, without closing the pane
---

Determine the session id: run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/state-root.sh"` to get
the state root, then list directories under it. If exactly one exists, use it; otherwise
use the most recently modified one. Substitute it for `<session_id>` below.

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/baseline.sh" "<session_id>"
```

This is the same acknowledgment that happens automatically when the user closes the
pane (see the README's "Closing the pane" section) - this command does it explicitly,
on demand, without requiring the pane to be closed first.

Report in one line that the baseline was reset: everything shown so far has been
acknowledged and won't reappear in the pane, but nothing was discarded - the changes
themselves are still in the working tree and in git, and can always be diffed by hand.
