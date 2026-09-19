# Sourced, not executed. Builds <state_dir>/combined.patch from every repo in state.json.
HHR_MAX_UNTRACKED_BYTES=524288
HHR_MAX_PATCH_BYTES=5242880

hhr_build_patch() {
  dir="$1"
  state="$dir/state.json"
  [ -f "$state" ] || return 0
  tmp="$dir/.patch.tmp"
  reposlist="$dir/.patch.repos.tmp"
  fileslist="$dir/.patch.files.tmp"
  : > "$tmp"

  jq -r '.repos | to_entries[] | "\(.key)\t\(.value.baseline)\t\(.value.prefix)"' "$state" > "$reposlist"

  while IFS="$(printf '\t')" read -r root base prefix; do
    [ -d "$root" ] || continue
    git -C "$root" diff --src-prefix="a/$prefix/" --dst-prefix="b/$prefix/" "$base" >> "$tmp" 2>/dev/null || true

    : > "$fileslist"
    git -C "$root" ls-files --others --exclude-standard 2>/dev/null > "$fileslist"

    while IFS= read -r f; do
      [ -n "$f" ] || continue
      full="$root/$f"
      [ -f "$full" ] || continue
      size=$(wc -c < "$full" 2>/dev/null || echo 0)
      [ "$size" -gt "$HHR_MAX_UNTRACKED_BYTES" ] && continue
      # git reports binary files without content; skip them rather than emit a useless stub.
      grep -qI . "$full" 2>/dev/null || continue
      ( cd "$root" && git diff --no-index \
          --src-prefix="a/$prefix/" --dst-prefix="b/$prefix/" /dev/null "$f" ) >> "$tmp" 2>/dev/null || true
    done < "$fileslist"
  done < "$reposlist"

  rm -f "$reposlist" "$fileslist"

  if [ "$(wc -c < "$tmp")" -gt "$HHR_MAX_PATCH_BYTES" ]; then
    head -c "$HHR_MAX_PATCH_BYTES" "$tmp" > "$tmp.cut"
    printf '\n# truncated: patch exceeded %s bytes\n' "$HHR_MAX_PATCH_BYTES" >> "$tmp.cut"
    mv "$tmp.cut" "$tmp"
  fi

  # Skip the move when nothing changed, so watchers do not reload needlessly. Compare
  # content directly with cmp rather than hashing: a missing shasum makes both sides of
  # a hash comparison resolve to the same empty string, so the "unchanged" branch fires
  # even when the patch changed, and the new patch is discarded forever.
  if [ -f "$dir/combined.patch" ] && cmp -s "$tmp" "$dir/combined.patch"; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$dir/combined.patch"
  return 0
}
