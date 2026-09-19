#!/bin/sh
# Regenerate the patch and sidecar, then make sure a viewer is showing them.
# Usage: refresh.sh <session_id>
set -e
here="$(dirname "$0")"
. "$here/common.sh"
. "$here/patch.sh"
. "$here/sidecar.sh"
. "$here/pane.sh"

session="$1"
[ -n "$session" ] || exit 0
dir="$(hhr_state_dir "$session")" || exit 0
hhr_guard "$dir"

# A refresh already in flight will pick up our writes; skipping is correct, not a loss.
hhr_lock "$dir" || exit 0
# shellcheck disable=SC2064
trap "hhr_unlock '$dir'" EXIT INT TERM

hhr_build_patch "$dir"
hhr_build_sidecar "$dir"
[ -s "$dir/combined.patch" ] || exit 0

if [ "$(jq -r '.watch_stalled // false' "$dir/state.json" 2>/dev/null)" = "true" ]; then
  hhr_pane_restart "$dir"
  exit 0
fi

hhr_pane_ensure "$dir"

# Detect a watch that is not reloading: the live session should be no older than the patch.
sid="$(hhr_session_id "$dir")"
if [ -n "$sid" ]; then
  patch_mtime=$(stat -f %m "$dir/combined.patch" 2>/dev/null || stat -c %Y "$dir/combined.patch" 2>/dev/null || echo 0)
  updated=$(hunk session list --json 2>/dev/null \
            | jq -r --arg s "$sid" '.sessions[] | select(.sessionId == $s) | .snapshot.updatedAt // empty')
  if [ -n "$updated" ]; then
    # updatedAt is ISO-8601 UTC (trailing Z). BSD `date -j -f` has no way to say "parse
    # this as UTC" other than running it with TZ=UTC, so without that the naive
    # wall-clock string gets reinterpreted in the local zone and the epoch comes out
    # skewed by the local UTC offset (hours) - fatal against a 10s staleness threshold.
    # GNU `date -d` already understands the trailing Z and needs no such override.
    sess_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$(printf '%s' "$updated" | cut -d. -f1)" +%s 2>/dev/null \
                 || date -d "$updated" +%s 2>/dev/null || echo 0)
    if [ "$sess_epoch" -gt 0 ] && [ $((patch_mtime - sess_epoch)) -gt 10 ]; then
      jq '.watch_stalled = true' "$dir/state.json" > "$dir/.s.tmp" && mv "$dir/.s.tmp" "$dir/state.json"
      hhr_pane_restart "$dir"
    fi
  fi
fi
exit 0
