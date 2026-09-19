---
description: Toggle automatic refreshing of the session diff pane
---

Determine the session id: list directories under `${CLAUDE_PLUGIN_DATA}/sessions/`. If exactly
one exists, use it; otherwise use the most recently modified one. Substitute it for
`<session_id>` below, then toggle its pause marker:

```bash
D="${CLAUDE_PLUGIN_DATA}/sessions/<session_id>"
if [ -e "$D/paused" ]; then rm -f "$D/paused"; echo "resumed"; else touch "$D/paused"; echo "paused"; fi
```

Report whether refreshing is now paused or resumed, in one line.
