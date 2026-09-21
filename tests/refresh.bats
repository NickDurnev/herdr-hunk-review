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

@test "a trailing force argument does not disturb an ordinary refresh with HERDR_ENV unset" {
  unset HERDR_ENV
  run sh "$HHR_ROOT/scripts/refresh.sh" s1 force
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -s "$DIR/combined.patch" ]
}

# Shared herdr/hunk stub for the close-detection tests below: "pane list" always
# reports no panes (the pane the user closed never comes back on its own), and "hunk
# session list" always reports no live viewer session.
stub_closed_pane() {
  STUB="$SCRATCH/bin"; mkdir -p "$STUB"; export PATH="$STUB:$PATH"
  cat > "$STUB/hunk" <<'EOF'
#!/bin/sh
[ "$1 $2" = "session list" ] && echo '{"sessions":[]}'
exit 0
EOF
  chmod +x "$STUB/hunk"
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
}

@test "a plain refresh does not reopen a pane the user closed when nothing changed, and acknowledges it instead" {
  stub_closed_pane

  # First refresh: no pane, no shown.patch marker yet -> opens one.
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  first_splits=$(grep -c 'pane split' "$HERDR_STUB_LOG" || true)
  [ "$first_splits" -eq 1 ]
  [ -f "$DIR/shown.patch" ]

  # User closes the pane (herdr's stubbed "pane list" already always reports none);
  # nothing else changes. A plain refresh must NOT reopen it - but per PIX's close =
  # acknowledge behavior, it must also silently move the baseline past the change that
  # was shown, and leave the patch empty and shown.patch gone.
  rm -f "$DIR/pane"
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  second_splits=$(grep -c 'pane split' "$HERDR_STUB_LOG" || true)
  [ "$second_splits" -eq 1 ]
  [ ! -f "$DIR/pane" ]
  [ ! -s "$DIR/combined.patch" ]
  [ ! -f "$DIR/shown.patch" ]
  run git -C "$REPO" diff "$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"
  [ -z "$output" ]
}

@test "force reopens a pane the user closed and not-yet-acknowledged content, instead of silently swallowing it" {
  stub_closed_pane

  # First refresh: opens the pane and shows the current change.
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  [ -f "$DIR/shown.patch" ]
  before_baseline="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"

  # User closes the pane; nothing else changes. Force this very next refresh instead of
  # a plain one - force clears shown.patch before hhr_pane_ensure ever gets a
  # chance to read it, so the would-be silent acknowledgment never happens: the user
  # asked to see the pane, so they see the content, not an empty one.
  rm -f "$DIR/pane"
  sh "$HHR_ROOT/scripts/refresh.sh" s1 force
  splits=$(grep -c 'pane split' "$HERDR_STUB_LOG" || true)
  [ "$splits" -eq 2 ]
  [ -f "$DIR/pane" ]
  grep -q '^+change' "$DIR/combined.patch"
  after_baseline="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"
  [ "$before_baseline" = "$after_baseline" ]
}

@test "force with an empty combined.patch issues no pane split" {
  # Minimal, decoupled from the close-detection feature: a repo with no uncommitted
  # changes at all, so hhr_build_patch produces an empty patch on the very first run -
  # this isolates the empty-patch guard itself from the close-acknowledgment path that
  # also happens to leave an empty patch.
  git -C "$REPO" checkout -q -- tracked.txt
  stub_closed_pane

  run sh "$HHR_ROOT/scripts/refresh.sh" s1 force
  [ "$status" -eq 0 ]
  [ ! -s "$DIR/combined.patch" ]
  run grep -q 'pane split' "$HERDR_STUB_LOG"
  [ "$status" -ne 0 ]
  [ ! -f "$DIR/pane" ]
}

@test "force does nothing (no pane opens) once the content has already been acknowledged" {
  stub_closed_pane

  sh "$HHR_ROOT/scripts/refresh.sh" s1
  rm -f "$DIR/pane"
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  [ ! -s "$DIR/combined.patch" ]

  sh "$HHR_ROOT/scripts/refresh.sh" s1 force
  splits=$(grep -c 'pane split' "$HERDR_STUB_LOG" || true)
  [ "$splits" -eq 1 ]
  [ ! -f "$DIR/pane" ]
}

@test "close detected with an unchanged patch: a change made after that point appears next time, the acknowledged change does not" {
  stub_closed_pane

  sh "$HHR_ROOT/scripts/refresh.sh" s1
  rm -f "$DIR/pane"
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  [ ! -s "$DIR/combined.patch" ]

  printf 'after close\n' >> "$REPO/tracked.txt"
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  [ -s "$DIR/combined.patch" ]
  grep -q '^+after close' "$DIR/combined.patch"
  run grep -q '^+change$' "$DIR/combined.patch"
  [ "$status" -ne 0 ]
}

@test "the trap: content landing between the display and the close detection is not acknowledged - the pane reopens and the baseline does not move" {
  stub_closed_pane

  # Shown once.
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  before_baseline="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"

  # Deliberately NO sleep here: the close and the new work must be able to land in the
  # very same wall-clock second as the display above. shown.patch is a byte-for-byte
  # content snapshot, not a timestamp, so this test genuinely exercises the trap
  # regardless of timing - an mtime-based implementation (`stat`'s mtime is
  # second-resolution) would read two same-second patch rewrites as identical and
  # wrongly acknowledge this change.
  # The pane is closed AND new work lands before the close is ever detected - this is
  # the race the spec calls out: a naive "re-baseline on close" would swallow this.
  rm -f "$DIR/pane"
  printf 'landed before detection\n' >> "$REPO/tracked.txt"

  sh "$HHR_ROOT/scripts/refresh.sh" s1
  # hhr_build_patch (called before hhr_pane_ensure) picks up the new line, so
  # combined.patch no longer matches shown.patch byte-for-byte - this must reopen, not
  # acknowledge.
  splits=$(grep -c 'pane split' "$HERDR_STUB_LOG" || true)
  [ "$splits" -eq 2 ]
  [ -f "$DIR/pane" ]
  after_baseline="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"
  [ "$before_baseline" = "$after_baseline" ]
  grep -q '^+change' "$DIR/combined.patch"
  grep -q '^+landed before detection' "$DIR/combined.patch"
}

@test "close detection re-baselines every tracked repo, not just one" {
  REPO2="$(make_repo "$SCRATCH/repoB")"
  BASE2="$(git -C "$REPO2" rev-parse HEAD)"
  jq --arg r "$REPO2" --arg b "$BASE2" \
    '.repos[$r] = {baseline:$b, prefix:"repoB"}' "$DIR/state.json" > "$DIR/t" && mv "$DIR/t" "$DIR/state.json"
  printf 'second repo change\n' >> "$REPO2/tracked.txt"

  stub_closed_pane
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  rm -f "$DIR/pane"
  sh "$HHR_ROOT/scripts/refresh.sh" s1

  [ ! -s "$DIR/combined.patch" ]
  run git -C "$REPO" diff "$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"
  [ -z "$output" ]
  run git -C "$REPO2" diff "$(jq -r --arg r "$REPO2" '.repos[$r].baseline' "$DIR/state.json")"
  [ -z "$output" ]
}

@test "a repo whose path contains a space is re-baselined correctly on close detection" {
  SPACY="$(make_repo "$SCRATCH/repo with space")"
  BASE_SPACY="$(git -C "$SPACY" rev-parse HEAD)"
  jq -nc --arg r "$SPACY" --arg b "$BASE_SPACY" \
    '{repos:{($r):{baseline:$b,prefix:"spacy"}},agents:{}}' > "$DIR/state.json"
  printf 'spacy change\n' >> "$SPACY/tracked.txt"

  stub_closed_pane
  sh "$HHR_ROOT/scripts/refresh.sh" s1
  rm -f "$DIR/pane"
  sh "$HHR_ROOT/scripts/refresh.sh" s1

  [ ! -s "$DIR/combined.patch" ]
  run git -C "$SPACY" diff "$(jq -r --arg r "$SPACY" '.repos[$r].baseline' "$DIR/state.json")"
  [ -z "$output" ]
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
