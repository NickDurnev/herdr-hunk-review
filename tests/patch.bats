load helper

setup() {
  setup_scratch
  REPO="$(make_repo "$SCRATCH/repoA")"
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

@test "includes an untracked file" {
  printf 'brand new\n' > "$REPO/fresh.txt"
  build
  grep -q 'b/repoA/fresh.txt' "$DIR/combined.patch"
  grep -q '^+brand new' "$DIR/combined.patch"
}

@test "excludes a gitignored file" {
  printf 'ignored.txt\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore && git -C "$REPO" commit -qm ignore
  printf 'secret\n' > "$REPO/ignored.txt"
  build
  ! grep -q 'ignored.txt' "$DIR/combined.patch"
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
  build
  grep -q 'has space.txt' "$DIR/combined.patch"
}

@test "skips a large untracked file" {
  mkfile -n 600k "$REPO/big.bin" 2>/dev/null || dd if=/dev/zero of="$REPO/big.bin" bs=1024 count=600 2>/dev/null
  build
  ! grep -q 'big.bin' "$DIR/combined.patch"
}

@test "skips an untracked binary file" {
  printf 'bin\000\001\002data\n' > "$REPO/blob.bin"
  build
  ! grep -q 'blob.bin' "$DIR/combined.patch"
}

@test "records a rename" {
  git -C "$REPO" mv tracked.txt renamed.txt
  build
  grep -q 'renamed.txt' "$DIR/combined.patch"
}
