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
