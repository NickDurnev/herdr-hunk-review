# herdr-hunk-review

![version](https://img.shields.io/github/v/tag/NickDurnev/herdr-hunk-review?label=herdr-hunk-review&color=blue&sort=semver)

The badge above reads the latest git tag from GitHub. Until this repo is published and
the first `v0.1.0` tag is pushed, it will render `unknown` — that's expected, not broken.

<!-- DEMO: replace this block with an embedded video or GIF of the pane in action. -->
**Demo video coming soon.**

## What it is

Subagent-driven Claude Code work spreads across several repos and worktrees in a single
session — a backend fix here, a frontend fix there, a test change in a third checkout.
Reviewing that means opening each repo by hand and reconstructing what happened where.

`herdr-hunk-review` keeps a single live diff pane open for the whole session instead.
It watches every repo the session touches, stitches the changes into one combined patch,
attaches the closing note from whichever subagent made each change, and refreshes the
pane automatically — so the diff is always there, already organized, without you asking
for it.

## What you see

One pane, every repo the session touched, each subagent's own closing note anchored to the
line it changed. Captured from a real run:

```
  billing-api/handlers.py                                         +1 -0
 ▌··· 1 unchanged line ···
 ▌@@ -2,3 +2,4 @@ class InvoiceHandler:
 ▌2 2        def __init__(self, repo, audit_repo):
 ▌3 3            self.repo = repo
 ▌4 4            self.audit_repo = audit_repo
 ▌  5 +          self.audit_repo.record(invoice)                       │
     ╭─ Agent note - billing-api/handlers.py R5 ──────────────────────┬┘
     │                                                                │
     │ [impl-handler] Made audit_repo required - the Optional guard   │
     │ silently skipped invoice writes.                               │
     ╰────────────────────────────────────────────────────────────────╯
```

With several repos in play each appears under its own prefix in the same patch, so a
change in a backend service and the worktree of a frontend sit side by side in one scroll.

## How it works

Six hooks, each doing one small thing:

| Hook | Script | Does |
|---|---|---|
| `SessionStart` | `init.sh` | Creates the session's state directory before anything else can race on it. |
| `PreToolUse` (`Edit\|Write\|NotebookEdit`) | `prebaseline.sh` | Snapshots each repo's pre-edit baseline the first time the session touches it. |
| `PostToolUse` (`Edit\|Write\|NotebookEdit`) | `track.sh` | Records which agent touched which file, and which repo it lives in. |
| `SubagentStop` | `note.sh` | Captures the subagent's closing report as that file's note, then refreshes. |
| `Stop` | `refresh.sh` | Rebuilds the combined patch and sidecar, and makes sure the pane is showing them. |
| `SessionEnd` | `cleanup.sh` | Closes the pane this session opened. |

The baseline snapshot runs on `PreToolUse`, not `PostToolUse`, on purpose: by the time
`PostToolUse` fires, the write has already landed, so a baseline taken there would
already include the very edit it's supposed to exclude — the first change to every repo
would silently vanish from the diff. Taking it before the write closes that gap.

### Baselining a repo with an unresolved merge

The baseline is normally `git stash create` — a commit that folds the tree's dirty
state in, so a plain `git diff` against it already excludes that drift. On a repo
with a genuine unresolved merge (`DU`/unmerged paths), `stash create` refuses to run
at all and the baseline falls back to plain `HEAD` — which, unlike the clean-tree
case, does **not** itself exclude anything: the repo's pre-existing modified and
unmerged paths sit outside that commit entirely, so every one of them would otherwise
show up as if the session had made it, on every refresh, and reappear identically
after closing the pane (acknowledgment re-baselines through the same failing `stash
create`).

To keep the fallback meaningful, this path also snapshots the set of paths already
dirty or unmerged at that moment and excludes them from the diff explicitly —
subtracting any path the session itself went on to edit, so that one still appears.
Both `/herdr-hunk-review:hunk-baseline` and the pane-close acknowledgment recompute this set on every
re-baseline, so acknowledging a still-conflicted repo actually clears the pane instead
of silently doing nothing.

## Requirements

- **`git`** and **`jq`** — required. Every hook that touches state needs them; without
  either, hooks exit cleanly and do nothing.
- **`awk`**, **`stat`**, **`date`**, **`cmp`** — required. Used respectively to anchor
  notes to changed lines, read lock/patch mtimes, parse `hunk`'s session timestamps, and
  detect whether a rebuilt patch actually changed.
- **`herdr`** — optional. Without it, no pane opens, but the combined patch and sidecar
  files are still written to the session's state directory on every refresh.
- **`hunk`** — optional. Without it, the same applies: no viewer opens, but the patch
  file is still produced and can be opened with any other diff viewer.

Developed and tested on macOS with bash 3.2; every script is POSIX `sh`, with no
bash-only or GNU-only constructs.

## Installation

In Claude Code, run **both** commands, in this order:

```
/plugin marketplace add NickDurnev/herdr-hunk-review
/plugin install herdr-hunk-review@nickdurnev
```

The first registers this repo as a plugin marketplace; the second installs from it.
Running only the second gives `Marketplace "nickdurnev" not found` — `/plugin install`
resolves names that are already registered, it does not fetch them.

To work from a local checkout instead, point the first command at the directory:

```
/plugin marketplace add /path/to/herdr-hunk-review
/plugin install herdr-hunk-review@nickdurnev
```

Nothing else is required: the hooks register themselves, and the pane appears the first
time the session changes a file in a git repository.

## Closing the pane

Closing the pane is not a neutral act — it means "I have reviewed this; don't show it to
me again." The plugin only notices the pane is gone on the *next* refresh (closing isn't
intercepted directly, so this can lag by one refresh cycle), and when it does, provided
nothing new landed in the meantime, it resets the baseline for every tracked repo — the
same reset `/herdr-hunk-review:hunk-baseline` does. The acknowledged work then drops out of the diff, and
the pane stays shut until new work shows up, at which point it reopens on its own.

Nothing is discarded. The changes themselves are untouched in your working tree and in
git — closing only forgets that the plugin's own pane already showed them to you. You can
always diff them by hand (`git diff <old-baseline>`, `git log`, or any other tool),
whether or not the pane remembers to show them again.

If new work lands between the pane's last display and the plugin noticing it was closed,
that work is never silently acknowledged — the pane reopens instead, showing everything,
including the part that would otherwise have been swallowed. The check is exact: only a
patch that is byte-for-byte identical to what was last shown gets acknowledged; anything
else reopens the pane.

`/herdr-hunk-review:hunk-baseline` does the same acknowledgment explicitly, on demand, without requiring you
to close the pane first — useful when you want to mark everything as reviewed but keep
watching for what comes next.

## Commands

Claude Code namespaces plugin commands, so each one is invoked as
`/herdr-hunk-review:<command>` — the bare `/hunk-review` will report
`Unknown command`. Type `/herdr` and let completion fill in the rest.


| Command | Does |
|---|---|
| `/herdr-hunk-review:hunk-review` | Refreshes the pane immediately and opens it if there is anything to show and it isn't already open. If everything so far has already been acknowledged (see [Closing the pane](#closing-the-pane)), it reports that instead of opening an empty pane. |
| `/herdr-hunk-review:hunk-baseline` | Acknowledges everything the pane currently shows and resets the diff baseline, without closing the pane — the same acknowledgment that happens automatically when you close the pane yourself, done explicitly. |
| `/herdr-hunk-review:hunk-pause` | Toggles automatic refreshing on and off for the current session. |

## Using it outside herdr

Without `herdr`, no pane opens automatically, but nothing is lost — the same patch and
sidecar files the pane would have shown are sitting in the session's state directory.
Point `hunk` at them yourself:

```
hunk patch <dir>/combined.patch --agent-context <dir>/agent-context.json --agent-notes --watch
```

`--agent-notes` is not optional here — without it, `hunk` ignores the sidecar file
entirely and no notes render, even though the file exists and is well-formed.

## Token cost

The automatic loop costs zero model tokens. Hooks run as ordinary shell scripts
executed by the harness, and every one of this plugin's hooks deliberately prints
nothing — that's what keeps the loop free of token cost, not any special handling on
the harness side. The notes attached to each hunk are just the subagent's own closing
report, sliced and reused rather than regenerated. The only standing cost is the
`description` lines for the three commands and the skill, which sit in the
always-loaded listing like any other plugin's.

## Troubleshooting

**No pane appears.** Check that `HERDR_ENV=1` is set, and that both `herdr` and `hunk`
are on `PATH` — the pane is skipped silently (not an error) when either is missing or
the environment variable isn't set. The patch and sidecar are still being written either
way; see [Using it outside herdr](#using-it-outside-herdr).

**Notes aren't rendering.** Two separate requirements have to both hold: the viewer
must be started with `--agent-notes`, and the sidecar needs at least one *ranged*
annotation — a file-level summary alone renders nothing. If a subagent's note couldn't
be attached at all — an unexpected `agent_id` field, or both `agent_output` and the
transcript fallback coming up empty (see [Where agent notes come from](#where-agent-notes-come-from)
below, and check `note_source` in `state.json`) — the result is no note on that file,
not a degraded one. This holds however the note went missing: `note.sh` exits before
writing anything when `agent_id` is missing, and `sidecar.sh` never emits an annotation
for an agent that has no captured report text (a populated `type` with empty `output`,
or the placeholder `track.sh` seeds before any hook has filled it in) — a subagent
with nothing to say produces no note, never an empty or placeholder one. The diff
itself is unaffected either way.

**The pane stops updating.** `refresh.sh` detects a stalled watch by comparing the
patch's write time against the live session's last-updated timestamp reported by
`hunk`; if the pane lags by more than 10 seconds, it restarts the viewer in place
automatically on the next refresh. If it's still stuck after that, close the pane and
run `/herdr-hunk-review:hunk-review` to reopen it.

**To pause automatic refreshing**, run `/herdr-hunk-review:hunk-pause` — it toggles a marker file that
`refresh.sh` checks before rebuilding the pane, and run it again to resume. Recording
(which repo, which file, which agent, which closing note) is never gated on it — only
the pane refresh is, so nothing edited while paused is lost once you resume.

**I closed the pane and it came back anyway.** It shouldn't, as long as nothing new
landed: `hhr_pane_ensure` keeps a copy of the patch as `shown.patch` the moment a pane is
opened (or reused), and when the pane is gone it byte-for-byte compares that copy against
the current patch before deciding what to do (a copy, not a timestamp — a write-time
comparison can't tell two rewrites inside the same second apart, so it isn't trustworthy
here). An identical patch means the user closed it deliberately and nothing landed since
— see [Closing the pane](#closing-the-pane): the plugin acknowledges it (resets the
baseline, same as `/herdr-hunk-review:hunk-baseline`) and it stays closed. A different patch means new code
landed, so it is never acknowledged and the pane reopens automatically instead.
`/herdr-hunk-review:hunk-pause` never touches this — only `/herdr-hunk-review:hunk-review` bypasses the `shown.patch` check
(via `refresh.sh session_id force`), reopening the pane whenever there is something to
show; if there is genuinely nothing to show (every repo already at its baseline), `/herdr-hunk-review:hunk-review`
reports that instead of opening an empty pane.

**Inspecting the raw hook payload.** Set `HHR_DEBUG_PAYLOAD=1` in the environment
Claude Code's hooks run in, reproduce the scenario you're debugging, then inspect
`<dir>/payloads-<hook_event_name>.jsonl` in the session's state directory (one raw JSON
line per hook invocation that ran while the flag was set). Currently wired into
`note.sh` (`SubagentStop`) and `track.sh` (`PostToolUse`) — the two hooks that read the
`agent_id`/`agent_type`/`agent_output` fields this plugin depends on. It is a complete
no-op — no file touched, no output — whenever the variable is unset.

## Where agent notes come from

The field names this plugin reads off hook payloads — `agent_id`, `agent_type`,
`agent_output` — come from Claude Code's documentation, and have since been verified
against 104 real subagents across two live sessions:

- `agent_id` is populated and correct every time. `note.sh` keys every note by it.
- `agent_type` is populated *sometimes* (it carries the subagent type, e.g.
  `general-purpose`); the `// "agent"` fallback in `note.sh` covers the rest.
- `agent_output` — documented as the subagent's closing report — is **always empty**
  in practice. The text simply isn't on the payload.

So the closing report `note.sh` attaches to each hunk does not come from
`agent_output`. When that field is empty, `note.sh` falls back to the subagent's own
transcript: the harness writes one JSONL file per subagent, at a path derived
entirely from fields already on the payload —
`dirname(transcript_path)/<session_id>/subagents/agent-<agent_id>.jsonl` — and the
note is the text of the last assistant record in that file (read from a bounded tail,
not the whole file — see the comment in `note.sh`).

**This reads a harness-internal layout, not a documented contract.** If a future
harness version changes where or how subagent transcripts are written, this
extraction can silently stop working. It is built to degrade, never to error: every
failure mode — no `transcript_path`, no transcript file at the derived path, malformed
JSON in it, no assistant text in it — falls back to exactly today's behavior (no note
on that file) and never raises. Because of that, a broken extraction and "nothing to
report" look identical from the diff pane alone.

To tell them apart, check `.agents["<agent_id>"].note_source` in the session's
`state.json` (under `hhr_state_root`, per-session — see `common.sh`). It's one of:

| `note_source` | Meaning |
|---|---|
| `payload` | `agent_output` was non-empty and used directly (preferred whenever it's there — costs nothing, and is forward-compatible if the harness starts populating it). |
| `transcript` | `agent_output` was empty; the note came from the subagent transcript fallback above. |
| `none` | Neither source produced text — the harness layout may have changed, or the subagent genuinely left no closing report. |

If notes that used to show up stop appearing, check `note_source` first: `none` across
the board (where you'd expect `transcript`) points at a harness layout change, not a
regression in the subagents themselves. Use `HHR_DEBUG_PAYLOAD=1` (see
[Troubleshooting](#troubleshooting)) to capture the exact payload shape in your own
session before deciding what to change. Every read defaults safely regardless (see
`common.sh`'s `hhr_json_get` and the `// empty` / `// "agent"` fallbacks throughout the
scripts), so if a field is ever absent outright rather than empty, the practical effect
is that `note.sh` exits before writing anything — no note at all for that subagent's
files — not a degraded or partial one. The diff pane itself is unaffected either way.

## Releasing

```
sh scripts/bump.sh [patch|minor|major]
git commit -am "chore: release <version>"
git tag v<version>
git push --follow-tags
```

Ordinary commits never touch the version — only a release does, via `bump.sh`.

## Tests

Requires `bats-core`: `brew install bats-core`. Then `bats tests/` — 115 tests, all
passing.
