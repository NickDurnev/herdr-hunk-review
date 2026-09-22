load helper

setup() {
  setup_scratch
  # Physically resolved (pwd -P), matching what track.sh/prebaseline.sh actually store
  # as a repo root - on macOS $SCRATCH sits under a symlink (/var -> /private/var), and
  # mark_touched independently resolves the same way, so leaving REPO unresolved here
  # would make the two paths differ as strings even though they name the same file.
  REPO="$(cd "$(make_repo "$SCRATCH/repoA")" && pwd -P)"
  DIR="$CLAUDE_PLUGIN_DATA/sessions/s1"
  mkdir -p "$DIR"
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  jq -nc --arg r "$REPO" --arg b "$BASE" \
    '{repos:{($r):{baseline:$b, prefix:"repoA"}}, agents:{}}' > "$DIR/state.json"
}
teardown() { teardown_scratch; }

build() { sh -c '. "$1/scripts/patch.sh"; hhr_build_patch "$2"' _ "$HHR_ROOT" "$DIR"; }

# Runs the real hhr_capture_repo_baseline (common.sh) against a state file and repo
# root, exactly as prebaseline.sh/track.sh do - so a conflicted-repo test here exercises
# the actual `git stash create` failure path, not a hand-rolled dirty_at_baseline.
capture_baseline() { sh -c '. "$1/scripts/common.sh"; hhr_capture_repo_baseline "$2" "$3"' _ "$HHR_ROOT" "$1" "$2"; }

@test "includes an uncommitted change with the repo prefix" {
  printf 'new line\n' >> "$REPO/tracked.txt"
  build
  grep -q 'a/repoA/tracked.txt' "$DIR/combined.patch"
  grep -q '^+new line' "$DIR/combined.patch"
}

@test "includes work the agent committed during the session" {
  printf 'committed\n' >> "$REPO/tracked.txt"
  git -C "$REPO" commit -qam "agent commit"
  build
  grep -q '^+committed' "$DIR/combined.patch"
}

@test "excludes drift captured in the baseline" {
  printf 'drift\n' >> "$REPO/tracked.txt"
  NB="$(git -C "$REPO" stash create)"
  jq --arg r "$REPO" --arg b "$NB" '.repos[$r].baseline = $b' "$DIR/state.json" > "$DIR/t" && mv "$DIR/t" "$DIR/state.json"
  printf 'session\n' >> "$REPO/tracked.txt"
  build
  grep -q '^+session' "$DIR/combined.patch"
  ! grep -q '^+drift' "$DIR/combined.patch"
}

@test "includes an untracked file the session touched" {
  printf 'brand new\n' > "$REPO/fresh.txt"
  mark_touched "$DIR/state.json" "$REPO/fresh.txt"
  build
  grep -q 'b/repoA/fresh.txt' "$DIR/combined.patch"
  grep -q '^+brand new' "$DIR/combined.patch"
}

@test "excludes an untracked file the session never touched (pre-existing drift)" {
  # git stash create (the baseline) does not capture untracked files, so an untracked
  # file that was already sitting in the repo before the session started must not
  # appear just because it postdates the baseline - only files the session itself
  # touched (agents[].files[], written by track.sh) belong in the patch.
  printf 'pre-existing drift\n' > "$REPO/stale.txt"
  build
  run grep -q 'stale.txt' "$DIR/combined.patch"
  [ "$status" -ne 0 ]
}

@test "an untouched untracked file is excluded even when a different file was touched" {
  printf 'brand new\n' > "$REPO/fresh.txt"
  printf 'never touched\n' > "$REPO/stale.txt"
  mark_touched "$DIR/state.json" "$REPO/fresh.txt" "agent-1"
  build
  grep -q 'b/repoA/fresh.txt' "$DIR/combined.patch"
  run grep -q 'stale.txt' "$DIR/combined.patch"
  [ "$status" -ne 0 ]
}

@test "excludes a gitignored file" {
  printf 'ignored.txt\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore && git -C "$REPO" commit -qm ignore
  printf 'secret\n' > "$REPO/ignored.txt"
  build
  # Assert on the ignored file's own diff path and content. A bare `grep ignored.txt`
  # would match the .gitignore's committed CONTENT — that commit is legitimate session
  # work and belongs in the patch, so the bare grep tests the wrong thing.
  # (`run` + status check, not `! grep`, because in bash a `!`-negated command is exempt
  # from errexit/bats failure detection unless it happens to be the test's last statement
  # — a non-final `! grep` here would silently pass even when the grep matches.)
  run grep -q 'b/repoA/ignored.txt' "$DIR/combined.patch"
  [ "$status" -ne 0 ]
  run grep -q '^+secret' "$DIR/combined.patch"
  [ "$status" -ne 0 ]
  # The .gitignore commit itself is session work and must still appear.
  grep -q 'b/repoA/.gitignore' "$DIR/combined.patch"
}

@test "includes a deletion" {
  git -C "$REPO" rm -q tracked.txt
  build
  grep -q 'a/repoA/tracked.txt' "$DIR/combined.patch"
  grep -q '^-line1' "$DIR/combined.patch"
}

@test "merges two repos into one patch" {
  R2="$(make_repo "$SCRATCH/repoB")"
  B2="$(git -C "$R2" rev-parse HEAD)"
  jq --arg r "$R2" --arg b "$B2" '.repos[$r] = {baseline:$b, prefix:"repoB"}' \
     "$DIR/state.json" > "$DIR/t" && mv "$DIR/t" "$DIR/state.json"
  printf 'a\n' >> "$REPO/tracked.txt"
  printf 'b\n' >> "$R2/tracked.txt"
  build
  grep -q 'a/repoA/tracked.txt' "$DIR/combined.patch"
  grep -q 'a/repoB/tracked.txt' "$DIR/combined.patch"
}

@test "is idempotent: an unchanged rebuild does not rewrite the file" {
  printf 'x\n' >> "$REPO/tracked.txt"
  build
  before="$(stat -f %m "$DIR/combined.patch")"
  sleep 1
  build
  [ "$before" = "$(stat -f %m "$DIR/combined.patch")" ]
}

@test "a changed rebuild does rewrite the file" {
  printf 'x\n' >> "$REPO/tracked.txt"
  build
  before="$(stat -f %m "$DIR/combined.patch")"
  sleep 1
  printf 'y\n' >> "$REPO/tracked.txt"
  build
  [ "$before" != "$(stat -f %m "$DIR/combined.patch")" ]
}

@test "handles a path containing a space" {
  printf 'z\n' > "$REPO/has space.txt"
  mark_touched "$DIR/state.json" "$REPO/has space.txt"
  build
  grep -q 'has space.txt' "$DIR/combined.patch"
}

@test "skips a large untracked file even when the session touched it" {
  mkfile -n 600k "$REPO/big.bin" 2>/dev/null || dd if=/dev/zero of="$REPO/big.bin" bs=1024 count=600 2>/dev/null
  mark_touched "$DIR/state.json" "$REPO/big.bin"
  build
  ! grep -q 'big.bin' "$DIR/combined.patch"
}

@test "skips an untracked binary file even when the session touched it" {
  printf 'bin\000\001\002data\n' > "$REPO/blob.bin"
  mark_touched "$DIR/state.json" "$REPO/blob.bin"
  build
  ! grep -q 'blob.bin' "$DIR/combined.patch"
}

@test "records a rename" {
  git -C "$REPO" mv tracked.txt renamed.txt
  build
  grep -q 'renamed.txt' "$DIR/combined.patch"
}

# Three committed files, each producing an identical, measured 1080-byte diff (44-byte
# header line + 50 added lines), so a cap of 2200 keeps exactly the first two whole
# diffs (2160 bytes) and drops the third entirely - never a byte-level mid-file cut.
make_three_big_diffs() {
  for n in 1 2 3; do
    printf 'file %s\n' "$n" > "$REPO/big$n.txt"
    git -C "$REPO" add "big$n.txt"
  done
  git -C "$REPO" commit -qm "add big files"
  b="$(git -C "$REPO" rev-parse HEAD)"
  jq --arg r "$REPO" --arg b "$b" '.repos[$r].baseline = $b' "$DIR/state.json" > "$DIR/t" && mv "$DIR/t" "$DIR/state.json"
  for n in 1 2 3; do
    i=0
    while [ "$i" -lt 50 ]; do
      printf 'line %s in file %s\n' "$i" "$n" >> "$REPO/big$n.txt"
      i=$((i + 1))
    done
  done
}

@test "a patch over the size cap is truncated at a whole-file boundary, not mid-diff" {
  make_three_big_diffs
  export HHR_MAX_PATCH_BYTES=2200
  build
  # The two files that fit are present with their FULL body (last added line intact) -
  # a byte-level `head -c` cut would either drop the last line or leave a fragment.
  grep -q 'a/repoA/big1.txt' "$DIR/combined.patch"
  grep -q '^+line 49 in file 1' "$DIR/combined.patch"
  grep -q 'a/repoA/big2.txt' "$DIR/combined.patch"
  grep -q '^+line 49 in file 2' "$DIR/combined.patch"
  # The third file is left out entirely - no header, no partial content.
  run grep -q 'big3.txt' "$DIR/combined.patch"
  [ "$status" -ne 0 ]
  run grep -q 'line 0 in file 3' "$DIR/combined.patch"
  [ "$status" -ne 0 ]
  grep -qx '# truncated: 1 more file(s) omitted, patch exceeded 2200 bytes' "$DIR/combined.patch"
}

@test "a patch truncated by the size cap still parses: every diff --git header has its complete body" {
  make_three_big_diffs
  export HHR_MAX_PATCH_BYTES=2200
  build
  patch="$DIR/combined.patch"
  # Every kept file section runs a full '+++ ' line, a full hunk header and its added
  # lines - counts must match 1:1, which they cannot if any section was cut short.
  headers=$(grep -c '^diff --git ' "$patch")
  plus=$(grep -c '^+++ ' "$patch")
  hunks=$(grep -c '^@@ ' "$patch")
  [ "$headers" -eq 2 ]
  [ "$plus" -eq "$headers" ]
  [ "$hunks" -eq "$headers" ]
  # The file ends at a file boundary: the trailing truncation marker, never a bare,
  # unterminated fragment of a hunk header or diff line.
  last_line=$(tail -n1 "$patch")
  case "$last_line" in
    '# truncated:'*) : ;;
    *) false ;;
  esac
}

# Real conflicted repo (genuine unresolved merge, so `git stash create` really fails
# with "needs merge") captured through the actual hhr_capture_repo_baseline, exercising
# the fallback-to-HEAD-plus-dirty_at_baseline path end to end, not a hand-built fixture.
setup_conflicted_repo() {
  RC="$(cd "$(make_conflicted_repo "$SCRATCH/repoConflict")" && pwd -P)"
  DC="$CLAUDE_PLUGIN_DATA/sessions/sc"
  mkdir -p "$DC"
  printf '{"repos":{},"agents":{}}' > "$DC/state.json"
  capture_baseline "$DC/state.json" "$RC"
}

@test "a repo whose stash create fails: pre-existing modifications do not appear in the patch" {
  setup_conflicted_repo
  # Sanity: prove the fallback really happened and the conflict really was recorded -
  # otherwise the assertion below would be vacuously true.
  [ "$(jq -r --arg r "$RC" '.repos[$r].baseline' "$DC/state.json")" = "$(git -C "$RC" rev-parse HEAD)" ]
  [ "$(jq -c --arg r "$RC" '.repos[$r].dirty_at_baseline' "$DC/state.json")" = '["tracked.txt"]' ]
  sh -c '. "$1/scripts/patch.sh"; hhr_build_patch "$2"' _ "$HHR_ROOT" "$DC"
  [ ! -s "$DC/combined.patch" ]
}

@test "a file dirty at baseline that the session then edits still appears (subtraction)" {
  setup_conflicted_repo
  mark_touched "$DC/state.json" "$RC/tracked.txt"
  printf 'session edit\n' >> "$RC/tracked.txt"
  sh -c '. "$1/scripts/patch.sh"; hhr_build_patch "$2"' _ "$HHR_ROOT" "$DC"
  grep -q 'a/repoConflict/tracked.txt' "$DC/combined.patch"
  grep -q '^+session edit' "$DC/combined.patch"
}

@test "in a conflicted repo, a different clean file the session touches appears as normal" {
  # A NEW committed file cannot be added here (git refuses to commit anything while
  # tracked.txt's merge conflict is unresolved), so this uses an untracked file the
  # session touches instead - proving the two exclusion mechanisms (dirty_at_baseline
  # and the untouched-untracked-file guard) coexist correctly in the same repo.
  setup_conflicted_repo
  printf 'brand new\n' > "$RC/fresh.txt"
  mark_touched "$DC/state.json" "$RC/fresh.txt"
  sh -c '. "$1/scripts/patch.sh"; hhr_build_patch "$2"' _ "$HHR_ROOT" "$DC"
  grep -q 'b/repoConflict/fresh.txt' "$DC/combined.patch"
  grep -q '^+brand new' "$DC/combined.patch"
  # The still-untouched conflict on tracked.txt must stay excluded alongside it.
  run grep -q 'tracked.txt' "$DC/combined.patch"
  [ "$status" -ne 0 ]
}

@test "a repo where stash create succeeds records no dirty_at_baseline and behaves as before" {
  # Must have real pre-existing uncommitted (but non-conflicted) drift when captured,
  # or `git stash create` returns empty on a clean tree and this exercises the same
  # HEAD-fallback path as the clean-tree tests elsewhere, not the stash-create-succeeds
  # path this test is named for.
  R2="$(cd "$(make_repo "$SCRATCH/repoClean")" && pwd -P)"
  printf 'pre-existing uncommitted change\n' >> "$R2/tracked.txt"
  D2="$CLAUDE_PLUGIN_DATA/sessions/s-clean"
  mkdir -p "$D2"
  printf '{"repos":{},"agents":{}}' > "$D2/state.json"
  capture_baseline "$D2/state.json" "$R2"
  # Sanity: stash create really succeeded - the baseline folds in the pre-existing
  # change, so it differs from plain HEAD.
  [ "$(jq -r --arg r "$R2" '.repos[$r].baseline' "$D2/state.json")" != "$(git -C "$R2" rev-parse HEAD)" ]
  [ "$(jq -r --arg r "$R2" '.repos[$r] | has("dirty_at_baseline")' "$D2/state.json")" = "false" ]
  printf 'new\n' >> "$R2/tracked.txt"
  sh -c '. "$1/scripts/patch.sh"; hhr_build_patch "$2"' _ "$HHR_ROOT" "$D2"
  grep -q '^+new' "$D2/combined.patch"
  # Same as before this fix: the baseline (not dirty_at_baseline) already excludes the
  # pre-existing drift, with no explicit exclusion needed - it must not show as an
  # ADDED line (a bare substring match would also hit it as unchanged diff CONTEXT,
  # since it sits right next to the session's own added line).
  run grep -q '^+pre-existing uncommitted change' "$D2/combined.patch"
  [ "$status" -ne 0 ]
}
