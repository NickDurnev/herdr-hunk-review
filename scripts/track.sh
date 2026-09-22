#!/bin/sh
# PostToolUse: record which repo and file an agent touched; snapshot a baseline once per repo.
set -e
. "$(dirname "$0")/common.sh"

payload=$(cat)
hhr_have jq || exit 0

session=$(printf '%s' "$payload" | hhr_json_get session_id)
[ -n "$session" ] || exit 0
dir="$(hhr_state_dir "$session")" || exit 0
hhr_debug_payload "$dir" "$payload"
hhr_guard "$dir"

agent=$(printf '%s' "$payload" | jq -r '.agent_id // "main"')
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')
[ -n "$file" ] || exit 0
[ -e "$file" ] || exit 0

hhr_lock "$dir" || exit 0

state="$dir/state.json"
[ -f "$state" ] || printf '{"repos":{},"agents":{}}' > "$state"

# Resolve the file's directory to its PHYSICAL path first. On macOS /var is a symlink
# to /private/var, and `rev-parse --show-toplevel` always answers physically; if the two
# disagree, Task 5's `startswith($root + "/")` prefix match silently fails.
filedir=$(cd "$(dirname "$file")" 2>/dev/null && pwd -P) || { hhr_unlock "$dir"; exit 0; }
file="$filedir/$(basename "$file")"
# Ask git, never walk for `.git` by hand: in a linked worktree `.git` is a FILE, not a
# directory, so a hand-rolled walk skips the worktree root and may attribute the file to
# an enclosing repo. Worktrees are the primary use case for this plugin.
root=$(git -C "$filedir" rev-parse --show-toplevel 2>/dev/null) || root=
[ -n "$root" ] || { hhr_unlock "$dir"; exit 0; }

# Fallback only: prebaseline.sh (PreToolUse) normally captures this baseline before the
# write lands. This still runs for sessions where PreToolUse never fired (e.g. the plugin
# was enabled mid-session), and it still swallows the first edit — but that beats recording
# nothing for a repo this hook has otherwise never seen.
# Snapshot the baseline the first time this repo is seen.
hhr_capture_repo_baseline "$state" "$root"

jq --arg a "$agent" --arg f "$file" \
   '.agents[$a] = (.agents[$a] // {type:"", output:"", files:[]})
    | .agents[$a].files = ((.agents[$a].files + [$f]) | unique)' \
   "$state" > "$state.tmp" && mv "$state.tmp" "$state"

hhr_unlock "$dir"
exit 0
