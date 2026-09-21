load helper

setup() {
  setup_scratch
  REPO="$(make_repo "$SCRATCH/repoA")"
  DIR="$CLAUDE_PLUGIN_DATA/sessions/s1"; mkdir -p "$DIR"
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  jq -nc --arg r "$REPO" --arg b "$BASE" \
    '{repos:{($r):{baseline:$b,prefix:"repoA"}},agents:{}}' > "$DIR/state.json"
}
teardown() { teardown_scratch; }

@test "re-snapshotting moves the baseline past current changes" {
  printf 'reviewed\n' >> "$REPO/tracked.txt"
  old="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"
  sh "$HHR_ROOT/scripts/baseline.sh" s1
  new="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"
  [ "$old" != "$new" ]
  run git -C "$REPO" diff "$new"
  [ -z "$output" ]
}

@test "clears stored agent notes so old reports do not linger" {
  jq '.agents = {a1:{type:"t",output:"o",files:["/f"]}}' "$DIR/state.json" > "$DIR/t" && mv "$DIR/t" "$DIR/state.json"
  sh "$HHR_ROOT/scripts/baseline.sh" s1
  [ "$(jq -r '.agents | length' "$DIR/state.json")" -eq 0 ]
}

@test "is silent and exits 0" {
  run sh "$HHR_ROOT/scripts/baseline.sh" s1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "/hunk-baseline and the pane-close acknowledgment path produce the same resulting state" {
  # Two independent repos, seeded identically, one session acknowledged via
  # baseline.sh (/hunk-baseline) and the other via the close-detection path in
  # hhr_pane_ensure (reached through refresh.sh) - both call the same
  # hhr_reset_repo_baselines, so both should end up at an equivalent snapshot.
  REPO2="$(make_repo "$SCRATCH/repoB")"
  BASE2="$(git -C "$REPO2" rev-parse HEAD)"
  D2="$CLAUDE_PLUGIN_DATA/sessions/s2"; mkdir -p "$D2"
  jq -nc --arg r "$REPO2" --arg b "$BASE2" \
    '{repos:{($r):{baseline:$b,prefix:"repoB"}},agents:{}}' > "$D2/state.json"

  printf 'reviewed\n' >> "$REPO/tracked.txt"
  printf 'reviewed\n' >> "$REPO2/tracked.txt"

  # Session 1: /hunk-baseline.
  sh "$HHR_ROOT/scripts/baseline.sh" s1

  # Session 2: open the pane, close it, let the next refresh detect and acknowledge.
  STUB="$SCRATCH/bin"; mkdir -p "$STUB"; export PATH="$STUB:$PATH"
  cat > "$STUB/hunk" <<'EOF'
#!/bin/sh
[ "$1 $2" = "session list" ] && echo '{"sessions":[]}'
exit 0
EOF
  chmod +x "$STUB/hunk"
  cat > "$STUB/herdr" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "pane list")   echo '{"result":{"panes":[]}}' ;;
  "pane layout") echo '{"result":{"layout":{"area":{"width":120,"height":40}}}}' ;;
  "pane split")  echo '{"result":{"pane":{"pane_id":"w1:p1"}}}' ;;
  *) echo '{"result":{}}' ;;
esac
EOF
  chmod +x "$STUB/herdr"
  export HERDR_ENV=1
  sh "$HHR_ROOT/scripts/refresh.sh" s2
  rm -f "$D2/pane"
  sh "$HHR_ROOT/scripts/refresh.sh" s2

  # Same observable outcome for both: patch empty, notes cleared, baseline == tree.
  [ ! -s "$DIR/combined.patch" ]
  [ ! -s "$D2/combined.patch" ]
  [ "$(jq -r '.agents | length' "$DIR/state.json")" -eq 0 ]
  [ "$(jq -r '.agents | length' "$D2/state.json")" -eq 0 ]
  run git -C "$REPO" diff "$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"
  [ -z "$output" ]
  run git -C "$REPO2" diff "$(jq -r --arg r "$REPO2" '.repos[$r].baseline' "$D2/state.json")"
  [ -z "$output" ]

  # Identical starting trees + identical edits -> identical snapshot trees.
  tree1="$(git -C "$REPO" rev-parse "$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")^{tree}")"
  tree2="$(git -C "$REPO2" rev-parse "$(jq -r --arg r "$REPO2" '.repos[$r].baseline' "$D2/state.json")^{tree}")"
  [ "$tree1" = "$tree2" ]
}
