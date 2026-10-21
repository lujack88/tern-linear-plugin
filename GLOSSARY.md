# Linear Taskboard

A Tern pane that shows one Linear team's work and edits it in place.

## Language

**Issue**:
A Linear issue of the active Workspace's team: the unit of work shown on the Board.
_Avoid_: Task, card, ticket, todo

**State**:
One of the team's Linear workflow states (Backlog, Todo, In Progress, Done, …); each visible State is one column or group.
_Avoid_: Lane, status, column (for the State itself)

**Board**:
The pane showing the active Workspace's team: its visible States and their Issues.
_Avoid_: Taskboard (for the pane)

**View**:
How the Board is drawn: Kanban (a column per State) or List (a group of rows per State).
_Avoid_: Mode, layout, tab

**Workspace**:
A Linear workspace (organization) added to the plugin, with its API key and the one team its Board shows; one Workspace is active at a time.
_Avoid_: Setup, account, connection, organization (in the UI)
