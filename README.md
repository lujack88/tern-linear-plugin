# Linear Taskboard

A Tern host + window plugin that shows every Issue of one Linear team as a
Linear-style Board, as a Kanban or a List View, and writes every change straight
back to Linear. The host half renders the board block and talks to Linear; the
window half holds the commands, the keychain and the workspaces.

Open it with **Linear: open board**. The board lives in its own pane and stays in
step with Linear while that pane exists.

## Workspaces

A workspace is one Linear workspace (organization), its API key, and the team its
board shows.

**Add one** with **Add workspace…** in the header's workspace menu, or with
**Linear: add workspace**:

1. Paste a Linear personal API key. Create one in that Linear workspace under
   **Settings → Security & access → Personal API keys**. The key is checked with
   a `viewer` query before anything is stored.
2. Type the team key (`ENG`). An unknown key shows the valid ones and asks
   again.

The new workspace becomes the board's. Adding a workspace that is already there
replaces its key and team (use this to change the team).

**Switch** with the workspace button at the left of the board's header. Like
Linear's workspace menu, it drops down every workspace with its initials, team and
number: click one or press `1`–`9`; `Esc` closes it. **Add workspace…** at the
bottom opens the key prompt above, so no command is needed. **Linear: switch
workspace** does the same from the palette. Every team keeps its own cache, so a
switch paints the last known board at once and syncs it.

Each key is stored in the OS keychain as `plugin.linear-todo.key.<orgId>`. Keys
are never written to a file, and the board receives them in memory only.

Until a workspace is added, the board shows a "Run Linear: add workspace" message.
Upgrading from 0.5 files the existing key and team as the first workspace on the
next window start; nothing needs to be pasted again.

## The Board

One column per workflow State of the team, in Linear's order: Backlog, then
Unstarted, Started and Completed States, each group by Linear's position.
Canceled, Duplicate and Triage States are hidden. Completed issues stay for 14
days.

A card shows the priority icon (Urgent, High, Medium, Low or none), the
identifier (`ENG-42`), the title, its labels, the assignee's initials avatar, the
estimate, and the State. Columns sort by priority, then by most recently updated,
then identifier. Moving never reorders inside a column.

The header holds the team key, the **Kanban | List** tabs, the **Mine** toggle
(only issues assigned to you), the issue count, the last sync time and the last
error.

### Views

- **Kanban**: one column per State; the board scrolls sideways when the columns
  (at least 240 px each) do not fit.
- **List**: one group per State, headed by its name and count, with compact rows
  (priority, identifier, title, labels, estimate, assignee). `↑`/`↓` run on
  across groups.

Each column (Kanban) or group (List) collapses with the `▾` before its name, and
expands with `▸`; collapsed ones keep their count, and the arrow keys skip them.

The View, the Mine toggle and the collapsed columns are remembered.

## Clicking an issue

- **Click** a row or card: its menu opens under it (below).
- **Double-click**, or select it with the arrow keys and press `Enter`: the issue
  view opens.
- While an issue is lifted for a move, a click drops it instead.

The checkbox, `⠿`, `✎`, `✕` and `▷` keep their own actions.

### The issue menu

As in Linear's right-click menu (Tern blocks get no right-click, so a plain click
opens it; `m` opens it for the keyboard-selected issue):

- **Status ▸**, **Priority ▸**, **Assignee ▸**: open the New issue modal's list in
  the menu, the current value checked, with a filter field and a **‹ Back** row.
- **Open issue** (`Enter`), **▷ Start in omp**, **Open in Linear**, **Copy ID**,
  **Copy link**, **Rename** (`R`), and **Cancel issue** (click twice).

When the clicked issue is one of several selected, the menu acts on the whole
selection: its title says how many, and it offers Status, Priority, Assignee,
**▷ Start in omp**, **Copy IDs** and **Cancel N issues**. Every change offers one undo.

Keys while it is open: `↑`/`↓` (or `K`/`J`) move, `Enter` runs, `→`/`Enter` opens
a ▸ list, `←` (or `Backspace` in an empty filter) goes back, `Esc` closes. A click
outside closes it.

## The issue view

Double-click an issue (or select it with the arrow keys and press `Enter`) to
open it in place of the board, as Linear's list does:

- **Title**: edit it in place. It saves on `Enter`, `Tab`, `Esc` or a click elsewhere.
- **Description**: shown as Markdown. Click it to edit, and it saves when you leave
  it (`Esc`, `Ctrl+Enter`, `Tab` or a click elsewhere).
- **Properties** (right): the same chips and lists as the New issue modal (Status,
  Priority, Assignee, Labels, Estimate, Project, Cycle, Due date), with the same
  shortcuts. Each change is written to Linear at once.
- **Activity**: who created the issue, then the comments, oldest first. Write a
  comment in the box at the bottom and send it with **Comment** or `Ctrl+Enter`.
- **Header**: `←` back to the board (`Esc`), **▷ Start**, **Open in Linear ↗**,
  and **Cancel issue** (click twice).

`J` / `K` open the next or previous issue in the board's order. Every edit offers
the usual one-step undo. Times are shown in UTC. Comments can be read and added
here, not edited or deleted.

## Moving an issue

- Mouse: click the grip `⠿`, then click the destination column or group.
- Keyboard: `Space` to pick up, `←`/`→` to change State, `Enter` to drop.
- `Shift+←` / `Shift+→` moves the focused issue to the previous or next State.

The same keys work in both Views. While an issue is lifted, the States it can be
dropped into are highlighted. `Esc` cancels the lift.

A move writes that exact State to Linear immediately. While the request is in
flight the issue is drawn in its new State (an optimistic overlay); if Linear
refuses, it returns to its old State.

## Creating an issue

| Action | Key |
| --- | --- |
| New issue | click **+ New issue** in the header, click `+` on a column or group, or `c` |
| New issue from a template | `Alt+C` |

Both open a **New issue** modal, as in Linear: title, a Markdown description, and
one chip per property. Clicking a chip opens a searchable list (`↑`/`↓`, `Enter`,
`Esc`):

| Chip | Shortcut | Notes |
| --- | --- | --- |
| Status | `S` | starts at the column you created from |
| Priority | `P` | |
| Assignee | `A` | you first; with Mine on, you are preselected |
| Labels | `L` | several at once; one label per label group |
| Estimate | `E` | the team's scale; hidden when the team does not estimate |
| Project | `Shift+P` | open projects of the team |
| Cycle | `Shift+C` | upcoming cycles; hidden when the team has cycles off |
| Due date | `Shift+D` | type `YYYY-MM-DD` or pick Today, Tomorrow, End of this week, In one week |
| Template | `T` | Linear's issue templates of this team and the workspace |

The shortcuts work while the caret is outside the title and description (`Esc`
leaves a field, `Tab` moves between them). `Ctrl+Enter` / `Cmd+Enter` creates
the issue. `Esc` outside a field, or a click outside the modal, closes it and keeps
the draft: the next New issue opens it again as it was (a created issue clears it).
A click outside an open list closes just the list.
**Create more** keeps the modal open with the same properties after each issue.

A template fills the modal with its title, description and properties. The issue
is created with the template's id, so Linear also applies what the modal does
not show (sub-issues, for example). Every property the modal shows is sent as
shown, so clearing a chip clears the template's value. Leaving the description
untouched keeps the template's own formatting.

## Renaming, canceling, starting

| Action | Key |
| --- | --- |
| Rename | click ✎, or `r` / `F2` |
| Start in omp | click **▷ Start** on a row or in the issue view, or the **▷** at a card's bottom-right |

Start opens a new omp chat in plan mode. Its first message is the issue:
identifier, title, URL, State, priority, assignee, labels and description. It
tells omp to grill you about the approach with the `grilling` skill, then write
the plan, and to implement nothing until you approve it. The chat runs in the
board pane's directory, else your home.

`✕` (or `Delete` pressed twice) cancels an issue: it moves to the team's
Canceled State. The plugin never deletes issues.

Undo the last edit with the undo bar (shown for 10 s) or `Ctrl+Z` / `Cmd+Z`.
Undo is one step: a move or rename returns to the previous value, a create
cancels the new issue, a cancel restores the previous State.

## Selecting several issues

| Action | Key |
| --- | --- |
| Select / unselect an issue | click its checkbox (left of a row, top-left of a card), or `x` on the keyboard-selected issue |
| Select a range | `Shift`-click a checkbox: every issue from the last one ticked, in the board's order |
| Clear the selection | `Esc`, or `×` in the bar |

The checkbox shows when you hover an issue, and on every issue while any is
selected; selected issues are tinted. A click on the rest of a selected row or
card opens the issue menu for the whole selection. The selection is not saved;
issues that are canceled, synced away, or hidden by Mine leave it, and switching
workspaces clears it.

While at least one issue is selected, a bar at the bottom shows how many and:

- **Status ▾**, **Priority ▾**, **Assignee ▾**: the New issue modal's lists
  (`↑`/`↓`, `Enter`, `Esc`); the pick is written to every selected issue.
- **Cancel issues**: click twice (**Cancel N?**); cancels every selected issue
  and clears the selection.
- **▷ Start** (2 or more selected): opens one new omp chat on all of them, in
  the board's order, up to 10 issues. Its first message lists each issue's
  fields and description and asks for one plan covering all of them. The
  selection stays.

One undo (the undo bar or `Ctrl+Z`) reverts the whole bulk edit. The selection
stays after a Status, Priority or Assignee change, as in Linear.

## Commands

| Command | What it does |
| --- | --- |
| `Linear: open board` | Opens the board pane; if one is already open, re-keys it and syncs it now. |
| `Linear: sync now` | Syncs the open board immediately. |
| `Linear: add workspace` | Pastes an API key and picks the team; adds the workspace or replaces its key and team. |
| `Linear: switch workspace` | Picks the workspace the board shows. |
| `Linear: poll interval` | Seconds between syncs (at least 30). |
| `Linear: status` | Last sync result, issue count and error. |
| `Linear: self-test` | Development check of the board model. |

## Install

```
tern plugin install C:\path\to\tern-linear-plugin
```

For development, link the working copy instead. A linked plugin reloads when the
daemon saves changes:

```
tern plugin link C:\path\to\tern-linear-plugin
```

## Polling

- Polling runs only while the board pane exists.
- The interval defaults to 60 s; the minimum is 30 s.
- Network failures, `429` and `5xx` back off exponentially up to 600 s.
- `Linear: sync now` forces one fetch.

## Scope

Every open Issue of the Setup's team, plus Issues completed in the last 14 days,
up to 1000. A team with more is refused rather than truncated. Mine filters on the
board and makes no extra request.
