#!/bin/sh
# PostToolUse: record which repo and file an agent touched; snapshot a baseline once per repo.
set -e
. "$(dirname "$0")/common.sh"

payload=$(cat)
hhr_have jq || exit 0

session=$(printf '%s' "$payload" | hhr_json_get session_id)
[ -n "$session" ] || exit 0
dir="$(hhr_state_dir "$session")" || exit 0
hhr_guard "$dir"

agent=$(printf '%s' "$payload" | jq -r '.agent_id // "main"')
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')
[ -n "$file" ] || exit 0
[ -e "$file" ] || exit 0

hhr_lock "$dir" || exit 0

state="$dir/state.json"
[ -f "$state" ] || printf '{"repos":{},"agents":{}}' > "$state"

# Find git root by walking up the directory tree, without resolving symlinks.
root=""
search_dir="$(dirname "$file")"
while [ -n "$search_dir" ] && [ "$search_dir" != "/" ]; do
  if [ -d "$search_dir/.git" ]; then
    root="$search_dir"
    break
  fi
  search_dir="$(dirname "$search_dir")"
done

# Only process if we found a repo.
if [ -z "$root" ]; then
  hhr_unlock "$dir"
  exit 0
fi

# Verify it's a valid git repo by running a git command.
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { hhr_unlock "$dir"; exit 0; }

# Snapshot the baseline the first time this repo is seen.
if [ "$(jq -r --arg r "$root" '.repos[$r] // empty' "$state")" = "" ]; then
  base=$(git -C "$root" stash create 2>/dev/null) || base=
  [ -n "$base" ] || base=$(git -C "$root" rev-parse HEAD 2>/dev/null) || base=
  if [ -n "$base" ]; then
    prefix=$(basename "$root")
    n=2
    while [ "$(jq -r --arg p "$prefix" '[.repos[] | select(.prefix == $p)] | length' "$state")" != "0" ]; do
      prefix="$(basename "$root")-$n"
      n=$((n + 1))
    done
    jq --arg r "$root" --arg b "$base" --arg p "$prefix" \
       '.repos[$r] = {baseline:$b, prefix:$p}' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  fi
fi

jq --arg a "$agent" --arg f "$file" \
   '.agents[$a] = (.agents[$a] // {type:"", output:"", files:[]})
    | .agents[$a].files = ((.agents[$a].files + [$f]) | unique)' \
   "$state" > "$state.tmp" && mv "$state.tmp" "$state"

hhr_unlock "$dir"
exit 0
