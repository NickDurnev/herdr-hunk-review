load helper

setup() {
  setup_scratch
  DIR="$CLAUDE_PLUGIN_DATA/sessions/s1"; mkdir -p "$DIR"
  printf 'patch\n' > "$DIR/combined.patch"
  printf '{}\n'    > "$DIR/agent-context.json"
  STUB="$SCRATCH/bin"; mkdir -p "$STUB"; export PATH="$STUB:$PATH"
  # Stub BOTH binaries: hhr_pane_ensure legitimately guards on each, so a suite that
  # stubs only herdr would force the guard on hunk to be removed just to stay green.
  # hunk's "session list" reads $HHR_TEST_SESSIONS so each test can express "a
  # session exists" (set it) vs "no session exists" (leave it unset/empty) without
  # rewriting the stub. Default (set below) is a session whose sourceLabel matches
  # this $DIR, so tests that don't care see a genuinely live viewer.
  cat > "$STUB/hunk" <<'EOF'
#!/bin/sh
echo "hunk $@" >> "$HERDR_STUB_LOG"
if [ "$1 $2" = "session list" ]; then
  if [ -n "$HHR_TEST_SESSIONS" ]; then
    printf '%s' "$HHR_TEST_SESSIONS"
  else
    printf '%s' '{"sessions":[]}'
  fi
fi
exit 0
EOF
  chmod +x "$STUB/hunk"
  cat > "$STUB/herdr" <<'EOF'
#!/bin/sh
echo "$@" >> "$HERDR_STUB_LOG"
case "$1 $2" in
  "pane split") echo '{"result":{"pane":{"pane_id":"w1:p9"}}}' ;;
  "pane list")  echo '{"result":{"panes":[{"pane_id":"w1:p9"}]}}' ;;
  "pane layout") echo '{"result":{"layout":{"area":{"width":200,"height":50}}}}' ;;
  *) echo '{"result":{}}' ;;
esac
EOF
  chmod +x "$STUB/herdr"
  export HERDR_STUB_LOG="$SCRATCH/herdr.log"; : > "$HERDR_STUB_LOG"
  export HHR_TEST_SESSIONS="$(printf '{"sessions":[{"cwd":"/private/tmp/elsewhere","sourceLabel":"%s/combined.patch","sessionId":"sess-live"}]}' "$DIR")"
}
teardown() { teardown_scratch; }

src() { sh -c ". \"$HHR_ROOT/scripts/pane.sh\"; $1" ; }

@test "viewer command includes agent-notes and watch" {
  run src "hhr_viewer_cmd '$DIR'"
  [ "$status" -eq 0 ]
  case "$output" in *"--agent-notes"*) : ;; *) false ;; esac
  case "$output" in *"--watch"*) : ;; *) false ;; esac
  case "$output" in *"combined.patch"*) : ;; *) false ;; esac
  case "$output" in *"agent-context.json"*) : ;; *) false ;; esac
}

@test "ensure does nothing when HERDR_ENV is unset" {
  unset HERDR_ENV
  run src "hhr_pane_ensure '$DIR'"
  [ "$status" -eq 0 ]
  [ ! -f "$DIR/pane" ]
}

@test "ensure creates a pane and stores its id when inside herdr" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  src "hhr_pane_ensure '$DIR'"
  [ "$(cat "$DIR/pane")" = "w1:p9" ]
  grep -q 'pane split' "$HERDR_STUB_LOG"
  grep -q 'no-focus'   "$HERDR_STUB_LOG"
}

@test "ensure reuses an existing live pane" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  printf 'w1:p9' > "$DIR/pane"
  src "hhr_pane_ensure '$DIR'"
  ! grep -q 'pane split' "$HERDR_STUB_LOG"
}

@test "restart sends q before running the viewer" {
  export HERDR_ENV=1
  printf 'w1:p9' > "$DIR/pane"
  src "hhr_pane_restart '$DIR'"
  # send-keys must be logged before pane run
  q_line=$(grep -n 'send-keys' "$HERDR_STUB_LOG" | head -1 | cut -d: -f1)
  r_line=$(grep -n 'pane run'  "$HERDR_STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$q_line" ] && [ -n "$r_line" ] && [ "$q_line" -lt "$r_line" ]
}

@test "ensure opens no pane when hunk is not installed" {
  # The spec promises a missing hunk degrades to "a valid patch file any diff viewer
  # can open" — not to a pane running a command that does not exist.
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  rm -f "$STUB/hunk"
  # A dev machine may have a real hunk elsewhere on PATH (e.g. Homebrew); strip its
  # directory too so this actually exercises "hunk not installed", not just "not stubbed".
  if hpath=$(command -v hunk 2>/dev/null); then
    hdir=$(dirname "$hpath")
    PATH=$(printf '%s' "$PATH" | awk -v d="$hdir" 'BEGIN{RS=":"} $0!=d{printf "%s:", $0}' | sed 's/:$//')
    export PATH
  fi
  src "hhr_pane_ensure '$DIR'"
  [ ! -f "$DIR/pane" ]
  run grep -q 'pane split' "$HERDR_STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "ensure is silent on stdout" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  run src "hhr_pane_ensure '$DIR'"
  [ -z "$output" ]
}

@test "split is requested with the project directory, never the state directory" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  proj="$(pwd)"
  src "hhr_pane_ensure '$DIR'"
  grep -q 'pane split' "$HERDR_STUB_LOG"
  grep -F -- "--cwd $proj" "$HERDR_STUB_LOG"
  run grep -F -- "--cwd $DIR" "$HERDR_STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "hhr_session_id finds a session whose cwd differs from the state dir but sourceLabel matches" {
  export HHR_TEST_SESSIONS="$(printf '{"sessions":[{"cwd":"/private/tmp/elsewhere","sourceLabel":"%s/combined.patch","sessionId":"sess-42"}]}' "$DIR")"
  run src "hhr_session_id '$DIR'"
  [ "$status" -eq 0 ]
  [ "$output" = "sess-42" ]
}

@test "hhr_session_id does not match a session belonging to a different state dir" {
  other="$CLAUDE_PLUGIN_DATA/sessions/s-other"
  export HHR_TEST_SESSIONS="$(printf '{"sessions":[{"cwd":"/private/tmp/elsewhere","sourceLabel":"%s/combined.patch","sessionId":"sess-99"}]}' "$other")"
  run src "hhr_session_id '$DIR'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a stored pane that exists but has no live viewer is relaunched rather than silently reused" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  printf 'w1:p9' > "$DIR/pane"
  export HHR_TEST_SESSIONS='{"sessions":[]}'
  src "hhr_pane_ensure '$DIR'"
  run grep -q 'pane split' "$HERDR_STUB_LOG"
  [ "$status" -ne 0 ]
  q_line=$(grep -n 'send-keys' "$HERDR_STUB_LOG" | head -1 | cut -d: -f1)
  r_line=$(grep -n 'pane run'  "$HERDR_STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$q_line" ] && [ -n "$r_line" ] && [ "$q_line" -lt "$r_line" ]
}

@test "a stored pane with a live viewer is reused without splitting or relaunching" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  printf 'w1:p9' > "$DIR/pane"
  # HHR_TEST_SESSIONS keeps the setup default: a session matching this DIR.
  src "hhr_pane_ensure '$DIR'"
  run grep -q 'pane split' "$HERDR_STUB_LOG"
  [ "$status" -ne 0 ]
  run grep -q 'send-keys' "$HERDR_STUB_LOG"
  [ "$status" -ne 0 ]
  run grep -q 'pane run' "$HERDR_STUB_LOG"
  [ "$status" -ne 0 ]
}

@test "cleanup.sh sends q before close, and removes the pane file" {
  export HERDR_ENV=1
  printf 'w1:p9' > "$DIR/pane"
  run sh -c 'printf "%s" "$1" | sh "$2/scripts/cleanup.sh"' _ "$(session_end_payload s1)" "$HHR_ROOT"
  [ "$status" -eq 0 ]
  [ ! -f "$DIR/pane" ]
  q_line=$(grep -n 'send-keys'   "$HERDR_STUB_LOG" | head -1 | cut -d: -f1)
  c_line=$(grep -n 'pane close'  "$HERDR_STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$q_line" ] && [ -n "$c_line" ] && [ "$q_line" -lt "$c_line" ]
}

@test "cleanup.sh exits 0 and is silent when there is no pane file" {
  rm -f "$DIR/pane"
  run sh -c 'printf "%s" "$1" | sh "$2/scripts/cleanup.sh"' _ "$(session_end_payload s1)" "$HHR_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
