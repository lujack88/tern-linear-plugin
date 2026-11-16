# Sync model

How version 0.9.0 keeps the Board in step with Linear.

## Host and window halves

The plugin is split because of one platform rule: **secrets are window-only**
(`tern.secrets` does not exist in the host VM). The board block itself runs in
the host half, so it cannot read the API key.

- **Window half** (`window.luau`) owns the commands, the keychain and the workspaces.
- **Host half** (`host.luau`) owns the block: it polls Linear, holds the board
  state, and performs the edits.

The window injects every workspace's key into the block's memory with
`cx.session:event(pane, { ev = "action", act = "key", value = teamId, key = key, keys = { [orgId] = key } })`:
`value` and `key` are the active workspace's, `keys` all of them, so the board's
own workspace switcher needs no round trip to the window. Nothing is written to
disk, and the block discards the keys when the pane closes. A window that finds no
board pane reads no secret at all.

The block has no way to call the window half, yet adding a workspace needs the
window's keychain and prompts. So the board's **Add workspace…** sets the pane
title to `Model.ADD_TITLE`; the window half watches board panes' `title` events,
answers with `{act = "ws-added"}` (the title reverts) and runs its key prompt.

Starting work on an issue needs `cx.agents:start`, which is also window-only.
**▷ Start** (card/row control, the issue view's header or the Tasks View's card)
loads the description when the issue view has not, writes a one-item list of
`Model.startPrompts` items, `{prompt, issueId, model?, thinking?, cwd?}`, to kv
`linear-todo.start` and sets the title to `Model.START_TITLE`. `prompt` is the
chat's first message (`Model.startPrompt`). The window answers with
`{act = "started"}`, takes and clears the kv entry, and opens an omp chat per item
in the item's `cwd`, else the board pane's cwd, else `~`. The command is
`Model.startCommand`: `omp --plan --config <plugin dir>/plan-mode.yml`. `--plan`
starts the Plannotator omp plugin's plan mode (omp's own plan mode stays off), and
the overlay sets `task.prewalk`
and the reviewer models (`task.agentModelOverrides`) for this chat only; plus
`--model <model>` and `--thinking <level>` when the item has them. A value that is
not safe on a command line is left out. Only the Tasks View card sets `model`,
`thinking` and `cwd` (its Model, Thinking and Project pills); a picked folder goes
to the front of kv `linear-todo.folders`. A failed description fetch still starts
the chat; the prompt says the description could not be loaded.
The bulk bar's **▷ Start** and the selection menu's **▷ Start in omp** use the same
path for up to 10 issues, without picks: the descriptions load in parallel, and
once all have answered the board writes one item per issue, and the window half
opens one omp chat per item, each in its own tab, in the board's order. Items not
in this shape, from a board loaded before 0.9.0, start nothing.

The card's Model pill lists omp's chat models from `omp models --json`. The host
half runs it (`tern.process.run`) once per board, when a card first opens; each
model brings its own Thinking levels. A failure leaves only "Default model".

**Send to chat** uses the same title channel twice, because the open chats
(`cx.agents:list`), `cx.agents:ask`, `cx:ask_carly` and `cx.layout:focus` are all
window-only:

1. Opening the list sets the title to `Model.CHATS_TITLE`. The window answers with
   `{act = "chats", chats = {{pane, label, meta, icon, state}, …}}` straight in the
   event (no kv): Carly first (`pane = "carly"`, icon `tile-carly`, no meta), then
   every agent that has not exited, named by `Model.chatRow` as the tab list names
   it (`label`) with its folder · model · state (`meta`) and Tern tile icon
   (`tile-omp`, `tile-claude`, …). Until it answers the list reads "Loading chats…".
2. Picking a chat loads the descriptions as Start does, writes
   `{pane, label, prompt = Model.contextPrompt(…), ids}` to kv `linear-todo.send`
   (`ids`: the picked issues' ids) and sets the title to `Model.SEND_TITLE`. The
   window answers `{act = "sent"}`, takes and clears the kv entry, and calls
   `cx.agents:ask` (then focuses that pane and toasts) or `cx:ask_carly`. A failed
   send toasts the error.

**Open pane** (the Tasks View card's button, or a row's glyph when its issue has
a linked chat) needs `cx.layout:focus`. It writes the chat's pane to kv
`linear-todo.focus` and sets the title to `Model.FOCUS_TITLE`
("Linear · focusing a chat…"). The window answers `{act = "focused"}` (the title
reverts), takes and clears the kv entry and focuses the pane; a pane that is gone
toasts "That chat is closed".

The window half remembers which chat each Start or Send to chat used, in kv
`linear-todo.links` (`{[issueId] = pane}`). Only the window writes it; a send to
Carly is not linked. A window timer runs every second and, while a board pane
exists, pushes the linked chats to every board pane straight in the event:
`{act = "agents", agents = {{issue, pane, state, cwd?}, …}}`, `state` being
`working`, `waiting_input`, `idle` or `exited` (a linked pane still open but no
longer an agent is `exited`). It sends when the list changed or 4 s passed since
the last push, and at once after a Start or Send records a link. A link whose
pane is gone is dropped from kv. The board shows the state on the Tasks View's
rows and card only: a chat never changes an issue's State, so closing it just
removes the status.

The window hands the keys over on `window_start`, 300 ms after load (a reload does
not fire `window_start`) and after adding or switching a workspace. An event sent
while a block is still starting is dropped, so a board that has a workspace but no
key asks for it: its title reads `Linear · connecting…` (`Model.KEY_TITLE`), and the
window half, which checks the board titles every second, hands the keys over. A
workspace whose key the keychain lacks is not asked for again until it is added or
switched to. The block ignores a duplicate key
for the same team. A new key for the same team only restarts polling; writes
already in flight finish normally. A different team clears the board.

## Stored state

Everything else lives in the plugin key/value store (`kv.json`), shared by both
halves.

| Key | Contents |
| --- | --- |
| `linear-todo.workspaces` | Array of `{orgId, orgName, orgUrlKey, viewerId, teamId, teamKey}`, one per Linear workspace. |
| `linear-todo.setup` | The active workspace (same shape); the host half reads only this. |
| `linear-todo.cache.<teamId>` | `{teamId, states, issues}` from the team's last sync, so a reopened or switched-to board paints before the network answers. |
| `linear-todo.status` | `{at, ok, error?, issues}` of the last sync, for `Linear: status`. |
| `linear-todo.view` | `"kanban"`, `"list"` or `"tasks"`. |
| `linear-todo.mine` | `true` while the Mine toggle is on. |
| `linear-todo.folded` | `{[stateId] = true}` for collapsed columns / List groups. The Tasks View's Backlog and Done groups are not stored; they start folded. |
| `linear-todo.links` | `{[issueId] = pane}`: the chat each Start or Send to chat used; written by the window half only. |
| `linear-todo.folders` | Recent Project folders picked on the Tasks View card, most recent first, at most 8. |
| `linear-todo.interval` | Poll interval in seconds; 60 when unset or below 30. |
| `linear-todo.selftest` | `"ok"` or the last self-test failure. |

Each key is in the OS keychain as `plugin.linear-todo.key.<orgId>`, never in
`kv.json`.

0.3–0.5 kept one key as `plugin.linear-todo.key` and a `setup` without its
organization. On the next window start the window half asks Linear whose key it
is, stores it as `key.<orgId>`, writes the one-entry workspace list and the full
`setup`, and only then deletes the old key and `linear-todo.cache`.

## Fetching

One sync is two steps:

1. The team's workflow States: `team(id) { states { nodes { id name type position } } }`.
2. The team's issues, one request per page, `orderBy: updatedAt`, filtered to
   `team: { id: { eq: teamId } }`: every open State (`backlog`, `unstarted`,
   `started`), plus issues completed within the last 14 days. Up to 10 pages of
   100; more is refused rather than truncated. Each issue carries its `parent
   { id identifier }` and up to 50 `children { nodes { id state { type } } }`
   for sub-issue nesting and progress.

Both are cached together. The Mine toggle filters on `assignee.id == viewerId`
on the board and makes no request.

A fetch takes a snapshot over several requests, so it can predate a write that
lands while it runs. When a move, rename, cancel, undo or create succeeded during
a fetch, its answer is discarded and the fetch runs again. An answer older than
one already applied (a manual sync beside a poll) is ignored. kv read and write
errors on the host side are swallowed, so they never stop the poll.

Polling runs only while a board pane exists and is armed by a repeating timer, so
closing the board stops all traffic. Network errors, `429` and `5xx` back off
exponentially up to 600 s; other errors surface in `Linear: status` and in the
board's header. The window's `agents` push makes no request and sends nothing
while no board pane exists.

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

## The issue view

The board's issue fields include `dueDate`, `project` and `cycle`, so the view's
property chips come straight from the board issue. Opening an issue fetches only
what the board lacks (`linear.DETAIL`): the Markdown `description`, the creator,
`createdAt`, `branchName`, up to 100 comments, up to 50 `children` (identifier,
title, url, state, assignee, first 10 labels), `history(first: 50)` (actor,
`fromState`/`toState`, `relationChanges`), and `relations` / `inverseRelations`
(the other issue's identifier, title, url and state). Nested lists stay small to
keep the query under Linear's complexity limit. None of it is cached, so old
board caches load unchanged. Choices for the lists come from `linear.META`,
fetched when none are loaded yet.

The activity merges creation, history and comments by time (`Model.timeline`).
A relation change's code is "a"/"r" then the relation letter ("ar": added
related).

Edits use the board's own write path (`push`, with the overlay and undo):

- **Title**: `rename`, when the title field loses the caret.
- **Description**: `issueUpdate { description }`, when the field loses the caret
  and the text changed.
- **Status**: `move`.
- **Other properties**: one `issueUpdate` with just the changed fields (`null`
  when cleared), and an undo that writes the old values back.
- **Comment**: `commentCreate { issueId, body }`, appended when Linear confirms.
- **Sub-issue**: the create modal's `issueCreate` with `parentId`; the new issue
  joins the open parent's list when Linear confirms.

Linear's values flow into every field the caret is not in. The chips take them
only while no write to the issue is in flight, so a refused write snaps back. The
view closes by itself when the issue leaves the board.

## Optimistic overlay

An edit is applied to the board's overlay immediately, keyed by issue id:
`{stateId?, title?, gone?}`. The issue moves or renames at once.

- `model.effective(issue, overlay)` merges the overlay over the fetched issue.
- `model.columns(issues, states, overlay, opts)` regroups and sorts the result,
  one column per visible State; `model.list(columns)` flattens it into the List
  View's row order, each group nested by `model.nest` (see Ordering).

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

In the List View, `model.nest` then moves each sub-issue whose parent is in the
same group right after its parent, siblings in that order, recursively; rows are
indented one level per depth, capped at 3. A sub-issue whose parent is in another
group, hidden by Mine, canceled or not fetched stays where it sorted, at the top
level. Kanban columns keep the plain order. Caches from before these fields load
as flat boards until the next sync.

A parent's progress pill counts its sub-issues as done when their State type is
`completed`, `canceled` or `duplicate`: nothing is left to do on them. It reads
the parent's own `children` from the last sync, so a sub-issue moved on the board
updates its parent's pill only after the next sync.

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
