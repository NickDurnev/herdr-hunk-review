load helper

setup() {
  setup_scratch
  DIR="$CLAUDE_PLUGIN_DATA/sessions/s1"; mkdir -p "$DIR"
  printf 'patch\n' > "$DIR/combined.patch"
  printf '{}\n'    > "$DIR/agent-context.json"
  STUB="$SCRATCH/bin"; mkdir -p "$STUB"; export PATH="$STUB:$PATH"
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

@test "ensure is silent on stdout" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  run src "hhr_pane_ensure '$DIR'"
  [ -z "$output" ]
}
