#!/bin/sh
# PreToolUse: snapshot the repo baseline BEFORE the write lands. PostToolUse is too
# late — by then `git stash create` would capture the very edit we want to exclude.
set -e
. "$(dirname "$0")/common.sh"

payload=$(cat)
hhr_have jq || exit 0

session=$(printf '%s' "$payload" | hhr_json_get session_id)
[ -n "$session" ] || exit 0
dir="$(hhr_state_dir "$session")" || exit 0
hhr_guard "$dir"

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')
[ -n "$file" ] || exit 0

# The target may not exist yet (a Write creating a new file, possibly in a new
# directory), so walk up to the nearest existing ancestor before asking git.
d="$(dirname "$file")"
while [ ! -d "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ] && [ -n "$d" ]; do
  d="$(dirname "$d")"
done
[ -d "$d" ] || exit 0
filedir=$(cd "$d" 2>/dev/null && pwd -P) || exit 0
root=$(git -C "$filedir" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0

hhr_lock "$dir" || exit 0
state="$dir/state.json"
[ -f "$state" ] || printf '{"repos":{},"agents":{}}' > "$state"

hhr_capture_repo_baseline "$state" "$root"

hhr_unlock "$dir"
exit 0
