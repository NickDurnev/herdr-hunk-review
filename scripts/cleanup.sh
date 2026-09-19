#!/bin/sh
# SessionEnd: close the pane this session opened. Without this, every session that
# ever ran a viewer leaves a pane behind. SessionEnd has roughly a 1.5-second total
# budget across all hooks, so this stays deliberately minimal: no sleep, no retries,
# one jq call, and every path exits 0 whether or not herdr/hunk are even installed.
set -e
here="$(dirname "$0")"
. "$here/common.sh"

payload=$(cat)
hhr_have jq || exit 0

session=$(printf '%s' "$payload" | hhr_json_get session_id)
[ -n "$session" ] || exit 0

# Read-only: never mkdir here (hhr_state_dir would), a torn-down session has nothing
# left to create.
dir="$(hhr_state_root)/$session"
[ -f "$dir/pane" ] || exit 0
command -v herdr >/dev/null 2>&1 || { rm -f "$dir/pane"; exit 0; }

pane=$(cat "$dir/pane" 2>/dev/null) || exit 0
if [ -n "$pane" ]; then
  # pane close on a live TUI can leave the process running, so quit it first.
  herdr pane send-keys "$pane" q >/dev/null 2>&1 || true
  herdr pane close "$pane" >/dev/null 2>&1 || true
fi
rm -f "$dir/pane"
exit 0
