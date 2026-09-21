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
hhr_reset_repo_baselines "$dir"
hhr_unlock "$dir"

sh "$here/refresh.sh" "$session" || true
exit 0
