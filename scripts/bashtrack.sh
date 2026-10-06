#!/bin/sh
# PostToolUse (Bash): compare each repo bashpre.sh snapshotted against its state now.
# A repo the command changed is recorded exactly as an Edit would record it - baseline
# (the pre-command snapshot, so the change itself stays visible) and the changed files
# under the calling agent, which also lets patch.sh show files the command created.
set -e
. "$(dirname "$0")/common.sh"

payload=$(cat)
hhr_have jq || exit 0

session=$(printf '%s' "$payload" | hhr_json_get session_id)
[ -n "$session" ] || exit 0
id=$(printf '%s' "$payload" | jq -r '.tool_use_id // empty' | tr -cd 'A-Za-z0-9_-')
[ -n "$id" ] || exit 0
dir="$(hhr_state_dir "$session")" || exit 0
hhr_guard "$dir"

pend="$dir/bash"
snaps="$pend/$id.tsv"
[ -f "$snaps" ] || exit 0
agent=$(printf '%s' "$payload" | jq -r '.agent_id // "main"')

changed="$pend/$id.changed"
: > "$changed"
while IFS="$(printf '\t')" read -r root base dirty ufile; do
  [ -d "$root" ] || continue
  # Tracked files that differ from the snapshot - including ones the command went on
  # to commit, since a plain `git diff <base>` reads the working tree. On the
  # stash-create-failed fallback the snapshot is HEAD, which does not fold in the
  # pre-existing dirty paths, so those are subtracted here as patch.sh does.
  # Submodule pointers are ignored for the same reason patch.sh ignores them.
  printf '%s' "$dirty" | jq -r '.[]?' 2>/dev/null > "$pend/$id.dirty" || : > "$pend/$id.dirty"
  git -C "$root" diff --ignore-submodules=all --name-only "$base" 2>/dev/null | grep -vxF -f "$pend/$id.dirty" > "$pend/$id.files" || :
  # Untracked files that did not exist before the command ran.
  git -C "$root" ls-files --others --exclude-standard 2>/dev/null | sort \
    | comm -13 "$ufile" - >> "$pend/$id.files" 2>/dev/null || :
  [ -s "$pend/$id.files" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] && printf '%s\t%s\t%s\t%s\n' "$root" "$base" "$dirty" "$root/$f"
  done < "$pend/$id.files" >> "$changed"
done < "$snaps"

if [ -s "$changed" ] && hhr_lock "$dir"; then
  state="$dir/state.json"
  [ -f "$state" ] || printf '{"repos":{},"agents":{}}' > "$state"
  while IFS="$(printf '\t')" read -r root base dirty f; do
    hhr_record_repo_baseline "$state" "$root" "$base" "$dirty"
    jq --arg a "$agent" --arg f "$f" \
       '.agents[$a] = (.agents[$a] // {type:"", output:"", files:[]})
        | .agents[$a].files = ((.agents[$a].files + [$f]) | unique)' \
       "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  done < "$changed"
  hhr_unlock "$dir"
fi

# Snapshot files are per call; remove them whether or not anything changed.
while IFS="$(printf '\t')" read -r _ _ _ ufile; do rm -f "$ufile"; done < "$snaps"
rm -f "$snaps" "$changed" "$pend/$id.files" "$pend/$id.dirty"
exit 0
