# Linear Taskboard

A Tern host + window plugin that shows every Issue of one Linear team as a
Linear-style Board, as a Kanban, a List or a Tasks View, and writes every change straight
back to Linear. The host half renders the board block and talks to Linear; the
window half holds the commands, the keychain and the workspaces.

Open it with **Linear: open board**. The board lives in its own pane and stays in
step with Linear while that pane exists.

## What's new

**0.9.0** (2026-11-08, [#6](https://github.com/lujack88/tern-linear-plugin/pull/6)):

- [The Tasks View](#the-tasks-view): one list of open issues with the selected
  issue's card beside it, where you edit the issue and Start it with a model,
  thinking level and project folder.
- [Linked chats](#linked-chats): rows and cards show their chat's state
  (Working, Needs you, Ready for you, Stopped, Blocked), and **Open pane** jumps
  to it.
- [Auto-start](#auto-start), [CI watch](#ci-watch) and
  [Cleaning up worktrees](#cleaning-up-worktrees).
- **Labels ▾** in the selection bar for many issues at once.
- Plans are reviewed in Plannotator (`omp --plan`), bulk Start opens one chat
  per issue, and the ticket brief is shorter.

Earlier: **0.8.0** (Start several issues, Send to chat, nested sub-issues, an
issue view laid out like Linear's), **0.7.0** (Start in omp, AI description
rewrite, multi-select) and **0.4.0** (first release). Every change is in
[CHANGELOG.md](CHANGELOG.md).

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

The header holds the team key, the **Kanban | List | Tasks** tabs, the **Mine** toggle
(only issues assigned to you), the issue count, the last sync time and the last
error.

### Views

- **Kanban**: one column per State; the board scrolls sideways when the columns
  (at least 240 px each) do not fit.
- **List**: one group per State, headed by its name and count, with compact rows
  (priority, identifier, title, labels, estimate, assignee). `↑`/`↓` run on
  across groups. Sub-issues nest under their parent when both are in the same
  group, indented with connector lines as in Linear's List view; a parent shows
  a `done/total` sub-issue pill (Kanban cards show it too, and sub-issue cards a
  `↳ FIX-49` parent hint).
- **Tasks**: one list of the open issues with a card beside it that shows the
  selected issue and hands it to an omp chat (see [The Tasks View](#the-tasks-view)).

Each column (Kanban) or group (List) collapses with the `▾` before its name, and
expands with `▸`; collapsed ones keep their count, and the arrow keys skip them.

The View, the Mine toggle and the collapsed columns are remembered.

## Clicking an issue

- **Click** a row or card, or select it with the arrow keys and press `Enter`:
  the issue view opens. (In the Tasks View a click opens the card instead; see
  below.)
- **⋮** (at the right end of the row's or card's controls, shown on hover), or
  `m` on the keyboard-selected issue: its menu opens under it (below).
- While an issue is lifted for a move, a click drops it instead.

The checkbox, `⠿`, `✎`, `✕`, `⋮`, `▷` and `▾` keep their own actions.

### The issue menu

As in Linear's right-click menu (Tern blocks get no right-click, so `⋮` or `m`
opens it):

- **Status ▸**, **Priority ▸**, **Assignee ▸**: open the New issue modal's list in
  the menu, the current value checked, with a filter field and a **‹ Back** row.
- **Open issue** (`Enter`), **▷ Start in omp**, **Send to chat ▸**, **Open in
  Linear**, **Copy ID**, **Copy link**, **Rename** (`R`), and **Cancel issue**
  (click twice).

When the issue is one of several selected, the menu acts on the whole
selection: its title says how many, and it offers Status, Priority, Assignee,
**▷ Start in omp**, **Send to chat ▸**, **Copy IDs** and **Cancel N issues**.
Every change offers one undo.

**Send to chat ▸** lists Carly and every open agent chat in Tern, each with the
icon and title Tern's tab list shows (the tab's name, else the pane title, e.g.
`omp` for an untitled chat) over a muted line with its folder, model and state,
for example `fixit-app · sonnet · idle`; a working or waiting chat gets an
accent dot. Pick one to send it the issue
(or the selection, up to 10): a message that starts "Here is Linear issue
TES-4:" with the same fields, description and workflow as Start. A busy chat
queues it. The chat's pane is shown; Carly opens with
the message.

Keys while it is open: `↑`/`↓` (or `K`/`J`) move, `Enter` runs, `→`/`Enter` opens
a ▸ list, `←` (or `Backspace` in an empty filter) goes back, `Esc` closes. A click
outside closes it.

## The issue view

Click an issue (or select it with the arrow keys and press `Enter`) to
open it in place of the board, laid out like Linear's issue page: a centered
640 px column and a 280 px sidebar.

- **Top bar**: the breadcrumb `TES › Issues › TES-4 title` (click `TES` or
  `Issues`, or press `Esc`, to go back), **⋯** (the issue menu: ▷ Start in omp,
  Send to chat ▸, Open in Linear, Copy ID, Copy link, Cancel issue (click twice)),
  and on the right the issue's place in the board's order (`5 / 11`) with **↓** / **↑**
  (also `J` / `K`).
- **Below it**: copy the issue URL, copy the ID, copy the git branch name, and the
  **▷ Start | ▾** split button (▾: New chat or Send to a session).
- **Title**: edit it in place. It saves on `Enter`, `Tab`, `Esc` or a click elsewhere.
- **Description**: shown as Markdown. Click it to edit, and it saves when you leave
  it (`Esc`, `Ctrl+Enter`, `Tab` or a click elsewhere). Issue mentions show as
  links, not Linear's inline chips (Tern's Markdown view takes text only).
- **Sub-issues**: `▾ Sub-issues` folds the list; the ring counts done ones. Each
  row shows its status, title, labels and assignee; click it to open it (in Linear
  when it is not on the board). **+** opens the New issue modal for a sub-issue.
- **Activity**: who created the issue, State changes, added or removed relations,
  and comments, oldest first, with relative times (`2h ago`; hover for UTC).
  Write a comment in the card at the bottom and send it with **↑** or `Ctrl+Enter`.
- **Sidebar**: Properties (Status, Priority, Assignee, Estimate, Due date), Labels,
  Project (and Cycle), each a row that opens the New issue modal's list with the
  same shortcuts and writes to Linear at once; then Related issues (click to open).

Every edit offers the usual one-step undo. Comments can be read and added here,
not edited or deleted.

## The Tasks View

The **Tasks** tab shows one list of issues on the left and the selected issue's
card beside it. On a narrow pane the card wraps below the list.

### The list

- **Heading**: "Issues" and "N open", counting issues in started and unstarted
  States (Mine applies).
- **Add an issue**: type a title and press `Enter` to create it in the team's
  first unstarted State (assigned to you when Mine is on). It goes through the
  same path as the New issue modal (pending row, errors, undo), and the new
  issue opens in the card. `Esc` clears the field; `a` focuses it.
- **Order**: issues in started States first, then unstarted, each in the board's
  sort (priority, then most recently updated, then identifier).
- **Backlog (N)** and **Done (N)** (completed in the last 14 days) follow as
  groups, folded at start. Click a group's header to open or fold it (not
  remembered). Canceled issues are not shown.

### Rows

A row shows the State glyph, the title, a meta line, pills and the age of the
last update (`now`, `8m`, `3h`, `2d`, `5w`, `4mo`, `1y`; hover for the full date).

- **Meta line**: the linked chat's state (see below) when the issue has one,
  else the State name.
- **Pills**: the priority (Urgent, High, Medium, Low, coloured), up to 2 labels
  with their colour dot, `pane` when a chat is linked, and the identifier.
- **Glyph**: click it to focus the linked chat; with no linked chat it marks the
  issue done (or reopens it).

On hover the age gives way to actions:

| Action | What it does |
| --- | --- |
| ✓ Mark as done | moves the issue to Done; on a done issue it is **↺ Reopen** (back to the first unstarted State) |
| ↓ Move to the Backlog | moves it to the Backlog; on a Backlog issue it is **↑** (back to the first unstarted State). An error shows when the team has no Backlog State |
| ✕ Cancel | click twice (**Cancel?**) |
| ⠿ | picks the issue up; then click an issue in the target State |
| ⋯ | the issue menu |

Every move or cancel offers the usual one-step undo.

### Keys

| Action | Key |
| --- | --- |
| Select a row and open its card | click it |
| Open the issue view | double-click, or `Enter`; leaving it (`Esc` or back) returns here with the card open |
| Next / previous issue (the card follows) | `↓`/`↑` or `j`/`k`, in the Tasks order: open rows, then the rows of opened groups |
| Close the card | `Esc` |
| Edit the card's title | `r` / `F2` |
| Focus Add an issue | `a` |

The other board keys (`x`, `m`, `c`, `Alt+C`, `Space`, `Delete` twice,
`Ctrl+Z` / `Cmd+Z`) work as in the List View.

### The card

- **Top**: the identifier, **⋯** (the issue menu), **↑** / **↓** (previous or next
  issue in the Tasks order) and **×** (close).
- **Title**: wraps; edit it in place. It saves on `Enter`, `Tab`, `Esc` or a click
  elsewhere.
- An agent badge when a chat is linked, then "Updated 4m ago · Thu 05 Nov 2026,
  13:41".
- **Description**: Markdown, edited in place; it saves on `Tab`, `Esc` or a click
  elsewhere, and scrolls within the card when long.
- **Status**, **Priority**, **Assignee**, **Labels** chips: the same lists as the
  New issue modal, with `S`, `P`, `A`, `L` while the card has the keys.
- **Hand it to an agent**:
  - **Model ▾**: omp's models (from `omp models --json`, loaded once per board).
  - **Thinking**: each click cycles Default → off → auto → the model's levels →
    Default.
  - **Project ▾**: recent folders, the board's folder, or type a full path and
    pick **Use <path>**.
  - **Send to chat ▸**: the **Send to chat ▸** list.
- **Buttons**: **Open issue** (the issue view), **Start** (or **Open pane** when a
  chat is linked), and **Mark as done** (or **Reopen**).

Edits offer the usual one-step undo. The card stays open when its issue moves to
Done or the Backlog; it closes when the issue leaves the board (canceled, synced
away or hidden by Mine).

### Linked chats

Each Start and each **Send to chat ▸** links the issue to the chat it opened or
used (a message sent to Carly is not linked). While a board is open, the row and
the card show the chat's state, updated every second:

- **Working · 8m**: the chat is busy (the glyph spins).
- **Needs you**: it waits for your input.
- **Ready for you**: its turn ended.
- **Stopped**: the chat exited.
- **Blocked · <reason>**: the Board stopped automatic work on the issue and
  needs you (see [CI watch](#ci-watch)).

**Open pane** on the card, or a click on the row's glyph, focuses the chat; if it
is closed a toast says "That chat is closed". When the chat's pane is gone the
link is dropped and the row shows its State again. Closing a chat never changes
the issue's State.

## Moving an issue

- Mouse: click the grip `⠿`, then click the destination column or group.
- Keyboard: `Space` to pick up, `←`/`→` to change State, `Enter` to drop.
- `Shift+←` / `Shift+→` moves the focused issue to the previous or next State.

The same keys work in the Kanban and List Views. While an issue is lifted, the States it can be
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
| Start in omp | click **▷ Start** on a row or in the issue view; on a card, click the **▷** at its bottom-right, then **▷ New chat** |
| Start or send to a session | click a row's **▾** (the right part of its **▷ Start** split button) or a card's **▷**: **▷ New chat**, or **Send to a session ▸** (the **Send to chat ▸** list) |

Start opens a new omp chat in plan mode. Its first message is the issue:
identifier, title, URL, State, priority, assignee, labels and description
(fields the issue leaves unset are left out), then the workflow:

- **Before you start**: omp fetches the issue from Linear (comments,
  attachments, sub-issues, parent, blockers, branch name), since the
  description may be empty or stale. If the issue is Done, Canceled or blocked
  by an open issue, omp stops and asks you. The scope is the issue plus
  anything omp judges related; it names every extra issue in the plan, and you
  approve the scope with the plan.
- **Hard stops**: omp asks you and waits at four points, and nowhere else:
  plan approval; the look check, when the plan has one; before a merge that
  changes migrations, auth, payments, RLS or security-definer SQL, touches more
  than 15 files or 500 lines, could not be run in QA, or a reviewer says needs
  human QA (omp tells you why); and whenever the work becomes much larger or
  riskier than planned.

Then four steps:

1. **Plan**: omp thinks it through, reads the relevant code and loads
   skill://domain-modeling. It asks you at most 5 questions, only on product
   scope, hard-to-reverse choices or where no safe default exists, and lists
   its other decisions as defaults in the plan. It decides whether a look
   check (up to 3 visual
   variants) is needed, and writes the plan to `.plans/<ID>.md` with
   skill://show-me's diagrams inside. It submits the plan to Plannotator, whose
   review opens in a Tern browser block beside the chat: approve it, or
   annotate it and send it back. Nothing is implemented until you approve; then
   it writes the domain-modeling docs.
2. **Build**: omp moves the issue(s) to In Progress, comments the plan, and
   works in its own git worktree from fresh `origin/main` on Linear's branch
   name. Implementation goes to task subagents (parallel for independent
   slices), each result verified. The chat runs with `task.prewalk` on, so
   each generic task subagent plans on your `task` model role and hands off
   to your `smol` role at its first edit (skipped when both are the same
   model). omp opens a PR titled `ID: title` with Summary, `Fixes ID` and
   Testing; with a look check it opens a draft, shows you the Vercel preview
   variants and iterates on your preview comments.
3. **Ship**: omp comments the PR link and moves the issue(s) to In Review.
   Reviews are sized by risk and see only the diff and the plan: one
   reviewer for a small diff (5 files, 200 lines or fewer), two otherwise, plus
   a security reviewer when auth, data access, RLS or SQL changed (generic
   reviewers run on Sonnet 5.5, the security reviewer on Opus 5.5, set in
   `plan-mode.yml`); one round. omp turns the acceptance criteria into a QA
   checklist and hands it to a `sonic` subagent, which returns only a
   pass/fail table (re-run for failed rows after fixes) that goes in the PR.
   omp merges once PR checks pass, unless a hard stop applies. After the merge
   it hands the issue(s) to the QA owner named in AGENTS.md, if any, with a
   checklist of only what CI and the QA table can't prove, and removes the
   worktree.
4. **Handover**: omp reports what changed, the PR link, the QA table and any
   reviewer findings it did not fix, then runs
   skill://visual-pr on the PR so its output is the final message.

The skills must be installed where omp finds them. Linear updates need a
Linear tool (e.g. the Linear MCP) in that chat. The chat opens in its own tab
and runs in the board pane's directory, else your home.

**Start** on the Tasks View's card starts the same chat, plus the picked
model (`--model`) and thinking level (`--thinking`), in the picked folder (else
the board pane's directory, else your home). A picked folder goes to the front
of the recent folders (up to 8). Every other Start (a row, the menu, the bulk
bar) uses no picks.

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
selected; selected issues are tinted. `⋮` (or `m`) on a selected row or card
opens the issue menu for the whole selection. The selection is not saved;
issues that are canceled, synced away, or hidden by Mine leave it, and switching
workspaces clears it.

While at least one issue is selected, a bar at the bottom shows how many and:

- **Status ▾**, **Priority ▾**, **Assignee ▾**: the New issue modal's lists
  (`↑`/`↓`, `Enter`, `Esc`); the pick is written to every selected issue.
- **Labels ▾**: the New issue modal's Labels list, with the labels every
  selected issue has already ticked. Tick or untick as many as you like; when the
  list closes (`Esc` or a click outside), each label you ticked is added to every
  selected issue and each one you unticked is removed from all of them. A label
  only some of them have stays as it is unless you tick it. Adding a label from a
  label group replaces the issue's other label of that group. An issue with more
  than 50 labels is left alone, with a toast.
- **Cancel issues**: click twice (**Cancel N?**); cancels every selected issue
  and clears the selection.
- **▷ Start** (2 or more selected): opens a separate new omp chat for each of
  them, each in its own tab, in the board's order, up to 10 issues. Each chat
  starts exactly as a single **▷ Start** on that issue would. To hand several
  issues to one chat, use **Send to chat ▸**. The selection stays.

One undo (the undo bar or `Ctrl+Z`) reverts the whole bulk edit. The selection
stays after a Status, Priority or Assignee change, as in Linear.

## Auto-start

The Board can start a chat for an issue without a click. An issue qualifies
when it has the label `agent` (any case), sits in an unstarted State such as
Todo, and is assigned to you. Auto-start is off by default.

The header chip shows it: `Auto · off`, `Auto · 1/2` (chats busy / slots), or
`Auto · budget` (hover shows why). A click on the chip turns it on or off, as
does **Linear: auto-start on/off**. Slots run from 1 to 3, default 2; set them
with **Linear: auto-start slots**. Every linked chat that has not exited counts
against the slots. Each issue auto-starts at most once; **▷ Start** still works.

The budget gate reads `omp usage`, at most every 5 minutes. No new chat starts
while Claude's 5-hour or 7-day window is at 80% or more, or when usage can't be
read.

Auto-start runs only while a Board is open, after each sync. The chat starts
exactly as **▷ Start** does: its own tab, plan mode, so it stops at plan
approval and at the hard stops. It runs in the project folder: the most recent
Start folder, else a linked chat's folder, else the board's folder.

## CI watch

For a linked issue whose chat is **Ready for you** or **Stopped**, the Board
reads its PR (`gh pr view` on the issue's Linear branch) at most every 2
minutes. While the chat is **Working** or **Needs you** it stays out.

- Pending checks: it waits.
- Failing checks, chat **Ready for you**: it sends that chat the failing check
  names and the `gh run view <id> --log-failed` command, without switching to
  it. Once per failing commit, at most 2 rounds per issue; then the issue shows
  **Blocked · CI red after 2 rounds**.
- Failing checks, chat closed: **Blocked · chat closed with red CI**.
- Passing checks, or the PR merged or closed, clear it. A manual Start clears it
  too.

The Board never restarts a chat.

## Cleaning up worktrees

**Linear: clean up worktrees**, or **Clean up worktrees…** in the workspace
menu, opens the clean-up in place of the board. It finds the repository from
the most recent Start folder, else a linked chat's folder, else the board's
folder, and lists every worktree as **Will remove** or **Keeping**, with the
reason.

It removes only worktrees whose PR is merged or closed, with no uncommitted
changes, no commits missing from GitHub, and no chat still working in it. It
never removes the main checkout, or locked or detached worktrees.

**Remove N** needs two clicks. It runs `git worktree remove` without `--force`,
then `git branch -d`, which keeps an unmerged branch. A worktree git refuses (on
Windows, often a dev server still holding its files) stays listed with git's
reason. `↻` or `r` checks again; `Esc` goes back. It never runs on its own.

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
| `Linear: auto-start on/off` | Turns auto-start on or off. |
| `Linear: auto-start slots` | How many chats auto-start may keep busy (1–3, default 2). |
| `Linear: clean up worktrees` | Opens the worktree clean-up in place of the board. |

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
