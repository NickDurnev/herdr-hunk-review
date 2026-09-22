# Sourced, not executed. POSIX sh; bash 3.2 compatible.
HHR_LOCK_STALE_SECONDS=30
# Shared by note.sh (writes agent notes into state.json) and sidecar.sh (renders them
# into agent-context.json) - one constant, not two, so the two never drift apart.
HHR_NOTE_MAX_CHARS=300

hhr_have() { command -v "$1" >/dev/null 2>&1; }

hhr_state_root() {
  # CLAUDE_PLUGIN_DATA is set by the harness; fall back for tests and manual runs.
  printf '%s' "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/herdr-hunk-review}/sessions"
}

hhr_state_dir() {
  d="$(hhr_state_root)/$1"
  mkdir -p "$d" || return 1
  printf '%s' "$d"
}

hhr_json_get() { jq -r --arg k "$1" '.[$k] // empty'; }

# Diagnostic aid, off by default. When HHR_DEBUG_PAYLOAD=1, append the raw hook
# payload as one JSON line to <dir>/payloads-<hook_event_name>.jsonl, so the real
# shape of a payload (field names, nulls vs empty strings) can be inspected later.
# Complete no-op - no file touched, no stdout - when the variable is unset.
hhr_debug_payload() {
  [ "${HHR_DEBUG_PAYLOAD:-}" = 1 ] || return 0
  [ -n "$1" ] && [ -n "$2" ] || return 0
  evt=$(printf '%s' "$2" | jq -r '.hook_event_name // "unknown"' 2>/dev/null) || evt=unknown
  printf '%s\n' "$2" >> "$1/payloads-$evt.jsonl" 2>/dev/null || true
  return 0
}

# Exit the CALLING script 0 when the plugin must not act. Recording (prebaseline.sh,
# track.sh, note.sh) must run whether or not the session is paused - only refresh.sh
# gates on the `paused` marker, so pausing stops the pane from updating without losing
# the edits made while it was paused.
hhr_guard() {
  hhr_have jq  || exit 0
  hhr_have git || exit 0
  return 0
}

hhr_lock() {
  lock="$1/.lock"
  brk="$1/.lockbreak"
  attempts=0
  # ~5s total (50 * 0.1s): parallel subagents finishing together is the normal case
  # for this plugin, so a single failed mkdir must not drop a caller's write - retry
  # for a bounded window before giving up.
  while [ "$attempts" -lt 50 ]; do
    mkdir "$lock" 2>/dev/null && return 0
    # Contended. Serialise stale-breaking behind a second lock so the staleness test and
    # the break cannot interleave: a racer that measured the OLD lock must not be able to
    # destroy the fresh lock a winner has since created. Measured over 30 concurrent
    # trials: blind rm -rf yields >1 winner 27/30, claim-by-rename 1/30, this 0/30.
    if mkdir "$brk" 2>/dev/null; then
      if [ -d "$lock" ]; then
        now=$(date +%s)
        then_=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")
        if [ $((now - then_)) -gt "$HHR_LOCK_STALE_SECONDS" ]; then
          rm -rf "$lock"
          if mkdir "$lock" 2>/dev/null; then
            rmdir "$brk" 2>/dev/null
            return 0
          fi
        fi
      fi
      rmdir "$brk" 2>/dev/null
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  return 1
}

hhr_unlock() { rm -rf "$1/.lock"; }

# Paths already modified or unmerged in ROOT relative to HEAD, as a JSON array of
# repo-root-relative paths (sorted, unique). Only meaningful on the `git stash create`
# HEAD-fallback path (see hhr_capture_repo_baseline / hhr_reset_repo_baselines below):
# when stash create succeeds it folds the dirty tree into the baseline commit itself,
# so nothing needs excluding and this is never called. `diff HEAD --name-only` alone
# does not surface unmerged paths on every git version, hence the second pass with
# --diff-filter=U.
hhr_dirty_paths_json() {
  { git -C "$1" diff HEAD --name-only 2>/dev/null; \
    git -C "$1" diff --name-only --diff-filter=U 2>/dev/null; } \
    | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# First-touch snapshot for a repo prebaseline.sh/track.sh have not recorded yet this
# session: a de-duplicated `prefix`, and a baseline captured the same way everywhere -
# prefer `git stash create`, which folds the dirty tree into the commit itself so a
# plain `git diff $base` already excludes it. Fall back to `git rev-parse HEAD` when
# stash create is empty (a clean tree) or fails outright (an unresolved merge - stash
# create refuses to touch unmerged paths). Only that fallback leaves pre-existing
# drift unexcluded by the baseline sha itself, so only then is `dirty_at_baseline` also
# recorded: every path already modified or unmerged at that moment, for patch.sh to
# subtract from the diff explicitly (see patch.sh). Idempotent - a no-op if STATE
# already has an entry for ROOT. Writes STATE in place; the caller must hold the lock.
hhr_capture_repo_baseline() {
  state="$1"
  root="$2"
  [ "$(jq -r --arg r "$root" '.repos[$r] // empty' "$state")" = "" ] || return 0

  base=$(git -C "$root" stash create 2>/dev/null) || base=
  if [ -n "$base" ]; then
    dirty='[]'
  else
    base=$(git -C "$root" rev-parse HEAD 2>/dev/null) || base=
    [ -n "$base" ] || return 0
    dirty=$(hhr_dirty_paths_json "$root")
  fi

  prefix=$(basename "$root")
  n=2
  while [ "$(jq -r --arg p "$prefix" '[.repos[] | select(.prefix == $p)] | length' "$state")" != "0" ]; do
    prefix="$(basename "$root")-$n"
    n=$((n + 1))
  done

  jq --arg r "$root" --arg b "$base" --arg p "$prefix" --argjson d "$dirty" \
     '.repos[$r] = ({baseline:$b, prefix:$p} + (if ($d | length) > 0 then {dirty_at_baseline:$d} else {} end))' \
     "$state" > "$state.tmp" && mv "$state.tmp" "$state"
}

# Re-snapshot every tracked repo's baseline to its current working state, and clear
# stored agent notes - the shared core of "acknowledge everything shown so far".
# Shared by baseline.sh (/hunk-baseline) and hhr_pane_ensure's pane-close
# acknowledgment path, so both take an identical snapshot instead of drifting apart as
# two copies. Deliberately does NOT lock: baseline.sh locks around its own call, and
# hhr_pane_ensure runs inside refresh.sh's lock already - locking again here would
# deadlock against the caller's own held lock instead of merely being redundant.
#
# Recomputes `dirty_at_baseline` the same way hhr_capture_repo_baseline does (see
# above) - re-baselining a repo that is still conflicted must record a fresh dirty set,
# or acknowledgment silently does nothing there: closing the pane re-baselines through
# the same failing `git stash create`, and the old dirty set (or none at all) would
# leave the same pre-existing drift showing up again. A repo that has since resolved
# down to a clean tree drops any stale `dirty_at_baseline` from a prior conflicted
# snapshot - stash create succeeding again means nothing needs excluding any more.
#
# A bare `for root in $(jq ...)` word-splits on spaces in the repo path; read the
# keys from a file instead, one per line, like hhr_build_patch does.
hhr_reset_repo_baselines() {
  dir="$1"
  state="$dir/state.json"
  [ -f "$state" ] || return 0
  reposlist="$dir/.baseline.repos.tmp"
  jq -r '.repos | keys[]' "$state" > "$reposlist"
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    base=$(git -C "$root" stash create 2>/dev/null) || base=
    if [ -n "$base" ]; then
      dirty='[]'
    else
      base=$(git -C "$root" rev-parse HEAD 2>/dev/null) || continue
      dirty=$(hhr_dirty_paths_json "$root")
    fi
    jq --arg r "$root" --arg b "$base" --argjson d "$dirty" \
       'if ($d | length) > 0
        then .repos[$r].baseline = $b | .repos[$r].dirty_at_baseline = $d
        else .repos[$r].baseline = $b | .repos[$r] |= del(.dirty_at_baseline) end' \
       "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  done < "$reposlist"
  rm -f "$reposlist"
  jq '.agents = {}' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  return 0
}
