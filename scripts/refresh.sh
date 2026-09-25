#!/bin/sh
# Regenerate the patch and sidecar, then make sure a viewer is showing them.
# Usage: refresh.sh <session_id> [force]
# `force` clears the "shown.patch" marker before hhr_pane_ensure runs, so a pane the
# user closed reopens regardless of whether anything changed since it was closed - this
# is how /herdr-hunk-review:hunk-review always opens the pane when there is something to show. It does
# NOT override the separate empty-patch guard below: with nothing to show (every repo
# at its baseline), no pane opens, forced or not.
set -e
here="$(dirname "$0")"
. "$here/common.sh"
. "$here/patch.sh"
. "$here/sidecar.sh"
. "$here/pane.sh"

session="$1"
force="$2"
[ -n "$session" ] || exit 0
# hhr_state_dir/hhr_state_root already printed a diagnostic to stderr on failure.
# Exit non-zero (not 0) here: a hook invocation never reaches this branch (its
# CLAUDE_PLUGIN_DATA is always set, so resolution always succeeds - see hhr_state_root),
# so the only caller who CAN see this exit code is a command, which must be told
# resolution failed rather than reading a silent, misleading exit 0.
dir="$(hhr_state_dir "$session")" || exit 1
hhr_guard "$dir"
# Refreshing (and only refreshing) stops while paused; recording still happens via
# prebaseline.sh/track.sh/note.sh regardless, so nothing edited while paused is lost.
[ -e "$dir/paused" ] && exit 0

# A refresh already in flight will pick up our writes; skipping is correct, not a loss.
hhr_lock "$dir" || exit 0
# shellcheck disable=SC2064
trap "hhr_unlock '$dir'" EXIT INT TERM

hhr_build_patch "$dir"
hhr_build_sidecar "$dir"
# The empty-patch guard. `force` NEVER bypasses this - it exists to defeat the
# `shown.patch` marker below, not this check. An empty patch means every tracked repo
# is at its baseline (most commonly: the close-acknowledgment path in hhr_pane_ensure
# just ran, or /herdr-hunk-review:hunk-baseline just ran), so there is nothing to put in a pane; keep
# this as its own early exit rather than folding it into the `force` condition below,
# or a later change to one will silently change the other.
[ -s "$dir/combined.patch" ] || exit 0

if [ "$(jq -r '.watch_stalled // false' "$dir/state.json" 2>/dev/null)" = "true" ]; then
  if [ -f "$dir/pane" ] && hhr_pane_alive "$(cat "$dir/pane")"; then
    hhr_pane_restart "$dir"
    exit 0
  fi
  # The pane the viewer used to live in is gone (the user closed it, or none ever
  # opened). watch_stalled is write-once and there is nothing left to restart, so clear
  # it and fall through to hhr_pane_ensure below - otherwise every future refresh keeps
  # taking this branch and the viewer can never come back.
  jq '.watch_stalled = false' "$dir/state.json" > "$dir/.s.tmp" && mv "$dir/.s.tmp" "$dir/state.json"
fi

# The shown.patch guard. This is the ONLY thing `force` bypasses: it clears
# shown.patch so hhr_pane_ensure cannot read "pane gone AND content == shown.patch" and
# treat the closed pane as acknowledged - by this point the empty-patch guard above has
# already vouched that there is real content to show.
[ "$force" = "force" ] && rm -f "$dir/shown.patch"
hhr_pane_ensure "$dir"

# Detect a watch that is not reloading: the live session should be no older than the patch.
sid="$(hhr_session_id "$dir")"
if [ -n "$sid" ]; then
  patch_mtime=$(hhr_patch_mtime "$dir")
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
