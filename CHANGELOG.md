# Changelog

Notable changes to the Linear Taskboard (`linear-todo`) Tern plugin, newest first.

## 0.9.1 — 2026-11-13 (#8)

### Fixed

- A board whose API key is no longer in the keychain says so and how to add it
  again; it used to show "Connecting…" forever.
- The workspace menu (with **Add workspace…**) opens on a board that has no
  key or no workspace yet; it used to open only once issues had loaded.

## 0.9.0 — 2026-11-08 (#6)

### Added

- **Tasks View**: a third tab beside Kanban and List. One list of open issues
  (started first, then unstarted), with Backlog and Done (last 14 days) folded
  below, and the selected issue's card beside it. Add an issue inline (`a`,
  then `Enter`); hover a row to mark it done or reopen it, send it to the
  Backlog, cancel it, move it or open its menu; `j`/`k` step through issues.
- **Issue card**: edit the title and Markdown description in place, change
  Status, Priority, Assignee and Labels (`S`, `P`, `A`, `L`), and hand the
  issue to an agent with **Model**, **Thinking** and **Project** picks. Models
  come from `omp models --json`; picked folders are remembered (up to 8).
- **Linked chats**: Start and Send to chat link the issue to its chat. Rows and
  the card show the chat's state every second (**Working · 8m**, **Needs you**,
  **Ready for you**, **Stopped**, **Blocked**), and **Open pane** focuses it.
- **Auto-start** (off by default): starts a plan-mode chat for issues labelled
  `agent`, in an unstarted State and assigned to you. It keeps 1–3 chats busy
  (default 2) and starts nothing while Claude usage is at 80% or more. Toggle
  it with the header chip or **Linear: auto-start on/off**; set slots with
  **Linear: auto-start slots**.
- **CI watch**: when a linked chat's PR has failing checks, the Board sends
  that chat the failing check names and the `gh run view <id> --log-failed`
  command, at most 2 rounds per issue; after that, or if the chat is closed,
  the issue shows **Blocked**.
- **Clean up worktrees** (**Linear: clean up worktrees**): lists every worktree
  as **Will remove** or **Keeping** with the reason, and removes only those
  whose PR is merged or closed, with nothing uncommitted or unpushed and no
  chat in them. Never uses `--force`; removing takes two clicks.
- **Labels ▾** in the selection bar adds or removes labels on many issues at
  once.
- Issues load their Linear `branchName`, used to find their PR.

### Changed

- Plans are reviewed in **Plannotator**: board chats start with `omp --plan`,
  write the plan to `.plans/<ID>.md` and open the review in a Tern browser
  block beside the chat. omp's own plan mode stays off in `plan-mode.yml`.
- **Bulk Start** opens one omp chat per issue, each in its own tab (it used to
  open one chat for all of them).
- The ticket brief is about 30% shorter and has hard stops. Planning asks at
  most 5 questions (product scope, hard-to-reverse choices, missing safe
  defaults) through skill://domain-modeling instead of grill-with-docs. Work
  happens in a fresh worktree from `origin/main` through task subagents;
  review is sized by risk (one round, security review only for auth, data,
  RLS or SQL); QA goes to a subagent that returns a PASS/FAIL table.
- `plan-mode.yml` turns on `task.prewalk` and runs the reviewer on Sonnet 5.5
  and the security reviewer on Opus 5.5 for board-started chats.
- Reload open boards after updating: a board loaded before 0.9.0 can't start
  chats in the new window half.

## 0.8.0 — 2026-10-22

### Added

- **▷ Start on several issues** at once, and **Send to chat** to hand issues to
  an open Tern chat or Carly as context (#3).
- The **⋮** issue menu and a split **▷ Start | ▾** (New chat / Send to a
  session) on rows and cards (#3).
- Sub-issues nest under their parent in the List View, with a `done/total`
  progress pill; Kanban cards show `↳` parent hints (#3).
- The issue view is laid out like Linear's issue page: breadcrumb,
  sub-issues, activity with comments, a properties sidebar and copy buttons
  for the link, ID and git branch (#4).

### Changed

- Shorter Start and Send to chat messages that leave unset fields out, and a
  workflow brief that keeps the Linear issue updated, runs a quick QA,
  auto-merges by default and hands over with a visual PR summary (#5).

## 0.7.0 — 2026-10-22

### Added

- **▷ Start** an issue in a new omp chat in plan mode (#2).
- **✨ Rewrite** a new issue's description with the default model (#2).
- A **+ New issue** button in the header, multi-select with a bulk bar, a
  click menu and collapsible columns (#2).

### Fixed

- Accent colours in the board pane, refocusing the title after the
  description, scrolling long descriptions in the create modal, and the
  template list's position (#2).

## 0.4.0 — 2026-10-21

### Added

- First release: one Linear team as a Kanban or List board with a Mine
  toggle, moves, renames and cancels with one-step undo, and a Linear-style
  create modal with templates (#1).
