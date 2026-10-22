--!strict
-- The issue view: a board issue opened in place, as Linear's list opens one. The title and
-- description edit in place, properties use the create modal's chips and lists, and comments
-- are read and posted. The host performs every write this module asks for.

local Field = require("./field")
local Create = require("./create")

local ui = tern.ui
local ROLE = "linear-todo."
local M = {}

-- Node paths: the left column holds the title, description and comment fields; the side
-- column's "props" holds the chips the property lists hang under.
local ROOT = "main.detail.left"
local ANCHOR = "main.detail.side.props"
local COMMENT = ROOT .. ".compose.comment"

export type Detail = {
	id: string,
	-- The title, description and property values as shown, plus the open property list.
	d: Create.Draft,
	comment: Field.Field,
	-- The caret is in the comment box.
	commenting: boolean,
	-- Linear.detail's answer: description, creator, createdAt, comments; nil until loaded.
	info: any?,
	error: string?,
	sending: boolean,
}

-- What the host should do after a key, click or event: "close", "title" / "desc" (save that
-- field), "comment" (post it), "next" / "prev" (open the neighbouring issue), "web", "start",
-- "chat" (open the "Send to chat" list) or "undo".
export type Intent = string

local function el(tag: string, role: string, key: string, props: { [string]: any }?, children: { Node }?): Node
	local p: { [string]: any } = props or {}
	p.role = ROLE .. role
	p.key = key
	return ui.el(tag, p, children)
end

local function flag(on: boolean): string?
	return if on then "true" else nil
end

-- Properties --------------------------------------------------------------------

type Props = {
	stateId: string,
	priority: number,
	assigneeId: string?,
	labelIds: { string },
	estimate: number?,
	projectId: string?,
	cycleId: string?,
	dueDate: string?,
}

local function fromIssue(d: Create.Draft, issue: any, stateId: string)
	d.stateId = stateId
	d.priority = if type(issue.priority) == "number" then issue.priority else 0
	d.assigneeId = if type(issue.assignee) == "table" then issue.assignee.id else nil
	local labels: { string } = {}
	for _, l in (if type(issue.labels) == "table" and type(issue.labels.nodes) == "table" then issue.labels.nodes else {}) do
		table.insert(labels, l.id)
	end
	d.labelIds = labels
	d.estimate = if type(issue.estimate) == "number" then issue.estimate else nil
	d.projectId = if type(issue.project) == "table" then issue.project.id else nil
	d.cycleId = if type(issue.cycle) == "table" then issue.cycle.id else nil
	d.dueDate = if type(issue.dueDate) == "string" then issue.dueDate else nil
end

function M.snapshot(d: Create.Draft): Props
	return {
		stateId = d.stateId,
		priority = d.priority,
		assigneeId = d.assigneeId,
		labelIds = table.clone(d.labelIds),
		estimate = d.estimate,
		projectId = d.projectId,
		cycleId = d.cycleId,
		dueDate = d.dueDate,
	}
end

local function sameLabels(a: { string }, b: { string }): boolean
	local sa, sb = table.clone(a), table.clone(b)
	table.sort(sa)
	table.sort(sb)
	return table.concat(sa, ",") == table.concat(sb, ",")
end

local function orNull(v: any): any
	return if v == nil then tern.json.null else v
end

-- The issueUpdate input for what changed from `a` to `b` (State aside: the host moves the
-- issue for that), and the input that puts `a` back; nil when nothing else changed.
function M.changes(a: Props, b: Props): (any?, any?)
	local input: { [string]: any }, back: { [string]: any } = {}, {}
	local any = false
	for _, f in { "priority", "assigneeId", "estimate", "projectId", "cycleId", "dueDate" } do
		local x, y = (a :: any)[f], (b :: any)[f]
		if x ~= y then
			input[f], back[f], any = orNull(y), orNull(x), true
		end
	end
	if not sameLabels(a.labelIds, b.labelIds) then
		input.labelIds, back.labelIds, any = tern.json.array(b.labelIds), tern.json.array(a.labelIds), true
	end
	return if any then input else nil, if any then back else nil
end

-- Lifecycle -----------------------------------------------------------------------

function M.new(issue: any, stateId: string, title: string): Detail
	local d = Create.new(stateId, nil)
	d.root, d.anchor, d.focus = ROOT, ANCHOR, nil
	fromIssue(d, issue, stateId)
	Field.reset(d.title, title)
	return { id = issue.id, d = d, comment = Field.new("", true, 20000), commenting = false, sending = false }
end

-- Takes Linear's values into every field the caret is not in. `idle`: no write to this issue
-- is in flight, so the board issue is the truth for the property chips too.
function M.refresh(dt: Detail, issue: any, stateId: string, title: string, idle: boolean)
	local d = dt.d
	if idle and not d.pop then
		fromIssue(d, issue, stateId)
	end
	if d.focus ~= "title" and d.title.text ~= title then
		Field.reset(d.title, title)
	end
	local desc = if dt.info and type(dt.info.description) == "string" then dt.info.description else ""
	if dt.info and d.focus ~= "desc" and d.desc.text ~= desc then
		Field.reset(d.desc, desc)
	end
end

function M.focusComment(dt: Detail, cx: BlockCx)
	dt.d.focus, dt.d.pop, dt.commenting = nil, nil, true
	cx:frame({ { "focus", COMMENT .. "_" .. dt.comment.rev } })
end

local function blur(dt: Detail, cx: BlockCx)
	dt.d.focus, dt.commenting = nil, false
	cx:frame({ { "focus", tern.json.null } })
end

-- Input -----------------------------------------------------------------------------

-- A key in the issue view: an intent for the host, or whether the key was used.
function M.key(dt: Detail, k: Key, c: Create.Ctx, cx: BlockCx): Intent | boolean
	local d = dt.d
	local name = k.name
	local mod = k.ctrl or k.meta
	if d.pop then
		return Create.popKey(d, k, c, cx)
	end
	if dt.commenting then
		if mod and name == "enter" then
			return "comment"
		end
		local what = Field.edit_key(dt.comment, k, cx)
		if what == "blur" then
			blur(dt, cx)
		elseif what == nil then
			return false
		end
		return true
	end
	local focus = d.focus
	if focus then
		-- Tab steps on (title → description → comment); Enter in the title and Esc also save.
		if name == "tab" and not k.shift then
			if focus == "title" then
				Create.focus(d, "desc", cx)
			else
				M.focusComment(dt, cx)
			end
			return focus
		elseif focus == "desc" and mod and name == "enter" then
			blur(dt, cx)
			return "desc"
		end
		local what = Field.edit_key(if focus == "title" then d.title else d.desc, k, cx)
		if what == "submit" or what == "blur" then
			blur(dt, cx)
			return focus
		end
		return what ~= nil
	end
	-- ⌃Z/⌘Z outside the fields is the board's undo; unclaimed, Tern would undo inside the title.
	if mod and not k.alt and name == "z" then
		return "undo"
	end
	if mod or k.alt then
		return false
	end
	if name == "escape" then
		return "close"
	elseif name == "j" then
		return "next"
	elseif name == "k" then
		return "prev"
	elseif name == "enter" then
		Create.focus(d, "title", cx)
		return true
	end
	local kind = Create.shortcut(k, false)
	if kind then
		Create.openPop(d, kind :: Create.Kind, cx)
		return true
	end
	return false
end

-- Routes edit/undo/focus events to the view's fields. Returns whether the event was the
-- view's, and the field whose edit just ended (the host saves it).
function M.event(dt: Detail, ev: UiEvent): (boolean, Intent?)
	local d = dt.d
	if ev.id ~= nil and ev.id == dt.comment.id then
		if ev.ev == "edit" then
			Field.apply_edit(dt.comment, ev)
		elseif ev.ev == "undo" then
			Field.undo_step(dt.comment, false)
		elseif ev.ev == "focus" then
			local left = d.focus
			d.focus, d.pop, dt.commenting = nil, nil, true
			return true, left
		end
		return true
	end
	local left = d.focus
	local mine = Create.event(d, ev)
	if ev.ev == "focus" then
		dt.commenting = false
		if left and d.focus ~= left then
			return true, left
		end
		return true
	end
	return mine
end

-- A click in the view: an intent, or whether it was the view's.
function M.act(dt: Detail, name: string, value: string, c: Create.Ctx, cx: BlockCx): Intent | boolean
	if name == "dt-back" then
		return "close"
	elseif name == "dt-web" then
		return "web"
	elseif name == "dt-start" then
		return "start"
	elseif name == "dt-chat" then
		return "chat"
	elseif name == "dt-send" then
		return "comment"
	elseif name == "dt-desc" then
		dt.commenting = false
		Create.focus(dt.d, "desc", cx)
		return true
	elseif name == "dt-comment" then
		M.focusComment(dt, cx)
		return true
	elseif string.sub(name, 1, 3) == "cm-" then
		return Create.act(dt.d, name, value, c, cx) == true
	end
	return false
end

-- View --------------------------------------------------------------------------------

local function stamp(iso: any): string
	if type(iso) ~= "string" then
		return ""
	end
	-- shortcut: shows Linear's UTC timestamp as is; convert to local time if that confuses.
	return string.sub(iso, 1, 10) .. " " .. string.sub(iso, 12, 16) .. " UTC"
end

local function md(key: string, text: string): Node
	return el("div", "md", key, { class = "lt-md" }, { ui.md(text) })
end

-- The main region's children for the open issue; `armed`: the Cancel button awaits its second click.
function M.view(dt: Detail, issue: any, c: Create.Ctx, armed: boolean): { Node }
	local d = dt.d
	local out: { Node } = {
		el("div", "head", "head", { class = "lt-head" }, {
			el("button", "back", "back", { class = "lt-refresh", text = "←", aria = "Back to the board", title = "Back to the board (Esc)", actions = { click = "dt-back" } }),
			el("span", "ws", "team", { class = "lt-ws", text = c.teamKey }),
			el("span", "dt-crumb", "crumb", { class = "lt-dt-crumb", text = issue.identifier }),
			el("span", "spacer", "sp", { class = "lt-spacer" }),
			el("button", "start", "start", { class = "lt-start", text = "▷ Start", title = "Start working on this issue in a new omp chat", actions = { click = "dt-start" } }),
			el("button", "dt-chat", "chat", { class = "lt-tab", text = "Send to chat ▾", title = "Send this issue to an open chat", actions = { click = "dt-chat" } }),
			el("button", "dt-web", "web", { class = "lt-tab", text = "Open in Linear ↗", title = issue.url, actions = { click = "dt-web" } }),
			el("button", "act", "cancel", {
				class = "lt-tab lt-del",
				text = if armed then "Cancel issue?" else "Cancel issue",
				title = if armed then "Click again to cancel the issue" else "Moves the issue to Canceled",
				attrs = { ["data-confirm"] = flag(armed) },
				actions = { click = "cancel=" .. dt.id },
			}),
		}),
	}
	if dt.error then
		table.insert(out, el("div", "error", "error", { class = "lt-error", tone = "error", text = dt.error }))
	end

	local left: { Node } = {
		Field.node("input", { key = "title", role = ROLE .. "dt-title", placeholder = "Issue title" }, d.title, "", ROOT .. ".title"),
	}
	if d.focus == "desc" then
		table.insert(left, Field.node("editor", { key = "desc", role = ROLE .. "dt-desc", placeholder = "Add description…" }, d.desc, "", ROOT .. ".desc"))
	elseif not dt.info then
		table.insert(left, el("div", "dt-desc-view", "desc-view", { class = "lt-dt-desc lt-dt-muted", text = "Loading…" }))
	else
		local text = d.desc.text
		table.insert(left, el("div", "dt-desc-view", "desc-view", {
			class = "lt-dt-desc",
			title = "Edit the description",
			actions = { click = "dt-desc" },
		}, { if text ~= "" then md("md", text) else el("span", "dt-muted", "ph", { class = "lt-dt-muted", text = "Add description…" }) }))
	end

	table.insert(left, el("div", "dt-section", "activity", { class = "lt-dt-section", text = "Activity" }))
	local info = dt.info
	if info then
		local who = if type(info.creator) == "table" then info.creator.name else "Someone"
		table.insert(left, el("div", "dt-event", "created", { class = "lt-dt-event", text = who .. " created the issue · " .. stamp(info.createdAt) }))
		for _, cm in (if type(info.comments) == "table" then info.comments else {}) do
			local author = if type(cm.user) == "table" then cm.user.name elseif type(cm.botActor) == "table" and cm.botActor.name then cm.botActor.name else "Linear"
			table.insert(left, el("div", "dt-comment", "c-" .. cm.id, { class = "lt-dt-comment" }, {
				el("div", "dt-comment-head", "head", { class = "lt-dt-comment-head" }, {
					el("span", "dt-author", "who", { class = "lt-dt-author", text = author }),
					el("span", "dt-muted", "at", { class = "lt-dt-muted", text = stamp(cm.createdAt) }),
				}),
				md("body", cm.body or ""),
			}))
		end
	end
	-- The wrapper's click puts the caret in the box (a bare editor is not always focused by a click).
	table.insert(left, el("div", "dt-compose", "compose", { class = "lt-dt-compose", actions = { click = "dt-comment" } }, {
		Field.node("editor", { key = "comment", role = ROLE .. "dt-comment-input", placeholder = "Leave a comment…" }, dt.comment, "", COMMENT),
	}))
	table.insert(left, el("div", "dt-comment-foot", "send", { class = "lt-dt-comment-foot" }, {
		el("span", "dt-muted", "hint", { class = "lt-dt-muted", text = "Ctrl+Enter to send" }),
		el("span", "spacer", "sp", { class = "lt-spacer" }),
		el("button", "submit", "go", { class = "lt-submit", text = if dt.sending then "Sending…" else "Comment", actions = { click = "dt-send" } }),
	}))

	local chips: { Node } = {}
	for _, kind in Create.kinds(c) do
		table.insert(chips, Create.chip(d, kind :: Create.Kind, c))
	end
	local side: { Node } = {
		el("div", "dt-section", "h", { class = "lt-dt-section", text = "Properties" }),
		el("div", "dt-props", "props", { class = "lt-dt-props" }, chips),
	}

	table.insert(out, el("div", "detail", "detail", { class = "lt-detail" }, {
		el("div", "dt-left", "left", { class = "lt-dt-main" }, left),
		el("div", "dt-side", "side", { class = "lt-dt-side" }, side),
	}))
	return out
end

return M
