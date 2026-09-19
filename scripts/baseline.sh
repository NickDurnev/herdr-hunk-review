#!/bin/sh
# Re-snapshot every tracked repo so the review starts from now.
set -e
here="$(dirname "$0")"
. "$here/common.sh"

session="$1"
[ -n "$session" ] || exit 0
dir="$(hhr_state_dir "$session")" || exit 0
hhr_have jq || exit 0
state="$dir/state.json"
[ -f "$state" ] || exit 0

hhr_lock "$dir" || exit 0
# A bare `for root in $(jq ...)` word-splits on spaces in the repo path; read the
# keys from a file instead, one per line, like hhr_build_patch does.
reposlist="$dir/.baseline.repos.tmp"
jq -r '.repos | keys[]' "$state" > "$reposlist"
while IFS= read -r root; do
  [ -d "$root" ] || continue
  base=$(git -C "$root" stash create 2>/dev/null) || base=
  [ -n "$base" ] || base=$(git -C "$root" rev-parse HEAD 2>/dev/null) || continue
  jq --arg r "$root" --arg b "$base" '.repos[$r].baseline = $b' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
done < "$reposlist"
rm -f "$reposlist"
jq '.agents = {}' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
hhr_unlock "$dir"

sh "$here/refresh.sh" "$session" || true
exit 0
