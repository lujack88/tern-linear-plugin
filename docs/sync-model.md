# Sync model

How version 0.4.0 keeps the Board in step with Linear.

## Host and window halves

The plugin is split because of one platform rule: **secrets are window-only**
(`tern.secrets` does not exist in the host VM). The board block itself runs in
the host half, so it cannot read the API key.

- **Window half** (`window.luau`) owns the commands, the keychain and the Setup.
- **Host half** (`host.luau`) owns the block: it polls Linear, holds the board
  state, and performs the edits.

The window injects the key into the block's memory with
`cx.session:event(pane, { ev = "action", act = "key", value = teamId, key = key })`.
Nothing is written to disk, and the block discards the key when the pane closes.
A window that finds no board pane reads no secret at all.

The window injects again on `window_start`, 300 ms after load (a reload does not
fire `window_start`), after setup, and up to 3 s after opening a board, to cover
the block's init race. The block ignores a duplicate key for the same team.

## Stored state

Everything else lives in the plugin key/value store (`kv.json`), shared by both
halves.

| Key | Contents |
| --- | --- |
| `linear-todo.setup` | `{teamId, teamKey, orgUrlKey, viewerId}`. |
| `linear-todo.cache` | `{teamId, states, issues}` from the last sync, so a reopened board paints before the network answers. Ignored when its `teamId` is not the Setup's; cleared when setup picks another team. |
| `linear-todo.status` | `{at, ok, error?, issues}` for `Linear: status`. |
| `linear-todo.view` | `"kanban"` or `"list"`. |
| `linear-todo.mine` | `true` while the Mine toggle is on. |
| `linear-todo.interval` | Poll interval in seconds; 60 when unset or below 30. |
| `linear-todo.selftest` | `"ok"` or the last self-test failure. |

The API key is in the OS keychain as `plugin.linear-todo.key`, never in
`kv.json`.

0.2 stored `linear-todo.workspaces`, `linear-todo.active`,
`linear-todo.cache.<orgId>`, `linear-todo.status.<orgId>` and keychain entries
`plugin.linear-todo.key.<orgId>`. The window half migrates them once (see the
README) and deletes them.

## Fetching

One sync is two steps:

1. The team's workflow States: `team(id) { states { nodes { id name type position } } }`.
2. The team's issues, one request per page, `orderBy: updatedAt`, filtered to
   `team: { id: { eq: teamId } }`: every open State (`backlog`, `unstarted`,
   `started`), plus issues completed within the last 14 days. Up to 10 pages of
   100; more is refused rather than truncated.

Both are cached together. The Mine toggle filters on `assignee.id == viewerId`
on the board and makes no request.

Polling runs only while a board pane exists and is armed by a repeating timer, so
closing the board stops all traffic. Network errors, `429` and `5xx` back off
exponentially up to 600 s; other errors surface in `Linear: status` and in the
board's header.

## Creating

Opening the New issue modal fetches its choices in one request (`linear.META`):
the team's estimate scale and `cyclesEnabled`, its members, labels, projects and
upcoming cycles (`isPast: false`), the workspace's team-less labels, and every
template (`templates`, filtered to `type == "issue"` of this team or of no team).
The fetch runs on every open and lives in the block's memory only; the previous
answer is shown while it runs. Status, priority and due date need nothing fetched.

`issueCreate` gets `teamId`, `title`, `stateId` and `priority`, plus each
property that is set. With a template it also gets `templateId`, and then every
property the modal shows is sent, `null` when cleared, because Linear lets input
values override the template's. The description is sent only when it differs
from what the template filled in; untouched, Linear applies the template's own
rich text. Template descriptions arrive as ProseMirror (`descriptionData`) and are
shown as Markdown (`model.markdown`).

The modal closes as soon as the request is sent, and the issue shows as
"Creating…" in its column. A failure reopens the modal with the draft when it was
closed; with Create more on, the failed title is named in the error toast.

## Optimistic overlay

An edit is applied to the board's overlay immediately, keyed by issue id:
`{stateId?, title?, gone?}`. The issue moves or renames at once.

- `model.effective(issue, overlay)` merges the overlay over the fetched issue.
- `model.columns(issues, states, overlay, opts)` regroups and sorts the result,
  one column per visible State; `model.list(columns)` flattens it into the List
  View's row order.

When Linear confirms, the returned issue replaces the fetched one and the
overlay entry is dropped. When the call fails, the overlay entry is discarded
too, so the issue snaps back to the last known Linear truth and the error is
shown. The overlay is never persisted; a reload always shows fetched state.

## Undo

The board keeps one undo step, valid for 10 s (the undo bar; `Ctrl+Z`/`Cmd+Z`).

| Edit | Undo does |
| --- | --- |
| Move | Writes the previous State id back. |
| Rename | Writes the previous title back. |
| Create | Cancels the newly created issue. |
| Cancel | Writes the previous State id back. |

Undo is itself an ordinary Linear edit, so it can fail like any other and then
rolls back the same way. Ten seconds after the edit, or after a second edit, the
step is dropped.

## Ordering

Columns follow the State type (`backlog`, `unstarted`, `started`, `completed`),
then Linear's State `position`. Inside a column, issues sort by priority (Urgent
1, High 2, Medium 3, Low 4, none last), then `updatedAt` descending, then
identifier ascending. This version does not read or write Linear's manual sort
order (`sortOrder`), so a move never reorders an issue within a column.

## "Delete" means cancel

The board never deletes an issue. `✕` or `Delete` pressed twice moves the issue
to the team's lowest-positioned `canceled` State, which is how Linear expresses a
discarded issue.

## Language mapping

| Board | Linear |
| --- | --- |
| Column (Kanban) or group (List) | one workflow State of type `backlog`, `unstarted`, `started` or `completed` |
| hidden | States of type `canceled`, `duplicate`, `triage` |
| Mine | `assignee.id` equals the key's `viewer.id` |
