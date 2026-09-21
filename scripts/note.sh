#!/bin/sh
# SubagentStop: keep the subagent's closing report, then refresh.
set -e
here="$(dirname "$0")"
. "$here/common.sh"

payload=$(cat)
hhr_have jq || exit 0

session=$(printf '%s' "$payload" | hhr_json_get session_id)
[ -n "$session" ] || exit 0
dir="$(hhr_state_dir "$session")" || exit 0
hhr_debug_payload "$dir" "$payload"
hhr_guard "$dir"

agent=$(printf '%s' "$payload" | jq -r '.agent_id // empty')
[ -n "$agent" ] || exit 0
atype=$(printf '%s' "$payload" | jq -r '.agent_type // "agent"')
output=$(printf '%s' "$payload" | jq -r '.agent_output // ""')

state="$dir/state.json"
[ -f "$state" ] || printf '{"repos":{},"agents":{}}' > "$state"

if hhr_lock "$dir"; then
  jq --arg a "$agent" --arg t "$atype" --arg o "$output" \
     '.agents[$a] = (.agents[$a] // {type:"", output:"", files:[]})
      | .agents[$a].type = $t
      | .agents[$a].output = $o' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  hhr_unlock "$dir"
fi

sh "$here/refresh.sh" "$session" || true
exit 0
