---
name: herdr-hunk-review
description: Drive the live session diff pane - navigate the user to a file or hunk, leave review comments, and highlight ranges while explaining. Use when the user asks to walk through the session's changes, points at the diff pane, or asks what changed.
---

# Session diff pane control

The pane shows `combined.patch`: every change this session made, across every repo,
with paths prefixed by repo name (`billing-api/app/...`). The plugin's hooks own that
pane - you steer it through `hunk session`, you never open a viewer yourself.

## Find the session

It is a patch-backed session, so `--repo` does not select it (there is no repo) and
`--session-path` is rejected outright. Address it by `sessionId`:

```bash
hunk session list --json | jq -r '.sessions[] | select(.inputKind == "patch") | .sessionId'
```

If more than one patch session could be live and you need the exact one this plugin
opened, match `sourceLabel` instead - it is the patch path exactly as passed on the
command line (not the session's `cwd`, which is the project directory, not the state
directory):

```bash
hunk session list --json | jq -r --arg l "<state-dir>/combined.patch" \
  '.sessions[] | select(.sourceLabel == $l) | .sessionId'
```

If `hunk session list` reports no patch session, there is no pane open. Say so and
offer `/hunk-review`. Do not try to open one yourself.

## Read before you steer

```bash
hunk session review <sid> --json                   # file and hunk structure
hunk session review <sid> --include-patch --json   # raw diff, only when needed
hunk session context <sid> --json                  # where the user is looking
```

Prefer the structure call. Pull raw patch text only for the files you must read.

A refresh can reload the pane mid-conversation (new commits, a new agent turn). Line
numbers you read earlier in the conversation can go stale when that happens - re-run
`session review` before navigating or commenting rather than trusting them.

## Steer

```bash
hunk session navigate <sid> --file billing-api/app/campaigns/handlers.py --hunk 1
hunk session navigate <sid> --file <path> --new-line 128
```

Paths must include the repo prefix exactly as `session review` reports them - not the
path relative to that repo's own root.

## Annotate

One note:

```bash
hunk session comment add <sid> --file <path> --new-line 128 \
  --summary "This drops the Optional guard" --rationale "..." --author claude
```

Several at once, which is preferred when you already have findings ready:

```bash
printf '%s' '{"comments":[{"filePath":"<path>","newLine":128,"summary":"..."}]}' \
  | hunk session comment apply <sid> --stdin
```

Highlight the exact expression while you talk about it:

```bash
hunk session highlight add <sid> --file <path> --new-line 128 --start 6 --end 19 --tone warning
```

List or remove comments with `hunk session comment list <sid> --json` and
`hunk session comment rm <sid> <comment-id>`.

## Rules

- Never run `hunk diff`, `hunk show` or `hunk patch` yourself. The TUI belongs to the
  user; the plugin's hooks already own the viewer, and spawning a second one leaves a
  stray pane behind.
- Do not edit `combined.patch` or `agent-context.json`. They are regenerated on every
  refresh and your edits would vanish.
- A refresh may reload the pane under you. Re-read `session review` rather than
  trusting line numbers from earlier in the conversation.
- Your job is to steer and explain. The review is the user's.
