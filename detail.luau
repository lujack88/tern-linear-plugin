--!strict
-- The issue view: a board issue opened in place, as Linear's list opens one. The title and
-- description edit in place, properties use the create modal's chips and lists, and comments
-- are read and posted. The host performs every write this module asks for.

local Field = require("./field")
local Create = require("./create")
local Model = require("./model")

local ui = tern.ui
local ROLE = "linear-todo."
local M = {}

-- Node paths: the left column holds the title, description and comment fields; the side
-- column's "props" holds the chips the property lists hang under.
local ROOT = "main.detail.left"
local ANCHOR = "main.detail.side.props"
local COMMENT = ROOT .. ".compose.comment"
-- The Tasks View's card: its title/description fields, "props" chips and "agent" pills.
local CARD = "main.tasks.card"

export type Detail = {
	id: string,
	-- The title, description and property values as shown, plus the open property list.
	d: Create.Draft,
	comment: Field.Field,
	-- The caret is in the comment box.
	commenting: boolean,
	-- Linear.detail's answer: description, creator, createdAt, branchName, comments, children,
	-- history, related; nil until loaded.
	info: any?,
	error: string?,
	sending: boolean,
	-- The Sub-issues section is expanded.
	subsOpen: boolean,
	-- What the last "copy" or "open" intent names: "link" / "id" / "branch", or an issue id.
	target: string?,
	-- Shown as the Tasks View's card; `live`: its last render had a linked chat alive.
	card: boolean?,
	live: boolean?,
}

-- What the host should do after a key, click or event: "close", "title" / "desc" (save that
-- field), "comment" (post it), "next" / "prev" (open the neighbouring issue), "start", "split"
-- (the Start dropdown), "more" (the issue menu), "copy" / "open" (of `target`), "subissue"
-- (the New issue modal for a sub-issue) or "undo"; from the card also "pane" (focus the linked
-- chat), "done" (complete or reopen), "full" (the full issue view) and "chats" (Send to chat).
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

function M.new(issue: any, stateId: string, title: string, card: boolean?): Detail
	local d = Create.new(stateId, nil)
	d.root, d.anchor, d.focus = if card then CARD else ROOT, if card then CARD .. ".props" else ANCHOR, nil
	fromIssue(d, issue, stateId)
	Field.reset(d.title, title)
	return { id = issue.id, d = d, comment = Field.new("", true, 20000), commenting = false, sending = false, subsOpen = true, card = card }
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
		-- Tab steps on (title → description → comment; the card cycles title ↔ description); Enter
		-- in the title and Esc also save.
		if dt.card and name == "tab" then
			-- The card's description takes no caret before it has loaded.
			if focus == "title" and not dt.info then
				blur(dt, cx)
			else
				Create.focus(d, if focus == "title" then "desc" else "title", cx)
			end
			return focus
		elseif name == "tab" and not k.shift then
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
	elseif name == "enter" and not dt.card then
		Create.focus(d, "title", cx)
		return true
	end
	local kind = Create.shortcut(k, false)
	-- The card shows only these chips; another list would have nothing to hang under.
	if kind and (not dt.card or kind == "status" or kind == "priority" or kind == "assignee" or kind == "labels") then
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

-- Clicks that only hand an intent to the host.
local INTENTS: { [string]: Intent } = {
	["dt-back"] = "close",
	["dt-start"] = "start",
	["dt-split"] = "split",
	["dt-more"] = "more",
	["dt-send"] = "comment",
	["dt-next"] = "next",
	["dt-prev"] = "prev",
	["dt-sub"] = "subissue",
	["dt-close"] = "close",
	["dt-up"] = "prev",
	["dt-down"] = "next",
	["dt-done"] = "done",
	["dt-full"] = "full",
	["dt-chats"] = "chats",
}

-- The card's chosen model in `c.models`, if listed.
local function chosenModel(d: Create.Draft, c: Create.Ctx): any
	local models: { any } = c.models or {}
	for _, m in models do
		if m.id == d.model then
			return m
		end
	end
	return nil
end

-- A click in the view: an intent, or whether it was the view's.
function M.act(dt: Detail, name: string, value: string, c: Create.Ctx, cx: BlockCx): Intent | boolean
	local intent = INTENTS[name]
	if intent then
		return intent
	elseif name == "dt-copy" or name == "dt-open" then
		dt.target = value
		return if name == "dt-copy" then "copy" else "open"
	elseif name == "dt-primary" then
		return if dt.live then "pane" else "start"
	elseif name == "dt-think" then
		local m = chosenModel(dt.d, c)
		dt.d.thinking = Model.nextThinking(dt.d.thinking, if m then m.thinking else nil)
		return true
	elseif name == "dt-subs" then
		dt.subsOpen = not dt.subsOpen
		return true
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

-- The Linear URL of a sub-issue or related issue the view shows, for one not on the board.
function M.urlOf(dt: Detail, id: string): string?
	local info = dt.info
	if not info then
		return nil
	end
	for _, k in info.children do
		if k.id == id and type(k.url) == "string" then
			return k.url
		end
	end
	for _, r in info.related do
		if r.issue.id == id and type(r.issue.url) == "string" then
			return r.issue.url
		end
	end
	return nil
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

-- A Tern icon by name.
local function icon(name: string): Node
	return { k = "icon", p = { name = name, key = "icon" } } :: any
end

-- A small borderless icon button; `open`: its menu is showing.
local function iconBtn(key: string, name: string, label: string, action: string, open: boolean?): Node
	return el("button", "dt-icon", key, {
		class = "lt-dt-icon",
		aria = label,
		title = label,
		attrs = { ["data-open"] = flag(open == true) },
		actions = { click = action },
	}, { icon(name) })
end

local function str(v: any): string?
	return if type(v) == "string" then v else nil
end

local function stateIcon(s: any, key: string): Node
	return el("span", "state", key, { class = "lt-state", attrs = { ["data-type"] = if type(s) == "table" then str(s.type) else nil }, title = if type(s) == "table" then str(s.name) else nil })
end

local function avatar(name: string?, key: string): Node
	return el("span", "avatar", key, { class = "lt-avatar", text = Model.initials(name), title = name })
end

-- A sub-issue row: status, title, labels and assignee; a click opens it.
local function subRow(k: any): Node
	local kids: { Node } = {
		stateIcon(k.state, "state"),
		el("span", "dt-row-title", "title", { class = "lt-dt-row-title", text = str(k.title) or "" }),
		el("span", "spacer", "sp", { class = "lt-spacer" }),
	}
	local labels = if type(k.labels) == "table" and type(k.labels.nodes) == "table" then k.labels.nodes else {}
	for i, l in labels do
		if type(l) == "table" and str(l.name) then
			table.insert(kids, el("span", "label", "l" .. i, { class = "lt-label", attrs = { ["data-c"] = Model.labelClass(str(l.color)) } }, {
				el("span", "dot", "dot", { class = "lt-dot" }),
				el("span", "label-name", "name", { class = "lt-label-name", text = l.name }),
			}))
		end
	end
	if type(k.assignee) == "table" then
		table.insert(kids, avatar(str(k.assignee.name), "avatar"))
	end
	return el("div", "dt-row", "s-" .. k.id, { class = "lt-dt-row", title = str(k.identifier), actions = { click = "dt-open=" .. k.id } }, kids)
end

-- "▾ Sub-issues", its progress ring and "+", then the sub-issue rows while expanded.
local function subIssues(dt: Detail, kids: { any }): Node
	local done, total = Model.progress({ children = { nodes = kids } })
	local head: { Node } = {
		el("button", "dt-subs-toggle", "toggle", {
			class = "lt-dt-subs-toggle",
			text = (if dt.subsOpen then "▾  " else "▸  ") .. "Sub-issues",
			attrs = { ["aria-expanded"] = if dt.subsOpen then "true" else "false" },
			actions = { click = "dt-subs" },
		}),
	}
	if total > 0 then
		table.insert(head, el("span", "progress", "progress", {
			class = "lt-progress lt-dt-progress",
			title = done .. " of " .. total .. " sub-issues done",
			attrs = { ["data-p"] = if done == total then "done" elseif done > 0 then "part" else nil },
		}, {
			el("span", "ring", "ring", { class = "lt-ring" }),
			el("span", "progress-n", "n", { class = "lt-progress-n", text = done .. "/" .. total }),
		}))
	end
	table.insert(head, el("span", "spacer", "sp", { class = "lt-spacer" }))
	table.insert(head, iconBtn("add", "plus", "Add sub-issue", "dt-sub"))
	local out: { Node } = { el("div", "dt-subs-head", "head", { class = "lt-dt-subs-head" }, head) }
	if dt.subsOpen then
		for _, k in kids do
			table.insert(out, subRow(k))
		end
	end
	return el("div", "dt-subs", "subs", { class = "lt-dt-subs" }, out)
end

-- The activity: one compact line per event (an avatar, State or link icon, then "who did what ·
-- 2h ago", the UTC time on hover), comments as cards in between.
local function timeline(info: any): { Node }
	local now = os.time()
	local out: { Node } = {}
	for i, e in Model.timeline(info) do
		local ago = Model.ago(e.at, now)
		if e.kind == "comment" then
			local cm = e.comment
			table.insert(out, el("div", "dt-comment", "e" .. i, { class = "lt-dt-comment" }, {
				el("div", "dt-comment-head", "head", { class = "lt-dt-comment-head" }, {
					avatar(e.who, "avatar"),
					el("span", "dt-author", "who", { class = "lt-dt-author", text = e.who }),
					el("span", "dt-muted", "at", { class = "lt-dt-muted", text = ago, title = stamp(e.at) }),
				}),
				md("body", str(cm.body) or ""),
			}))
			continue
		end
		local lead = if e.kind == "state" then stateIcon({ type = e.stateType }, "lead")
			elseif e.kind == "relation" then el("span", "dt-event-icon", "lead", { class = "lt-dt-event-icon" }, { icon("link") })
			else avatar(e.who, "lead")
		local what = e.text
		if e.ident then
			what ..= " " .. e.ident .. (if e.title then " " .. e.title else "")
		end
		table.insert(out, el("div", "dt-event", "e" .. i, { class = "lt-dt-event", title = stamp(e.at) }, {
			lead,
			el("span", "dt-event-text", "text", { class = "lt-dt-event-text", text = e.who .. " " .. what }),
			el("span", "dt-event-at", "at", { class = "lt-dt-event-at", text = "· " .. ago }),
		}))
	end
	return out
end

local RELATION_LABEL: { [string]: { string } } = {
	blocks = { "Blocks", "Blocked by" },
	duplicate = { "Duplicate of", "Duplicated by" },
	similar = { "Similar", "Similar" },
}

-- The sidebar's related issues: status, ID and title; a click opens it.
local function relatedRows(related: { any }): { Node }
	local out: { Node } = {}
	for i, r in related do
		local o = r.issue
		local kids: { Node } = {
			stateIcon(o.state, "state"),
			el("span", "dt-side-id", "id", { class = "lt-dt-side-id", text = str(o.identifier) or "" }),
			el("span", "dt-row-title", "title", { class = "lt-dt-row-title", text = str(o.title) or "" }),
		}
		local label = RELATION_LABEL[str(r.type) or ""]
		if label then
			table.insert(kids, el("span", "dt-muted", "type", { class = "lt-dt-muted", text = label[if r.inverse then 2 else 1] }))
		end
		table.insert(out, el("div", "dt-side-row", "r" .. i, {
			class = "lt-dt-side-row",
			title = (str(o.identifier) or "") .. " " .. (str(o.title) or ""),
			actions = { click = "dt-open=" .. tostring(o.id) },
		}, kids))
	end
	return out
end

local function heading(key: string, text: string): Node
	return el("div", "dt-heading", key, { class = "lt-dt-heading", text = text })
end

-- The title and description editors, shared by the full view and the card; `f` nil shows
-- the description idle (not editable). `class` set: the card's title, an editor so a long title
-- wraps; its Field stays single-line, so Enter saves and pasted or typed line breaks become spaces.
local function titleField(d: Create.Draft, class: string?): Node
	return Field.node(if class then "editor" else "input", { key = "title", role = ROLE .. "dt-title", class = class, placeholder = "Issue title" }, d.title, "", d.root .. ".title")
end

local function descField(d: Create.Draft, f: Field.Field?, class: string?, placeholder: string?): Node
	return Field.node("editor", { key = "desc", role = ROLE .. "dt-desc", class = class, placeholder = placeholder or "Add description…" }, f, "", d.root .. ".desc")
end

-- The main region's children for the open issue: `pos` of `total` is its place in the board's
-- order (0 when it is not shown there); `open` the header menu showing, "more" or "split".
function M.view(dt: Detail, issue: any, c: Create.Ctx, pos: number, total: number, open: string?): { Node }
	local d = dt.d
	local info = dt.info
	local head: { Node } = {
		el("button", "dt-crumb-btn", "team", { class = "lt-dt-crumb-btn", text = c.teamKey, title = "Back to the board (Esc)", actions = { click = "dt-back" } }),
		el("span", "dt-sep", "s1", { class = "lt-dt-sep", text = "›" }),
		el("button", "dt-crumb-btn", "issues", { class = "lt-dt-crumb-btn", text = "Issues", title = "Back to the board (Esc)", actions = { click = "dt-back" } }),
		el("span", "dt-sep", "s2", { class = "lt-dt-sep", text = "›" }),
		el("span", "dt-crumb", "crumb", { class = "lt-dt-crumb", text = issue.identifier .. "  " .. d.title.text, title = d.title.text }),
		iconBtn("more", "more", "More actions", "dt-more", open == "more"),
		el("span", "spacer", "sp", { class = "lt-spacer" }),
	}
	if pos > 0 then
		table.insert(head, el("span", "dt-pos", "pos", { class = "lt-dt-pos", text = pos .. " / " .. total }))
	end
	table.insert(head, iconBtn("next", "arrow-down", "Next issue (J)", "dt-next"))
	table.insert(head, iconBtn("prev", "arrow-up", "Previous issue (K)", "dt-prev"))
	local out: { Node } = {
		el("div", "head", "head", { class = "lt-head lt-dt-head" }, head),
		el("div", "dt-tools", "tools", { class = "lt-dt-tools" }, {
			el("span", "spacer", "sp", { class = "lt-spacer" }),
			iconBtn("copy-link", "link", "Copy issue URL", "dt-copy=link"),
			iconBtn("copy-id", "hash", "Copy issue ID", "dt-copy=id"),
			iconBtn("copy-branch", "branch", "Copy git branch name", "dt-copy=branch"),
			-- A split button: ▷ Start starts at once, ▾ opens the dropdown (New chat / Send to a session).
			el("div", "split", "split", { class = "lt-split" }, {
				el("button", "start", "start", { class = "lt-start lt-split-main", text = "▷ Start", title = "Start working on this issue in a new omp chat", actions = { click = "dt-start" } }),
				el("button", "split-caret", "caret", {
					class = "lt-start lt-split-caret",
					text = "▾",
					aria = "Start or send to a session",
					title = "Start in a new chat or send to a session",
					attrs = { ["data-open"] = flag(open == "split") },
					actions = { click = "dt-split" },
				}),
			}),
		}),
	}
	if dt.error then
		table.insert(out, el("div", "error", "error", { class = "lt-error", tone = "error", text = dt.error }))
	end

	local left: { Node } = {
		titleField(d),
	}
	if d.focus == "desc" then
		table.insert(left, descField(d, d.desc))
	elseif not info then
		table.insert(left, el("div", "dt-desc-view", "desc-view", { class = "lt-dt-desc lt-dt-muted", text = "Loading…" }))
	else
		-- shortcut: issue mentions show as Markdown links, not Linear's inline chips: ui.md takes text only.
		local text = d.desc.text
		table.insert(left, el("div", "dt-desc-view", "desc-view", {
			class = "lt-dt-desc",
			title = "Edit the description",
			actions = { click = "dt-desc" },
		}, { if text ~= "" then md("md", text) else el("span", "dt-muted", "ph", { class = "lt-dt-muted", text = "Add description…" }) }))
	end

	if info then
		table.insert(left, subIssues(dt, info.children))
		table.insert(left, el("div", "dt-divider", "divider", { class = "lt-dt-divider" }))
		table.insert(left, heading("activity", "Activity"))
		table.insert(left, el("div", "dt-timeline", "timeline", { class = "lt-dt-timeline" }, timeline(info)))
	end
	-- The card's click puts the caret in the box (a bare editor is not always focused by a click).
	table.insert(left, el("div", "dt-compose", "compose", { class = "lt-dt-compose", actions = { click = "dt-comment" } }, {
		Field.node("editor", { key = "comment", role = ROLE .. "dt-comment-input", placeholder = "Leave a comment…" }, dt.comment, "", COMMENT),
		el("div", "dt-compose-foot", "foot", { class = "lt-dt-compose-foot" }, {
			el("span", "dt-muted", "hint", { class = "lt-dt-muted", text = if dt.sending then "Sending…" else "" }),
			el("span", "spacer", "sp", { class = "lt-spacer" }),
			el("button", "dt-send", "send", {
				class = "lt-dt-send",
				aria = "Send comment",
				title = "Send comment (Ctrl+Enter)",
				attrs = { ["data-ready"] = flag(string.find(dt.comment.text, "%S") ~= nil and not dt.sending) },
				actions = { click = "dt-send" },
			}, { icon("arrow-up") }),
		}),
	}))

	-- Properties / Labels / Project: the modal's chips as sidebar rows; every chip stays a child
	-- of "props", where its list is anchored.
	local groups: { { string } } = { {}, {}, {} }
	for _, kind in Create.kinds(c) do
		table.insert(groups[if kind == "labels" then 2 elseif kind == "project" or kind == "cycle" then 3 else 1], kind)
	end
	local props: { Node } = {}
	for g, name in { "Properties", "Labels", "Project" } do
		table.insert(props, heading("h" .. g, name))
		for _, kind in groups[g] do
			table.insert(props, Create.chip(d, kind :: Create.Kind, c, true))
		end
	end
	local side: { Node } = { el("div", "dt-props", "props", { class = "lt-dt-props" }, props) }
	if info and #info.related > 0 then
		local rows = relatedRows(info.related)
		table.insert(rows, 1, heading("h", "Related"))
		table.insert(side, el("div", "dt-related", "related", { class = "lt-dt-props" }, rows))
	end

	table.insert(out, el("div", "detail", "detail", { class = "lt-detail" }, {
		el("div", "dt-left", "left", { class = "lt-dt-main" }, left),
		el("div", "dt-side", "side", { class = "lt-dt-side" }, side),
	}))
	return out
end

export type CardInfo = { agent: { kind: string?, line: string? }?, live: boolean, pos: number, total: number, menu: boolean }

local function cardIcon(key: string, text: string, label: string, action: string, attrs: { [string]: any }?): Node
	return el("button", "tc-icon", key, { class = "lt-tc-icon", text = text, aria = label, title = label, attrs = attrs, actions = { click = action } })
end

local function pill(key: string, text: string, label: string, action: string, attrs: { [string]: any }): Node
	attrs["data-icon"] = key
	return el("button", "tc-pill", key, { class = "lt-tc-pill", text = text, title = label, aria = label, attrs = attrs, actions = { click = action } })
end

-- The Tasks View's card for the open issue, beside the list: `info` from the host.
function M.card(dt: Detail, issue: any, c: Create.Ctx, info: CardInfo): Node
	local d = dt.d
	dt.live = info.live
	local popKind = if d.pop then d.pop.kind else nil
	local first = info.pos <= 1
	local last = info.pos == 0 or info.pos >= info.total
	local kids: { Node } = {
		el("div", "tc-head", "head", { class = "lt-tc-head" }, {
			el("span", "tc-ident", "ident", { class = "lt-tc-ident", text = str(issue.identifier) or "" }),
			el("span", "tc-spacer", "sp", { class = "lt-tc-spacer" }),
			cardIcon("more", "⋯", "More actions", "dt-more", { ["data-open"] = flag(info.menu) }),
			cardIcon("up", "↑", "Previous issue (K)", "dt-up", { ["data-dir"] = "up", ["data-edge"] = flag(first) }),
			cardIcon("down", "↓", "Next issue (J)", "dt-down", { ["data-dir"] = "down", ["data-edge"] = flag(last) }),
			cardIcon("close", "×", "Close (Esc)", "dt-close"),
		}),
		titleField(d, "lt-tc-title"),
	}
	if info.agent then
		table.insert(kids, el("div", "tc-badges", "badges", { class = "lt-tc-badges" }, {
			el("span", "tc-badge", "agent", { class = "lt-tc-badge", attrs = { ["data-kind"] = info.agent.kind }, text = info.agent.line or "" }),
		}))
	end
	local at = Model.epoch(issue.updatedAt)
	table.insert(kids, el("div", "tc-stamp", "stamp", {
		class = "lt-tc-stamp",
		text = if at then "Updated " .. Model.ago(issue.updatedAt, os.time()) .. " · " .. tostring(os.date("%a %d %b %Y, %H:%M", at)) else "",
	}))
	table.insert(kids, if dt.info then descField(d, d.desc, "lt-tc-desc") else descField(d, nil, "lt-tc-desc", if dt.error then "Could not load the description" else "Loading…"))

	local chips: { Node } = {}
	for _, kind in { "status", "priority", "assignee", "labels" } do
		table.insert(chips, Create.chip(d, kind :: Create.Kind, c))
	end
	table.insert(kids, el("div", "tc-props", "props", { class = "lt-tc-props" }, chips))

	local m = if d.model then chosenModel(d, c) else nil
	local model = if m then m.label elseif d.model then d.model else "Default model"
	table.insert(kids, el("div", "tc-agent", "agent", { class = "lt-tc-agent" }, {
		el("span", "tc-label", "label", { class = "lt-tc-label", text = "Hand it to an agent" }),
		pill("model", model, "Model", "cm-pop=model", { ["data-set"] = flag(d.model ~= nil), ["data-open"] = flag(popKind == "model") }),
		pill("thinking", d.thinking or "Default", "Thinking level (click to change)", "dt-think", { ["data-set"] = flag(d.thinking ~= nil), ["data-level"] = d.thinking or "default" }),
		pill("folder", if d.cwd then Create.folderName(d.cwd) else "No project", d.cwd or "Folder the chat starts in", "cm-pop=folder", { ["data-set"] = flag(d.cwd ~= nil), ["data-open"] = flag(popKind == "folder") }),
		pill("chat", "Send to chat", "Send to an open chat", "dt-chats", {}),
	}))

	local s = Model.stateById(c.states, d.stateId)
	local done = s ~= nil and s.type == "completed"
	table.insert(kids, el("div", "tc-buttons", "buttons", { class = "lt-tc-buttons" }, {
		el("button", "tc-btn", "full", { class = "lt-tc-btn", text = "Open issue", actions = { click = "dt-full" } }),
		el("button", "tc-btn", "primary", {
			class = "lt-tc-btn",
			text = if info.live then "Open pane" else "Start",
			title = if info.live then "Focus the chat working on this issue" else "Start working on this issue in a new omp chat",
			attrs = { ["data-primary"] = "true" },
			actions = { click = "dt-primary" },
		}),
		el("button", "tc-btn", "done", { class = "lt-tc-btn", text = if done then "Reopen" else "Mark as done", actions = { click = "dt-done" } }),
	}))
	return el("div", "tc-card", "card", { class = "lt-t-card" }, kids)
end

-- Where the card's model/folder list hangs: under its pill (the chips' lists use `d.anchor`).
function M.popAt(dt: Detail): string?
	local pop = dt.d.pop
	if dt.card and pop and (pop.kind == "model" or pop.kind == "folder") then
		return CARD .. ".agent." .. pop.kind
	end
	return nil
end

return M
