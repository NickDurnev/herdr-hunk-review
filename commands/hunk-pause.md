---
description: Toggle automatic refreshing of the session diff pane
---

Determine the session id: run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/state-root.sh"` to get
the state root, then list directories under it. If exactly one exists, use it; otherwise
use the most recently modified one. Substitute it for `<session_id>` below, then toggle
its pause marker:

```bash
D="$(sh "${CLAUDE_PLUGIN_ROOT}/scripts/state-root.sh")/<session_id>"
if [ -e "$D/paused" ]; then rm -f "$D/paused"; echo "resumed"; else touch "$D/paused"; echo "paused"; fi
```

Report whether refreshing is now paused or resumed, in one line.
