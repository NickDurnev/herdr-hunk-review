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
