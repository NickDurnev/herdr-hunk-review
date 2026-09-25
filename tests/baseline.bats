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

@test "/herdr-hunk-review:hunk-baseline and the pane-close acknowledgment path produce the same resulting state" {
  # Two independent repos, seeded identically, one session acknowledged via
  # baseline.sh (/herdr-hunk-review:hunk-baseline) and the other via the close-detection path in
  # hhr_pane_ensure (reached through refresh.sh) - both call the same
  # hhr_reset_repo_baselines, so both should end up at an equivalent snapshot.
  REPO2="$(make_repo "$SCRATCH/repoB")"
  BASE2="$(git -C "$REPO2" rev-parse HEAD)"
  D2="$CLAUDE_PLUGIN_DATA/sessions/s2"; mkdir -p "$D2"
  jq -nc --arg r "$REPO2" --arg b "$BASE2" \
    '{repos:{($r):{baseline:$b,prefix:"repoB"}},agents:{}}' > "$D2/state.json"

  printf 'reviewed\n' >> "$REPO/tracked.txt"
  printf 'reviewed\n' >> "$REPO2/tracked.txt"

  # Session 1: /herdr-hunk-review:hunk-baseline.
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

@test "re-baselining a conflicted repo recomputes dirty_at_baseline, so acknowledgment actually takes effect" {
  # This is the bug report: closing the pane re-baselines through the exact same
  # failing `git stash create`, falls back to HEAD again, and - without recomputing
  # dirty_at_baseline - the identical pre-existing content reappears every time.
  # Acknowledging is structurally incapable of working on such a repo until re-baselining
  # also recomputes the dirty set.
  #
  # Seeded by hand with baseline=HEAD and NO dirty_at_baseline - standing in for
  # whatever state a prior acknowledgment (pre-fix) left behind, where the field was
  # never populated. Seeding via hhr_capture_repo_baseline instead would already record
  # the correct set up front, and since the repo's tree does not change between the two
  # captures here, hhr_reset_repo_baselines "recomputing" the same value it already had
  # would look identical to hhr_reset_repo_baselines never touching it at all - the
  # assertions below could not tell recomputation from a no-op. Starting with the field
  # absent means only a real recompute can make it appear.
  RC="$(cd "$(make_conflicted_repo "$SCRATCH/repoConflict")" && pwd -P)"
  DC="$CLAUDE_PLUGIN_DATA/sessions/sc"; mkdir -p "$DC"
  BASE="$(git -C "$RC" rev-parse HEAD)"
  jq -nc --arg r "$RC" --arg b "$BASE" \
    '{repos:{($r):{baseline:$b,prefix:"repoConflict"}},agents:{}}' > "$DC/state.json"
  [ "$(jq -r --arg r "$RC" '.repos[$r] | has("dirty_at_baseline")' "$DC/state.json")" = "false" ]

  sh "$HHR_ROOT/scripts/baseline.sh" sc

  # The conflict is still unresolved, so stash create fails again, and re-baselining
  # must recompute dirty_at_baseline from scratch - it was never seeded here.
  [ "$(jq -c --arg r "$RC" '.repos[$r].dirty_at_baseline' "$DC/state.json")" = '["tracked.txt"]' ]

  # The thing that matters: rebuilding the patch after acknowledgment shows nothing -
  # before this fix, this was silently non-empty every time (the no-op the user hit).
  sh -c '. "$1/scripts/patch.sh"; hhr_build_patch "$2"' _ "$HHR_ROOT" "$DC"
  [ ! -s "$DC/combined.patch" ]
}
