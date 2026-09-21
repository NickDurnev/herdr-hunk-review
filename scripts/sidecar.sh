# Sourced. Builds <state_dir>/agent-context.json from state.json and combined.patch.
# HHR_NOTE_MAX_CHARS is defined in common.sh (shared with note.sh); callers should
# source common.sh before this file, but hhr_build_sidecar falls back to a default
# on its own if that was skipped - see the guard comment at its point of use.

# Prints "<prefixed-path>\t<side>\t<line>" for every file in the patch. The anchor
# prefers the first ADDED line (the common replace-one-line shape is "-old" then
# "+new", and the spec wants the new-side line); it falls back to the first REMOVED
# line only when the file has no additions at all (a pure deletion).
hhr_patch_anchors() {
  awk '
    function flush(p) {
      if (p == "" || (p in done)) return
      if (p in hasAdd) print p "\tnew\t" firstAdd[p]
      else if (p in hasDel) print p "\told\t" firstDel[p]
      done[p] = 1
    }
    # A new file section resets hunk state, so header lines are only ever read
    # outside a hunk. Inside one, a deleted "-- foo" renders as "--- foo" and must
    # not be mistaken for a header.
    /^diff --git / { flush(curpath); curpath = ""; newpath = ""; oldpath = ""; inhunk = 0; next }
    !inhunk && /^\+\+\+ / {
      p = substr($0, 5)
      if (p == "/dev/null") { newpath = "" } else { sub(/^b\//, "", p); newpath = p }
      curpath = (newpath != "" ? newpath : oldpath)
      next
    }
    !inhunk && /^--- / {
      p = substr($0, 5)
      if (p == "/dev/null") { oldpath = "" } else { sub(/^a\//, "", p); oldpath = p }
      curpath = (newpath != "" ? newpath : oldpath)
      next
    }
    /^@@ / {
      # @@ -oldstart,oldlen +newstart,newlen @@
      match($0, /-[0-9]+/); oldstart = substr($0, RSTART+1, RLENGTH-1) + 0
      match($0, /\+[0-9]+/); newstart = substr($0, RSTART+1, RLENGTH-1) + 0
      oldline = oldstart; newline = newstart
      inhunk = 1
      next
    }
    inhunk && /^\+/ {
      if (curpath != "" && !(curpath in hasAdd)) { hasAdd[curpath] = 1; firstAdd[curpath] = newline }
      newline++
      next
    }
    inhunk && /^-/ {
      if (curpath != "" && !(curpath in hasDel)) { hasDel[curpath] = 1; firstDel[curpath] = oldline }
      oldline++
      next
    }
    inhunk && /^ / { oldline++; newline++; next }
    END { flush(curpath) }
  ' "$1"
}

hhr_build_sidecar() {
  dir="$1"
  state="$dir/state.json"
  patch="$dir/combined.patch"
  out="$dir/agent-context.json"
  [ -f "$state" ] || return 0
  [ -f "$patch" ] || { printf '{"version":1,"summary":"","files":[]}' > "$out"; return 0; }

  # Guard, not a second source of truth: common.sh remains the one place the intended
  # value is configured. This default only stops an unset/empty HHR_NOTE_MAX_CHARS
  # (e.g. a caller that forgot to source common.sh first) from making `"" | tonumber`
  # raise inside the notes-extraction jq below - which its error handling would
  # otherwise swallow, silently producing NO annotations at all. Do not delete this
  # thinking common.sh's definition makes it redundant.
  : "${HHR_NOTE_MAX_CHARS:=300}"

  anchors="$dir/.anchors.tsv"
  hhr_patch_anchors "$patch" > "$anchors"

  # Agent notes keyed by the file's path as it appears in combined.patch: repo prefix
  # (basename of the repo root) joined with the file's path relative to that root.
  # $r is bound so the repo record stays in scope inside startswith()'s argument -
  # piping $f into startswith would otherwise rebind "." to the string $f itself.
  notes="$dir/.notes.tsv"
  : > "$notes"
  # Non-fatal on failure (hooks must never break the user's session) but not silent
  # either: a jq crash here used to be swallowed by `2>/dev/null || true` with zero
  # trace, which is exactly the "notes vanish and look like there was nothing to
  # show" failure this guard exists to prevent. Leave a breadcrumb on disk instead,
  # the same way hhr_mark_shown (pane.sh) does for its own silent-write hazard.
  if jq -r --arg m "$HHR_NOTE_MAX_CHARS" '
    [.repos | to_entries[] | {root: .key, prefix: .value.prefix}] as $repos
    | .agents | to_entries[]
    | . as $a
    # An agent with no captured report text - the seeded placeholder, a populated
    # type whose output/transcript extraction came up empty, or anything else with
    # nothing to say - has nothing worth annotating. Skip it rather than emit a
    # "[type] no report" box that carries zero information on every file it touched.
    | select(($a.value.output // "") | test("[^ \t\r\n]"))
    | ($a.value.files // [])[]
    | . as $f
    | ($repos[] | . as $rr | select($f | startswith($rr.root + "/")) | $rr) as $r
    | ($r.prefix + "/" + ($f | ltrimstr($r.root + "/"))) as $p
    | [$p,
       (($a.value.type // "agent")),
       (($a.value.output // "") | gsub("\\s+"; " ") | .[0:($m|tonumber)])
      ] | @tsv
  ' "$state" >> "$notes" 2>/dev/null; then
    rm -f "$dir/.notes-extract-error" 2>/dev/null
  else
    printf 'notes extraction failed at %s\n' "$(date +%s 2>/dev/null || echo 0)" \
      >> "$dir/.notes-extract-error" 2>/dev/null || true
  fi

  repos_count=$(jq -r '.repos | length' "$state")
  files_count=$(wc -l < "$anchors" | tr -d ' ')
  agents_count=$(jq -r '.agents | length' "$state")
  summary="$repos_count repos - $files_count files - $agents_count agents"

  # Join notes to anchors; a note whose file is absent from the patch is dropped.
  jq -n \
    --arg summary "$summary" \
    --rawfile anchors_raw "$anchors" \
    --rawfile notes_raw "$notes" '
    ($anchors_raw | split("\n") | map(select(length > 0) | split("\t"))
      | map({path: .[0], side: .[1], line: (.[2] | tonumber)})) as $anchors
    | ($notes_raw | split("\n") | map(select(length > 0) | split("\t"))
        | map({path: .[0], type: .[1], text: (.[2] // "")})) as $notes
    | {
        version: 1,
        summary: $summary,
        files: (
          $anchors
          | map(. as $an
              | ($notes | map(select(.path == $an.path))) as $ns
              | select($ns | length > 0)
              | {
                  path: $an.path,
                  summary: ($ns | map(.type) | unique | join(", ")),
                  annotations: ($ns | map(
                    {
                      summary: ("[" + .type + "] " + .text)
                    }
                    + (if $an.side == "new"
                       then {newRange: [$an.line, $an.line]}
                       else {oldRange: [$an.line, $an.line]} end)
                  ))
                })
        )
      }' > "$out.tmp" && mv "$out.tmp" "$out"

  rm -f "$anchors" "$notes"
  return 0
}
