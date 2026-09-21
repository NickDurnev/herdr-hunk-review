load helper

setup() {
  setup_scratch
  DIR="$CLAUDE_PLUGIN_DATA/sessions/s1"
  mkdir -p "$DIR"
  cat > "$DIR/combined.patch" <<'EOF'
diff --git a/repoA/tracked.txt b/repoA/tracked.txt
index 111..222 100644
--- a/repoA/tracked.txt
+++ b/repoA/tracked.txt
@@ -1,2 +1,3 @@
 line1
 line2
+added here
EOF
}
teardown() { teardown_scratch; }

write_state() { printf '%s' "$1" > "$DIR/state.json"; }
build() { sh -c '. "$1/scripts/common.sh"; . "$1/scripts/sidecar.sh"; hhr_build_sidecar "$2"' _ "$HHR_ROOT" "$DIR"; }

# Sources ONLY sidecar.sh - never common.sh - so HHR_NOTE_MAX_CHARS is unset going
# into hhr_build_sidecar, exactly the hazard the note-max-chars guard exists for:
# without it, `"" | tonumber` inside the notes-extraction jq raises and the whole
# annotation set silently disappears.
build_no_common() { sh -c 'unset HHR_NOTE_MAX_CHARS; . "$1/scripts/sidecar.sh"; hhr_build_sidecar "$2"' _ "$HHR_ROOT" "$DIR"; }

@test "emits a ranged annotation anchored to the first added line" {
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"Made the dep required.",files:[$f]}}}')"
  build
  [ "$(jq -r '.files[0].path' "$DIR/agent-context.json")" = "repoA/tracked.txt" ]
  [ "$(jq -r '.files[0].annotations[0].newRange[0]' "$DIR/agent-context.json")" -eq 3 ]
  jq -e '.files[0].annotations[0].summary | test("impl")' "$DIR/agent-context.json"
  jq -e '.files[0].annotations[0].summary | test("Made the dep required")' "$DIR/agent-context.json"
}

@test "anchors a replace-one-line hunk on the new line, not the old one" {
  # The dominant Edit shape ("-old" then "+new" in the same hunk) must anchor on the
  # NEW-side line. Confirmed against the unfixed hhr_patch_anchors: it stops at the
  # first changed line regardless of side, so a "-" arriving before the matching "+"
  # wins and this produces oldRange instead - this test fails against that behavior.
  cat > "$DIR/combined.patch" <<'EOF'
diff --git a/repoA/tracked.txt b/repoA/tracked.txt
index 111..222 100644
--- a/repoA/tracked.txt
+++ b/repoA/tracked.txt
@@ -1,2 +1,2 @@
-line1
+line1 replaced
 line2
EOF
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"replaced the line",files:[$f]}}}')"
  build
  jq -e '.files[0].annotations[0].newRange' "$DIR/agent-context.json"
  [ "$(jq -r '.files[0].annotations[0].newRange[0]' "$DIR/agent-context.json")" -eq 1 ]
}

@test "an agent with no report text produces no annotation" {
  # track.sh seeds {type:"", output:""} for a main-agent record note.sh never touches.
  # jq's `//` only defaults null/false, not "", so the old code emitted a real but
  # empty "[] no report" annotation on every file such an agent touched.
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{main:{type:"",output:"",files:[$f]}}}')"
  build
  [ "$(jq -r '.files | length' "$DIR/agent-context.json")" -eq 0 ]
}

@test "is valid JSON with version 1 and a changeset summary" {
  write_state "$(jq -nc '{repos:{},agents:{}}')"
  build
  [ "$(jq -r '.version' "$DIR/agent-context.json")" = "1" ]
  jq -e '.summary | type == "string"' "$DIR/agent-context.json"
}

@test "omits a file the patch does not contain" {
  write_state "$(jq -nc --arg f "/x/repoA/absent.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"note",files:[$f]}}}')"
  build
  [ "$(jq -r '.files | length' "$DIR/agent-context.json")" -eq 0 ]
}

@test "an agent with a type but no report text produces no annotation" {
  # A populated type with empty output (extraction ran, found nothing) must not
  # render a "[reviewer] no report" box - there is no case where "no report" is
  # worth showing, so a file whose only contributor has no text is dropped
  # entirely rather than rendered with a placeholder annotation.
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"reviewer",output:"",files:[$f]}}}')"
  build
  [ "$(jq -r '.files | length' "$DIR/agent-context.json")" -eq 0 ]
  run grep -c "no report" "$DIR/agent-context.json"
  [ "$status" -ne 0 ]
}

@test "an agent with report text still produces an annotation" {
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"reviewer",output:"looked good",files:[$f]}}}')"
  build
  [ "$(jq -r '.files | length' "$DIR/agent-context.json")" -eq 1 ]
  jq -e '.files[0].annotations[0].summary | test("reviewer")' "$DIR/agent-context.json"
  jq -e '.files[0].annotations[0].summary | test("looked good")' "$DIR/agent-context.json"
}

@test "two agents on one file, one with text and one without, yields exactly one annotation" {
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"",files:[$f]},
              a2:{type:"reviewer",output:"looks fine",files:[$f]}}}')"
  build
  [ "$(jq -r '.files | length' "$DIR/agent-context.json")" -eq 1 ]
  [ "$(jq -r '.files[0].annotations | length' "$DIR/agent-context.json")" -eq 1 ]
  jq -e '.files[0].annotations[0].summary | test("reviewer")' "$DIR/agent-context.json"
}

@test "no report text anywhere in the sidecar output, regardless of agent mix" {
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"",files:[$f]},
              a2:{type:"",output:"",files:[$f]},
              a3:{type:"reviewer",output:"looks fine",files:[$f]}}}')"
  build
  run grep -c "no report" "$DIR/agent-context.json"
  [ "$status" -ne 0 ]
}

@test "a file whose only contributor has no text still appears in combined.patch" {
  # Note suppression is an agent-context.json (annotation) concern only - the diff
  # itself must be unaffected by whether any agent had something to say about it.
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"",files:[$f]}}}')"
  build
  [ "$(jq -r '.files | length' "$DIR/agent-context.json")" -eq 0 ]
  grep -q "^diff --git a/repoA/tracked.txt b/repoA/tracked.txt$" "$DIR/combined.patch"
}

@test "truncates a very long output" {
  long="$(head -c 2000 /dev/zero | tr '\0' 'x')"
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" --arg o "$long" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:$o,files:[$f]}}}')"
  build
  [ "$(jq -r '.files[0].annotations[0].summary | length' "$DIR/agent-context.json")" -lt 400 ]
}

@test "renders two agents on one file as two annotations" {
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"one",output:"first",files:[$f]},
              a2:{type:"two",output:"second",files:[$f]}}}')"
  build
  [ "$(jq -r '.files | length' "$DIR/agent-context.json")" -eq 1 ]
  [ "$(jq -r '.files[0].annotations | length' "$DIR/agent-context.json")" -eq 2 ]
}

@test "anchors a deletion-only file on oldRange" {
  cat > "$DIR/combined.patch" <<'EOF'
diff --git a/repoA/gone.txt b/repoA/gone.txt
deleted file mode 100644
index 111..0000000
--- a/repoA/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-one
-two
EOF
  write_state "$(jq -nc --arg f "/x/repoA/gone.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"removed it",files:[$f]}}}')"
  build
  jq -e '.files[0].annotations[0].oldRange[0] == 1' "$DIR/agent-context.json"
}

@test "does not mistake a deleted comment line for a file header" {
  # The deletion line below is the ONLY change in the hunk (no trailing addition), so
  # the anchor can only come from correctly parsing "--- legacy note" as a deleted
  # line (marker "-" + original content "-- legacy note", a 2-dash SQL comment). If the
  # !inhunk guard is dropped, this line is mistaken for a "--- " header instead: no
  # deletion is recorded, the file never gets an anchor, and the assertions below fail.
  cat > "$DIR/combined.patch" <<'EOF'
diff --git a/repoA/q.sql b/repoA/q.sql
index 111..222 100644
--- a/repoA/q.sql
+++ b/repoA/q.sql
@@ -1,2 +1,1 @@
 SELECT 1;
--- legacy note
EOF
  write_state "$(jq -nc --arg f "/x/repoA/q.sql" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"cleaned up",files:[$f]}}}')"
  build
  [ "$(jq -r '.files[0].path' "$DIR/agent-context.json")" = "repoA/q.sql" ]
  [ "$(jq -r '.files[0].annotations[0].oldRange[0]' "$DIR/agent-context.json")" -eq 2 ]
}

@test "handles no agents without producing invalid JSON" {
  write_state "$(jq -nc '{repos:{},agents:{}}')"
  build
  jq -e '.' "$DIR/agent-context.json"
}

# --- HHR_NOTE_MAX_CHARS guard: common.sh not sourced must not mean no notes ---

@test "sidecar.sh sourced without common.sh still produces annotations" {
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"Made the dep required.",files:[$f]}}}')"
  build_no_common
  [ "$(jq -r '.files | length' "$DIR/agent-context.json")" -eq 1 ]
  jq -e '.files[0].annotations[0].summary | test("Made the dep required")' "$DIR/agent-context.json"
}

@test "sidecar.sh sourced without common.sh still truncates a very long output" {
  long="$(head -c 2000 /dev/zero | tr '\0' 'x')"
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" --arg o "$long" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:$o,files:[$f]}}}')"
  build_no_common
  [ "$(jq -r '.files[0].annotations[0].summary | length' "$DIR/agent-context.json")" -lt 400 ]
}

@test "a real HHR_NOTE_MAX_CHARS from common.sh overrides the built-in default" {
  # The default guard must be just that - a guard - never a second source of truth
  # that silently wins over the real configured value from common.sh.
  long="$(head -c 2000 /dev/zero | tr '\0' 'x')"
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" --arg o "$long" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:$o,files:[$f]}}}')"
  build
  got="$(jq -r '.files[0].annotations[0].summary' "$DIR/agent-context.json")"
  # "[impl] " prefix (7 chars) + HHR_NOTE_MAX_CHARS (300) from common.sh.
  [ "${#got}" -eq 307 ]
}

@test "breadcrumb is written and the run still exits 0 when the notes-extraction jq fails" {
  # files:"notarray" (a string, not an array) makes `($a.value.files // [])[]` raise
  # "Cannot iterate over string" - a real failure of the notes-extraction jq, not a
  # simulated one.
  printf '{"repos":{},"agents":{"a1":{"type":"impl","output":"x","files":"notarray"}}}' \
    > "$DIR/state.json"
  run build
  [ "$status" -eq 0 ]
  [ -f "$DIR/.notes-extract-error" ]
  [ -s "$DIR/.notes-extract-error" ]
}

@test "no breadcrumb when the notes-extraction jq succeeds" {
  write_state "$(jq -nc --arg f "/x/repoA/tracked.txt" \
    '{repos:{"/x/repoA":{baseline:"b",prefix:"repoA"}},
      agents:{a1:{type:"impl",output:"fine",files:[$f]}}}')"
  build
  [ ! -f "$DIR/.notes-extract-error" ]
}
