#!/bin/sh
# Re-snapshot every tracked repo so the review starts from now.
set -e
here="$(dirname "$0")"
. "$here/common.sh"

session="$1"
[ -n "$session" ] || exit 0
# hhr_state_dir/hhr_state_root already printed a diagnostic to stderr on failure.
# baseline.sh is only ever invoked by a command (no hook calls it - see hooks.json),
# so it must surface that failure rather than exiting 0 as if nothing were wrong.
dir="$(hhr_state_dir "$session")" || exit 1
hhr_have jq || exit 0
state="$dir/state.json"
[ -f "$state" ] || exit 0

hhr_lock "$dir" || exit 0
hhr_reset_repo_baselines "$dir"
hhr_unlock "$dir"

sh "$here/refresh.sh" "$session" || true
exit 0
