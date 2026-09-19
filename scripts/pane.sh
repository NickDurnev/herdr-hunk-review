# Sourced. Owns the herdr pane running the hunk viewer.

hhr_viewer_cmd() {
  printf 'hunk patch %s/combined.patch --agent-context %s/agent-context.json --agent-notes --watch' "$1" "$1"
}

hhr_pane_alive() {
  [ -n "$1" ] || return 1
  herdr pane list 2>/dev/null | jq -e --arg p "$1" '[.result.panes[].pane_id] | index($p)' >/dev/null 2>&1
}

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
      return 0
    fi
    hhr_pane_restart "$dir"
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
