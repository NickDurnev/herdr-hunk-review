# Sourced, not executed. Builds <state_dir>/combined.patch from every repo in state.json.
# Overridable (tests shrink these) rather than hard-assigned, so a caller can exercise
# the untracked-size guard or the truncation path without building real 512KB/5MB files.
: "${HHR_MAX_UNTRACKED_BYTES:=524288}"
: "${HHR_MAX_PATCH_BYTES:=5242880}"

hhr_build_patch() {
  dir="$1"
  state="$dir/state.json"
  [ -f "$state" ] || return 0
  tmp="$dir/.patch.tmp"
  reposlist="$dir/.patch.repos.tmp"
  fileslist="$dir/.patch.files.tmp"
  touched="$dir/.patch.touched.tmp"
  : > "$tmp"

  jq -r '.repos | to_entries[] | "\(.key)\t\(.value.baseline)\t\(.value.prefix)"' "$state" > "$reposlist"

  # `git stash create` (the baseline snapshot) deliberately does not capture untracked
  # files, so every untracked file already sitting in a repo before the session started
  # would otherwise read as "new since the baseline" - in a real workspace that is
  # dozens/hundreds of files of pre-existing drift, drowning the session's real changes.
  # `agents[].files[]` is the canonical, already-absolute-physical-path record of files
  # the session itself touched (maintained by track.sh); only an untracked file present
  # there belongs in the patch.
  jq -r '[.agents[].files[]?] | unique[]' "$state" 2>/dev/null > "$touched" || : > "$touched"

  while IFS="$(printf '\t')" read -r root base prefix; do
    [ -d "$root" ] || continue
    git -C "$root" diff --src-prefix="a/$prefix/" --dst-prefix="b/$prefix/" "$base" >> "$tmp" 2>/dev/null || true

    : > "$fileslist"
    git -C "$root" ls-files --others --exclude-standard 2>/dev/null > "$fileslist"

    while IFS= read -r f; do
      [ -n "$f" ] || continue
      full="$root/$f"
      [ -f "$full" ] || continue
      grep -qxF "$full" "$touched" 2>/dev/null || continue
      size=$(wc -c < "$full" 2>/dev/null || echo 0)
      [ "$size" -gt "$HHR_MAX_UNTRACKED_BYTES" ] && continue
      # git reports binary files without content; skip them rather than emit a useless stub.
      grep -qI . "$full" 2>/dev/null || continue
      ( cd "$root" && git diff --no-index \
          --src-prefix="a/$prefix/" --dst-prefix="b/$prefix/" /dev/null "$f" ) >> "$tmp" 2>/dev/null || true
    done < "$fileslist"
  done < "$reposlist"

  rm -f "$reposlist" "$fileslist" "$touched"

  if [ "$(wc -c < "$tmp")" -gt "$HHR_MAX_PATCH_BYTES" ]; then
    hhr_truncate_patch_to_file_boundary "$tmp" "$HHR_MAX_PATCH_BYTES" > "$tmp.cut"
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

# Truncates a patch at a whole-file-diff boundary instead of an arbitrary byte offset
# (plain `head -c` cuts mid-diff, which hunk cannot parse - a malformed patch is worse
# than a large one). Each per-file diff begins with a `diff --git ` header line; whole
# diffs are kept, in order, until the next one would push the total over the cap, then
# a trailing comment names how many files were left out. Reads $1 (the built patch),
# writes the truncated patch to stdout.
hhr_truncate_patch_to_file_boundary() {
  awk -v cap="$2" '
    function flush() {
      if (!started) return
      sz = length(chunk)
      if (total + sz <= cap) { printf "%s", chunk; total += sz }
      else { omitted++ }
    }
    /^diff --git / { flush(); chunk = $0 "\n"; started = 1; next }
    { chunk = chunk $0 "\n" }
    END {
      flush()
      if (omitted > 0) {
        printf "\n# truncated: %d more file(s) omitted, patch exceeded %d bytes\n", omitted, cap
      }
    }
  ' "$1"
}
