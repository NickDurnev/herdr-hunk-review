# Sourced. Owns the herdr pane running the hunk viewer.

hhr_viewer_cmd() {
  printf 'hunk patch %s/combined.patch --agent-context %s/agent-context.json --agent-notes --watch' "$1" "$1"
}

hhr_pane_alive() {
  [ -n "$1" ] || return 1
  herdr pane list 2>/dev/null | jq -e --arg p "$1" '[.result.panes[].pane_id] | index($p)' >/dev/null 2>&1
}

hhr_patch_mtime() {
  stat -f %m "$1/combined.patch" 2>/dev/null || stat -c %Y "$1/combined.patch" 2>/dev/null || echo 0
}

# Snapshot combined.patch as "what the pane is currently displaying". A full copy, not
# a timestamp: `stat`'s mtime is second-resolution, so two patch rewrites inside the
# same wall-clock second are indistinguishable by mtime even though their content
# differs - the same failure mode `cmp -s` already exists to dodge in patch.sh (see its
# header comment on why a hash isn't used either). combined.patch is capped at
# HHR_MAX_PATCH_BYTES (5MB, see patch.sh), so the extra copy is bounded - do not
# "optimise" this back to a timestamp or hash; that reintroduces the same-second bug.
hhr_mark_shown() { cp "$1/combined.patch" "$1/shown.patch" 2>/dev/null || true; }

hhr_pane_ensure() {
  dir="$1"
  [ "${HERDR_ENV:-}" = 1 ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  command -v hunk  >/dev/null 2>&1 || return 0
  [ -s "$dir/combined.patch" ] || return 0

  if [ -f "$dir/pane" ] && hhr_pane_alive "$(cat "$dir/pane")"; then
    # A pane can exist but be an empty shell if the hunk process inside it already
    # exited (crash, `q`, `hunk session` reaped). A live patch session is the signal
    # the viewer is actually running, so check that before trusting the pane.
    if [ -n "$(hhr_session_id "$dir")" ]; then
      hhr_mark_shown "$dir"
      return 0
    fi
    hhr_pane_restart "$dir"
    hhr_mark_shown "$dir"
    return 0
  fi

  # The pane is gone. An identical shown.patch means nothing landed since the close:
  # the user closed it deliberately. A different (or missing) shown.patch means either
  # new content landed or the pane has never been opened, so fall through and (re)open
  # it.
  if [ -f "$dir/shown.patch" ] && cmp -s "$dir/combined.patch" "$dir/shown.patch"; then
    # Closing the pane means "I have reviewed this; don't show it to me again". The
    # close is only detected here, one refresh later than it actually happened - but
    # the caller (refresh.sh) already rebuilt combined.patch just before calling us, so
    # an exact content match against shown.patch proves nothing landed between the
    # close and this detection: the snapshot taken right now is identical to one taken
    # at the moment of the close. Acknowledge it exactly like /hunk-baseline does, then
    # regenerate the patch and sidecar so disk state matches the new (empty) baseline,
    # and drop shown.patch since it no longer describes anything that was ever
    # displayed.
    #
    # No lock here: hhr_reset_repo_baselines/hhr_build_patch/hhr_build_sidecar are safe
    # to call unlocked because refresh.sh already holds the state-dir lock for the
    # whole duration of this call - locking again would deadlock against ourselves.
    hhr_reset_repo_baselines "$dir"
    hhr_build_patch "$dir"
    hhr_build_sidecar "$dir"
    rm -f "$dir/shown.patch"
    return 0
  fi

  # Split the long side so neither pane becomes unusably narrow.
  w=$(herdr pane layout --current 2>/dev/null | jq -r '.result.layout.area.width // 120')
  h=$(herdr pane layout --current 2>/dev/null | jq -r '.result.layout.area.height // 40')
  if [ "$w" -gt $((h * 3)) ] 2>/dev/null; then direction=right; else direction=down; fi

  # Split with the PROJECT directory, never the per-session state dir: state dirs are
  # cleaned up independently of pane lifetime, and a pane whose cwd is later deleted
  # becomes a permanently broken shell ("the current working directory was deleted").
  # hhr_viewer_cmd only ever emits absolute paths, so the pane's cwd doesn't matter
  # to the command it runs.
  pane=$(herdr pane split --current --direction "$direction" --cwd "$PWD" --no-focus 2>/dev/null \
         | jq -r '.result.pane.pane_id // empty')
  [ -n "$pane" ] || return 0
  printf '%s' "$pane" > "$dir/pane"
  herdr pane run "$pane" "$(hhr_viewer_cmd "$dir")" >/dev/null 2>&1 || true
  hhr_mark_shown "$dir"
  return 0
}

hhr_pane_restart() {
  dir="$1"
  [ -f "$dir/pane" ] || return 0
  pane=$(cat "$dir/pane")
  # pane run types into whatever occupies the pane, so the TUI must be quit first.
  herdr pane send-keys "$pane" q >/dev/null 2>&1 || true
  sleep 1
  herdr pane run "$pane" "$(hhr_viewer_cmd "$dir")" >/dev/null 2>&1 || true
  return 0
}

hhr_session_id() {
  # Match on sourceLabel, not cwd: cwd is the pane's cwd (now the project dir, not
  # this state dir - see hhr_pane_ensure), but sourceLabel is the patch path exactly
  # as passed on the command line, which hhr_viewer_cmd builds from this same $1.
  command -v hunk >/dev/null 2>&1 || return 0
  hunk session list --json 2>/dev/null \
    | jq -r --arg l "$1/combined.patch" '.sessions[] | select(.sourceLabel == $l) | .sessionId' 2>/dev/null | head -1
}
