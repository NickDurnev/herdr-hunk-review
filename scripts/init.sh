#!/bin/sh
# SessionStart: create the state directory so later hooks never race on it.
set -e
. "$(dirname "$0")/common.sh"
payload=$(cat)
hhr_have jq || exit 0
session=$(printf '%s' "$payload" | hhr_json_get session_id)
[ -n "$session" ] || exit 0
dir="$(hhr_state_dir "$session")" || exit 0
# Lock before writing: this runs async and can otherwise interleave with the
# synchronous prebaseline.sh on the very first edit, truncating a just-written
# baseline back to the empty skeleton.
if hhr_lock "$dir"; then
  [ -f "$dir/state.json" ] || printf '{"repos":{},"agents":{}}' > "$dir/state.json"
  hhr_unlock "$dir"
fi
exit 0
