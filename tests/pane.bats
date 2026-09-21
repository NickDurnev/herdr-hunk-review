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

# Source in the same order refresh.sh does: hhr_pane_ensure's close-acknowledgment
# branch calls hhr_reset_repo_baselines (common.sh), hhr_build_patch (patch.sh) and
# hhr_build_sidecar (sidecar.sh), so a bare `. pane.sh` here would silently no-op those
# calls ("command not found", swallowed since nothing in this harness runs under
# `set -e`) and a test could pass for the wrong reason.
src() { sh -c ". \"$HHR_ROOT/scripts/common.sh\"; . \"$HHR_ROOT/scripts/patch.sh\"; . \"$HHR_ROOT/scripts/sidecar.sh\"; . \"$HHR_ROOT/scripts/pane.sh\"; $1" ; }

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
  # A dev machine may have a real hunk elsewhere on PATH (e.g. Homebrew), and
  # setup_scratch also puts an inert default-bin stub on PATH as a safety net -
  # loop, not `if`, so every directory that resolves a hunk gets stripped, not
  # just the first, so this actually exercises "hunk not installed", not just
  # "not stubbed".
  while hpath=$(command -v hunk 2>/dev/null); do
    hdir=$(dirname "$hpath")
    PATH=$(printf '%s' "$PATH" | awk -v d="$hdir" 'BEGIN{RS=":"} $0!=d{printf "%s:", $0}' | sed 's/:$//')
    export PATH
  done
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

@test "ensure acknowledges and stays closed when the pane is gone and the patch has not changed since it was shown" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  export HHR_TEST_SESSIONS='{"sessions":[]}'
  # No repos to re-baseline - just enough state.json for hhr_reset_repo_baselines and
  # hhr_build_patch to run without erroring; the close-acknowledgment flow itself
  # (against real repos) is covered end-to-end in refresh.bats/baseline.bats.
  jq -nc '{repos:{},agents:{}}' > "$DIR/state.json"
  cp "$DIR/combined.patch" "$DIR/shown.patch"
  src "hhr_pane_ensure '$DIR'"
  [ ! -f "$DIR/pane" ]
  run grep -q 'pane split' "$HERDR_STUB_LOG"
  [ "$status" -ne 0 ]
  # Acknowledged: the patch was rebuilt (zero repos -> empty) and shown.patch dropped.
  [ ! -s "$DIR/combined.patch" ]
  [ ! -f "$DIR/shown.patch" ]
}

@test "ensure reopens and updates shown.patch when the patch changed since it was last shown" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  export HHR_TEST_SESSIONS='{"sessions":[]}'
  printf 'a different patch\n' > "$DIR/shown.patch"
  src "hhr_pane_ensure '$DIR'"
  [ "$(cat "$DIR/pane")" = "w1:p9" ]
  grep -q 'pane split' "$HERDR_STUB_LOG"
  run cmp -s "$DIR/combined.patch" "$DIR/shown.patch"
  [ "$status" -eq 0 ]
}

@test "ensure has no shown.patch to compare against on the very first display, and opens the pane" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  export HHR_TEST_SESSIONS='{"sessions":[]}'
  src "hhr_pane_ensure '$DIR'"
  [ "$(cat "$DIR/pane")" = "w1:p9" ]
  grep -q 'pane split' "$HERDR_STUB_LOG"
  run cmp -s "$DIR/combined.patch" "$DIR/shown.patch"
  [ "$status" -eq 0 ]
}

@test "ensure refreshes shown.patch to the current content when the pane is alive" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  printf 'w1:p9' > "$DIR/pane"
  # HHR_TEST_SESSIONS keeps the setup default: a session matching this DIR, so the
  # viewer reads as alive.
  src "hhr_pane_ensure '$DIR'"
  run cmp -s "$DIR/combined.patch" "$DIR/shown.patch"
  [ "$status" -eq 0 ]
}

@test "clearing shown.patch (what refresh.sh's force argument does) reopens the pane even when the patch is unchanged" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
  export HHR_TEST_SESSIONS='{"sessions":[]}'
  cp "$DIR/combined.patch" "$DIR/shown.patch"
  rm -f "$DIR/shown.patch"
  src "hhr_pane_ensure '$DIR'"
  [ "$(cat "$DIR/pane")" = "w1:p9" ]
  grep -q 'pane split' "$HERDR_STUB_LOG"
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

@test "cleanup.sh removes the shown.patch marker along with the pane file" {
  export HERDR_ENV=1
  printf 'w1:p9' > "$DIR/pane"
  cp "$DIR/combined.patch" "$DIR/shown.patch"
  run sh -c 'printf "%s" "$1" | sh "$2/scripts/cleanup.sh"' _ "$(session_end_payload s1)" "$HHR_ROOT"
  [ "$status" -eq 0 ]
  [ ! -f "$DIR/shown.patch" ]
}

@test "hhr_mark_shown writes shown.patch byte-for-byte after a successful display" {
  run src "hhr_mark_shown '$DIR'"
  [ "$status" -eq 0 ]
  run cmp -s "$DIR/combined.patch" "$DIR/shown.patch"
  [ "$status" -eq 0 ]
}

@test "hhr_mark_shown leaves a diagnosable breadcrumb, not a silent failure, when the copy cannot be written" {
  # Simulate a persistent write failure (disk full, permissions) by shadowing cp with
  # one that always fails. Before the fix this was hidden entirely behind
  # `2>/dev/null || true` - no marker, no trace, and the pane would reopen forever with
  # no way to tell why.
  FAILBIN="$SCRATCH/failbin"; mkdir -p "$FAILBIN"
  printf '#!/bin/sh\nexit 1\n' > "$FAILBIN/cp"; chmod +x "$FAILBIN/cp"
  export PATH="$FAILBIN:$PATH"
  run src "hhr_mark_shown '$DIR'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -f "$DIR/shown.patch" ]
  # No dangling temp file left behind either.
  run sh -c 'ls "$1"/.shown.patch.tmp.* 2>/dev/null' _ "$DIR"
  [ -z "$output" ]
  [ -s "$DIR/.shown-patch-error" ]
}

@test "a later successful hhr_mark_shown clears a previous failure breadcrumb" {
  FAILBIN="$SCRATCH/failbin"; mkdir -p "$FAILBIN"
  printf '#!/bin/sh\nexit 1\n' > "$FAILBIN/cp"; chmod +x "$FAILBIN/cp"
  PATH="$FAILBIN:$PATH" src "hhr_mark_shown '$DIR'" || true
  [ -s "$DIR/.shown-patch-error" ]

  src "hhr_mark_shown '$DIR'"
  [ -f "$DIR/shown.patch" ]
  [ ! -f "$DIR/.shown-patch-error" ]
}
