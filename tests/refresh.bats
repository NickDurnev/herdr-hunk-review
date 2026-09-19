load helper

setup() {
  setup_scratch
  REPO="$(make_repo "$SCRATCH/repoA")"
  DIR="$CLAUDE_PLUGIN_DATA/sessions/s1"; mkdir -p "$DIR"
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  jq -nc --arg r "$REPO" --arg b "$BASE" \
    '{repos:{($r):{baseline:$b,prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"did the thing",files:[($r + "/tracked.txt")]}}}' \
    > "$DIR/state.json"
  printf 'change\n' >> "$REPO/tracked.txt"
}
teardown() { teardown_scratch; }

@test "produces both artifacts" {
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  [ -s "$DIR/combined.patch" ]
  jq -e '.version == 1' "$DIR/agent-context.json"
}

@test "the note lands on the changed file" {
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  jq -e '.files[0].annotations[0].summary | test("did the thing")' "$DIR/agent-context.json"
}

@test "exits 0 and is silent" {
  run sh "$HHR_ROOT/scripts/refresh.sh" s1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "does nothing while paused" {
  touch "$DIR/paused"
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  [ ! -f "$DIR/combined.patch" ]
}

@test "a repo first touched while paused still produces a correct diff once resumed" {
  # Recording (prebaseline.sh + track.sh) must not be gated on `paused` - only
  # refresh.sh is. Otherwise a repo first touched during a paused stretch never gets a
  # pre-write baseline, and once resumed every edit made while paused is invisible.
  REPO2="$(make_repo "$SCRATCH/repoB")"
  D2="$CLAUDE_PLUGIN_DATA/sessions/s2"
  mkdir -p "$D2"; touch "$D2/paused"

  sh -c 'printf "%s" "$1" | sh "$2/scripts/prebaseline.sh"' _ \
    "$(post_tool_payload s2 a1 "$REPO2/tracked.txt")" "$HHR_ROOT"
  printf 'paused edit\n' >> "$REPO2/tracked.txt"
  sh -c 'printf "%s" "$1" | sh "$2/scripts/track.sh"' _ \
    "$(post_tool_payload s2 a1 "$REPO2/tracked.txt")" "$HHR_ROOT"

  # Still paused: refresh must produce nothing.
  sh "$HHR_ROOT/scripts/refresh.sh" s2
  [ ! -f "$D2/combined.patch" ]

  # Resume: the next refresh must show the edit made while paused.
  rm -f "$D2/paused"
  sh "$HHR_ROOT/scripts/refresh.sh" s2
  [ -s "$D2/combined.patch" ]
  grep -q '^+paused edit' "$D2/combined.patch"
}

@test "still writes artifacts with HERDR_ENV unset" {
  unset HERDR_ENV
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  [ -s "$DIR/combined.patch" ]
  [ ! -f "$DIR/pane" ]
}

@test "concurrent refreshes do not corrupt the patch" {
  sh "$HHR_ROOT/scripts/refresh.sh" s1 &
  sh "$HHR_ROOT/scripts/refresh.sh" s1 &
  wait
  grep -q '^+change' "$DIR/combined.patch"
  [ ! -f "$DIR/.patch.tmp" ]
}

@test "marks watch_stalled when the session snapshot lags the patch" {
  # A session that reports an ancient updatedAt must trigger the fallback exactly once.
  STUB="$SCRATCH/bin"; mkdir -p "$STUB"; export PATH="$STUB:$PATH"
  # cwd is deliberately NOT $DIR: the pane's cwd is now the project directory (see
  # hhr_pane_ensure), so the session lookup must match on sourceLabel instead.
  cat > "$STUB/hunk" <<EOF
#!/bin/sh
[ "\$1 \$2" = "session list" ] && cat <<'JSON'
{"sessions":[{"sessionId":"sid1","cwd":"/private/tmp/elsewhere","sourceLabel":"$DIR/combined.patch","snapshot":{"updatedAt":"2000-01-01T00:00:00.000Z"}}]}
JSON
exit 0
EOF
  chmod +x "$STUB/hunk"
  cat > "$STUB/herdr" <<'EOF'
#!/bin/sh
echo "$@" >> "$HERDR_STUB_LOG"
case "$1 $2" in
  "pane list") echo '{"result":{"panes":[{"pane_id":"w1:p9"}]}}' ;;
  *) echo '{"result":{}}' ;;
esac
EOF
  chmod +x "$STUB/herdr"
  export HERDR_STUB_LOG="$SCRATCH/herdr.log"; : > "$HERDR_STUB_LOG"
  export HERDR_ENV=1
  printf 'w1:p9' > "$DIR/pane"
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  jq -e '.watch_stalled == true' "$DIR/state.json"
  grep -q 'send-keys' "$HERDR_STUB_LOG"
}

@test "watch_stalled is cleared and the pane recreated when the old pane is gone" {
  # watch_stalled is write-once. If the user closes the pane after it stalls, restart
  # (send-keys into a dead pane id) is a permanent no-op and the viewer can never come
  # back - unless the flag is cleared so hhr_pane_ensure gets a chance to recreate it.
  STUB="$SCRATCH/bin"; mkdir -p "$STUB"; export PATH="$STUB:$PATH"
  printf '#!/bin/sh\nexit 0\n' > "$STUB/hunk"; chmod +x "$STUB/hunk"
  cat > "$STUB/herdr" <<'EOF'
#!/bin/sh
echo "$@" >> "$HERDR_STUB_LOG"
case "$1 $2" in
  "pane list")   echo '{"result":{"panes":[]}}' ;;
  "pane layout") echo '{"result":{"layout":{"area":{"width":120,"height":40}}}}' ;;
  "pane split")  echo '{"result":{"pane":{"pane_id":"w1:p1"}}}' ;;
  *) echo '{"result":{}}' ;;
esac
EOF
  chmod +x "$STUB/herdr"
  export HERDR_STUB_LOG="$SCRATCH/herdr.log"; : > "$HERDR_STUB_LOG"
  export HERDR_ENV=1
  jq '.watch_stalled = true' "$DIR/state.json" > "$DIR/t" && mv "$DIR/t" "$DIR/state.json"
  # No $DIR/pane file: the pane the viewer used to live in is gone.
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  [ "$(jq -r '.watch_stalled' "$DIR/state.json")" = "false" ]
  grep -q 'pane split' "$HERDR_STUB_LOG"
  run grep -q 'send-keys' "$HERDR_STUB_LOG"
  [ "$status" -ne 0 ]
}
