---
description: Reset the diff baseline so the pane shows only changes from now on
---

Determine the session id: run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/state-root.sh"` to get
the state root, then list directories under it. If exactly one exists, use it; otherwise
use the most recently modified one. Substitute it for `<session_id>` below.

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/baseline.sh" "<session_id>"
```

Report in one line that the baseline was reset and the pane now shows only new changes.
