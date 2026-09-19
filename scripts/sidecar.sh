# Sourced. Builds <state_dir>/agent-context.json from state.json and combined.patch.
HHR_NOTE_MAX_CHARS=300

# Prints "<prefixed-path>\t<side>\t<line>" for every file in the patch,
# where side is "new" or "old" and line is the first changed line on that side.
hhr_patch_anchors() {
  awk '
    # A new file section resets hunk state, so header lines are only ever read
    # outside a hunk. Inside one, a deleted "-- foo" renders as "--- foo" and must
    # not be mistaken for a header.
    /^diff --git / { inhunk = 0; next }
    !inhunk && /^\+\+\+ / {
      p = substr($0, 5)
      if (p == "/dev/null") { newpath = "" } else { sub(/^b\//, "", p); newpath = p }
      next
    }
    !inhunk && /^--- / {
      p = substr($0, 5)
      if (p == "/dev/null") { oldpath = "" } else { sub(/^a\//, "", p); oldpath = p }
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
      path = (newpath != "" ? newpath : oldpath)
      if (path != "" && !(path in done)) { print path "\tnew\t" newline; done[path] = 1; inhunk = 0 }
      newline++
      next
    }
    inhunk && /^-/ {
      path = (oldpath != "" ? oldpath : newpath)
      if (path != "" && !(path in done)) { print path "\told\t" oldline; done[path] = 1; inhunk = 0 }
      oldline++
      next
    }
    inhunk && /^ / { oldline++; newline++; next }
  ' "$1"
}

hhr_build_sidecar() {
  dir="$1"
  state="$dir/state.json"
  patch="$dir/combined.patch"
  out="$dir/agent-context.json"
  [ -f "$state" ] || return 0
  [ -f "$patch" ] || { printf '{"version":1,"summary":"","files":[]}' > "$out"; return 0; }

  anchors="$dir/.anchors.tsv"
  hhr_patch_anchors "$patch" > "$anchors"

  # Agent notes keyed by the file's path as it appears in combined.patch: repo prefix
  # (basename of the repo root) joined with the file's path relative to that root.
  # $r is bound so the repo record stays in scope inside startswith()'s argument -
  # piping $f into startswith would otherwise rebind "." to the string $f itself.
  notes="$dir/.notes.tsv"
  : > "$notes"
  jq -r --arg m "$HHR_NOTE_MAX_CHARS" '
    [.repos | to_entries[] | {root: .key, prefix: .value.prefix}] as $repos
    | .agents | to_entries[]
    | . as $a
    | ($a.value.files // [])[]
    | . as $f
    | ($repos[] | . as $rr | select($f | startswith($rr.root + "/")) | $rr) as $r
    | ($r.prefix + "/" + ($f | ltrimstr($r.root + "/"))) as $p
    | [$p,
       (($a.value.type // "agent")),
       (($a.value.output // "") | gsub("\\s+"; " ") | .[0:($m|tonumber)])
      ] | @tsv
  ' "$state" >> "$notes" 2>/dev/null || true

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
                      summary: ("[" + .type + "] " + (if (.text | length) > 0 then .text else "no report" end))
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
