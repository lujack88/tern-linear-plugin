--!strict
-- The Linear-style "New issue" modal: title, description, property chips with searchable
-- popovers, issue templates, and "Create more". Drawn in the board block's layer.

local Model = require("./model")
local Field = require("./field")

local ui = tern.ui
local ROLE = "linear-todo."
local M = {}

-- Node paths from the layer root; field focus and popover anchors use them.
local MODAL = "layer.create"
local SEARCH = "layer.pop.q"

export type Kind = "status" | "priority" | "assignee" | "labels" | "estimate" | "project" | "cycle" | "due" | "template"
export type Option = { id: string, label: string, on: boolean?, hint: string?, icon: string? }
export type Pop = { kind: Kind, q: Field.Field, cursor: number }
export type Draft = {
	-- Node paths: the container of the title/description fields, and of the property chips.
	root: string,
	anchor: string,
	stateId: string,
	priority: number,
	assigneeId: string?,
	labelIds: { string },
	estimate: number?,
	projectId: string?,
	cycleId: string?,
	dueDate: string?,
	templateId: string?,
	templateName: string?,
	-- The description a template filled in; left untouched, Linear applies the template's own rich text.
	descTemplate: string?,
	title: Field.Field,
	desc: Field.Field,
	focus: ("title" | "desc")?,
	pop: Pop?,
	more: boolean,
	error: string?,
}
-- What the modal needs from the board: the team's States, the fetched choices, the Setup.
export type Ctx = { states: { any }, meta: any?, teamKey: string, teamId: string, viewerId: string? }

local function el(tag: string, role: string, key: string, props: { [string]: any }?, children: { Node }?): Node
	local p: { [string]: any } = props or {}
	p.role = ROLE .. role
	p.key = key
	return ui.el(tag, p, children)
end

local function flag(on: boolean): string?
	return if on then "true" else nil
end

function M.new(stateId: string, assigneeId: string?): Draft
	return {
		root = MODAL,
		anchor = MODAL .. ".chips",
		stateId = stateId,
		priority = 0,
		assigneeId = assigneeId,
		labelIds = {},
		title = Field.new("", false, 255),
		desc = Field.new("", true, 20000),
		focus = "title",
		more = false,
	}
end

local function fieldPath(d: Draft, which: "title" | "desc"): string
	return d.root .. "." .. which
end

-- Moves the caret into `which` (nil: out of every field).
function M.focus(d: Draft, which: ("title" | "desc")?, cx: BlockCx)
	d.focus = which
	if which then
		local f = if which == "title" then d.title else d.desc
		cx:frame({ { "focus", fieldPath(d, which) .. "_" .. f.rev } })
	else
		cx:frame({ { "focus", tern.json.null } })
	end
end

function M.openPop(d: Draft, kind: Kind, cx: BlockCx)
	local q = Field.new("", false, 100)
	d.pop = { kind = kind, q = q, cursor = 1 }
	d.focus = nil
	cx:frame({ { "focus", SEARCH .. "_" .. q.rev } })
end

function M.closePop(d: Draft, cx: BlockCx)
	d.pop = nil
	cx:frame({ { "focus", tern.json.null } })
end

-- Lookups ---------------------------------------------------------------------

local function byId(list: { any }?, id: string?): any
	local all: { any } = list or {}
	for _, x in all do
		if x.id == id then
			return x
		end
	end
	return nil
end

local function labelName(l: any): string
	return if type(l.parent) == "table" and l.parent.name then l.parent.name .. " › " .. l.name else l.name
end

local function cycleName(c: any): string
	return if type(c.name) == "string" and c.name ~= "" then c.name else "Cycle " .. tostring(c.number)
end

local function today(): any
	return os.date("*t")
end

-- Options ---------------------------------------------------------------------

local function options(d: Draft, c: Ctx): { Option }
	local kind = (d.pop :: Pop).kind
	local meta = c.meta or {}
	local out: { Option } = {}
	local function add(id: string, label: string, on: boolean, hint: string?, icon: string?)
		table.insert(out, { id = id, label = label, on = on, hint = hint, icon = icon })
	end
	if kind == "status" then
		for _, s in Model.visibleStates(c.states) do
			add(s.id, s.name, s.id == d.stateId, nil, s.type)
		end
	elseif kind == "priority" then
		for _, p in Model.PRIORITIES do
			add(tostring(p.value), p.label, p.value == d.priority, nil, Model.prioClass(p.value))
		end
	elseif kind == "assignee" then
		add("none", "No assignee", d.assigneeId == nil)
		local me = byId(meta.members, c.viewerId)
		if me then
			add(me.id, me.name, me.id == d.assigneeId, "Me")
		end
		local people = {}
		for _, u in meta.members or {} do
			if u.active ~= false and u.id ~= c.viewerId then
				table.insert(people, u)
			end
		end
		table.sort(people, function(a: any, b: any): boolean
			return string.lower(a.name) < string.lower(b.name)
		end)
		for _, u in people do
			add(u.id, u.name, u.id == d.assigneeId, u.displayName)
		end
	elseif kind == "labels" then
		local on: { [string]: boolean } = {}
		for _, id in d.labelIds do
			on[id] = true
		end
		local labels = {}
		for _, l in meta.labels or {} do
			if not l.isGroup then
				table.insert(labels, l)
			end
		end
		table.sort(labels, function(a: any, b: any): boolean
			return string.lower(labelName(a)) < string.lower(labelName(b))
		end)
		for _, l in labels do
			add(l.id, labelName(l), on[l.id] == true, nil, Model.labelClass(l.color))
		end
	elseif kind == "estimate" then
		add("none", "No estimate", d.estimate == nil)
		for _, o in Model.estimateOptions(meta.estimation) do
			add(tostring(o.value), o.label, o.value == d.estimate)
		end
	elseif kind == "project" then
		add("none", "No project", d.projectId == nil)
		for _, p in meta.projects or {} do
			if not p.completedAt and not p.canceledAt then
				add(p.id, p.name, p.id == d.projectId)
			end
		end
	elseif kind == "cycle" then
		add("none", "No cycle", d.cycleId == nil)
		local cycles = {}
		for _, cy in meta.cycles or {} do
			table.insert(cycles, cy)
		end
		table.sort(cycles, function(a: any, b: any): boolean
			return (a.startsAt or "") < (b.startsAt or "")
		end)
		for _, cy in cycles do
			add(cy.id, cycleName(cy), cy.id == d.cycleId, if type(cy.startsAt) == "string" then string.sub(cy.startsAt, 1, 10) else nil)
		end
	elseif kind == "due" then
		local q = (d.pop :: Pop).q.text
		if Model.isDate(q) then
			add(q, "Due " .. q, q == d.dueDate)
		end
		local t = today()
		local friday = (6 - t.wday) % 7
		add(Model.addDays(t, 0), "Today", false, Model.addDays(t, 0))
		add(Model.addDays(t, 1), "Tomorrow", false, Model.addDays(t, 1))
		add(Model.addDays(t, friday), "End of this week", false, Model.addDays(t, friday))
		add(Model.addDays(t, 7), "In one week", false, Model.addDays(t, 7))
		if d.dueDate then
			add("none", "Remove due date", false)
		end
		return out -- the query is the date itself, not a filter
	elseif kind == "template" then
		add("none", "No template", d.templateId == nil)
		for _, tp in meta.templates or {} do
			local team = tp.team
			if tp.type == "issue" and (type(team) ~= "table" or team.id == c.teamId) then
				add(tp.id, tp.name, tp.id == d.templateId, if type(team) == "table" then c.teamKey else "Workspace")
			end
		end
	end
	local q = (d.pop :: Pop).q.text
	if q == "" then
		return out
	end
	local hit: { Option } = {}
	for _, o in out do
		if Model.matches(o.label, q) then
			table.insert(hit, o)
		end
	end
	return hit
end

-- Templates -------------------------------------------------------------------

local function decode(v: any): any
	if type(v) ~= "string" then
		return v
	end
	local ok, out = pcall(tern.json.decode, v)
	return if ok then out else nil
end

local function applyTemplate(d: Draft, tp: any)
	local data = decode(tp.templateData)
	local f = Model.templateFields(data, if type(data) == "table" then decode(data.descriptionData) else nil)
	d.templateId, d.templateName = tp.id, tp.name
	if f.title then
		Field.reset(d.title, f.title)
	end
	Field.reset(d.desc, f.description or "")
	d.descTemplate = f.description
	d.stateId = f.stateId or d.stateId
	d.priority = f.priority or d.priority
	d.assigneeId = f.assigneeId or d.assigneeId
	d.labelIds = f.labelIds or d.labelIds
	d.estimate = f.estimate or d.estimate
	d.projectId = f.projectId or d.projectId
	d.cycleId = f.cycleId or d.cycleId
	d.dueDate = f.dueDate or d.dueDate
end

-- Applies option `id` of the open popover. Labels stay open for more picks.
function M.choose(d: Draft, id: string, c: Ctx, cx: BlockCx)
	local pop = d.pop
	if not pop then
		return
	end
	local none = id == "none"
	local kind = pop.kind
	if kind == "status" then
		d.stateId = id
	elseif kind == "priority" then
		d.priority = tonumber(id) or 0
	elseif kind == "assignee" then
		d.assigneeId = if none then nil else id
	elseif kind == "labels" then
		local picked = byId(c.meta and c.meta.labels, id)
		local keep: { string } = {}
		local had = false
		for _, l in d.labelIds do
			local other = byId(c.meta and c.meta.labels, l)
			if l == id then
				had = true
			-- A label group allows one of its labels at a time.
			elseif not (picked and other and type(picked.parent) == "table" and type(other.parent) == "table" and picked.parent.id == other.parent.id) then
				table.insert(keep, l)
			end
		end
		if not had then
			table.insert(keep, id)
		end
		d.labelIds = keep
		Field.reset(pop.q, "")
		return
	elseif kind == "estimate" then
		d.estimate = if none then nil else tonumber(id)
	elseif kind == "project" then
		d.projectId = if none then nil else id
	elseif kind == "cycle" then
		d.cycleId = if none then nil else id
	elseif kind == "due" then
		d.dueDate = if none then nil else id
	elseif kind == "template" then
		if none then
			d.templateId, d.templateName, d.descTemplate = nil, nil, nil
		else
			local tp = byId(c.meta and c.meta.templates, id)
			if tp then
				applyTemplate(d, tp)
			end
		end
	end
	M.closePop(d, cx)
end

-- Submission ------------------------------------------------------------------

local function orNull(v: any): any
	return if v == nil then tern.json.null else v
end

-- The issueCreate input, or an error for the modal. With a template every shown property is
-- sent (null when cleared), so the modal wins over the template for everything it shows.
function M.input(d: Draft, teamId: string): (any?, string?)
	local title = string.match(d.title.text, "^%s*(.-)%s*$") or ""
	if title == "" then
		return nil, "A title is required"
	end
	local t = d.templateId ~= nil
	local input: { [string]: any } = { teamId = teamId, title = title, stateId = d.stateId, priority = d.priority, templateId = d.templateId }
	input.assigneeId = if t then orNull(d.assigneeId) else d.assigneeId
	input.estimate = if t then orNull(d.estimate) else d.estimate
	input.projectId = if t then orNull(d.projectId) else d.projectId
	input.cycleId = if t then orNull(d.cycleId) else d.cycleId
	input.dueDate = if t then orNull(d.dueDate) else d.dueDate
	if t or #d.labelIds > 0 then
		input.labelIds = tern.json.array(d.labelIds)
	end
	local desc = d.desc.text
	if desc ~= d.descTemplate and (desc ~= "" or d.descTemplate ~= nil) then
		input.description = desc
	end
	return input, nil
end

-- After "Create more": a fresh title and description, the properties kept, as Linear does.
function M.again(d: Draft, cx: BlockCx)
	Field.reset(d.title, "")
	Field.reset(d.desc, "")
	d.templateId, d.templateName, d.descTemplate, d.error = nil, nil, nil, nil
	M.focus(d, "title", cx)
end

-- Input -----------------------------------------------------------------------

-- Linear's modal shortcuts, active while no text field has the caret.
local SHORTCUTS: { [string]: Kind } = { s = "status", p = "priority", a = "assignee", l = "labels", e = "estimate", t = "template" }
local SHIFTED: { [string]: Kind } = { p = "project", c = "cycle", d = "due" }

-- A key for the open property list; whether it was used.
function M.popKey(d: Draft, k: Key, c: Ctx, cx: BlockCx): boolean
	local pop = d.pop :: Pop
	local name = k.name
	local list = options(d, c)
	if name == "escape" then
		M.closePop(d, cx)
	elseif name == "up" or name == "down" then
		pop.cursor = math.clamp(pop.cursor + (if name == "up" then -1 else 1), 1, math.max(#list, 1))
	elseif name == "enter" then
		local o = list[pop.cursor]
		if o then
			M.choose(d, o.id, c, cx)
		end
	else
		local what = Field.edit_key(pop.q, k, cx)
		if what == "text" then
			pop.cursor = 1
		end
		return what ~= nil
	end
	return true
end

-- The property shortcut `k` stands for (Linear's), if any; `template` only where offered.
function M.shortcut(k: Key, template: boolean): Kind?
	if k.ctrl or k.meta or k.alt then
		return nil
	end
	local kind: Kind? = if k.shift then SHIFTED[k.name] else SHORTCUTS[k.name]
	return if kind == "template" and not template then nil else kind
end

-- Handles a key while the modal is open: "submit", "close", or whether it was used.
function M.key(d: Draft, k: Key, c: Ctx, cx: BlockCx): ("submit" | "close" | boolean)
	local name = k.name
	if (k.ctrl or k.meta) and name == "enter" then
		return "submit"
	end
	if d.pop then
		return M.popKey(d, k, c, cx)
	end
	local focus = d.focus
	if focus then
		if name == "tab" then
			M.focus(d, if focus == "title" and not k.shift then "desc" else "title", cx)
			return true
		end
		local f = if focus == "title" then d.title else d.desc
		local what = Field.edit_key(f, k, cx)
		if what == "submit" then
			M.focus(d, "desc", cx)
		elseif what == "blur" then
			M.focus(d, nil, cx)
		elseif what == nil then
			return false
		end
		return true
	end
	if name == "escape" then
		return "close"
	elseif name == "enter" or name == "tab" then
		M.focus(d, "title", cx)
		return true
	end
	local kind = M.shortcut(k, true)
	if kind then
		M.openPop(d, kind :: Kind, cx)
		return true
	end
	return false
end

-- Routes edit/undo/focus events to the modal's fields; true when one was the modal's.
function M.event(d: Draft, ev: UiEvent): boolean
	local fields: { [string]: Field.Field } = { title = d.title, desc = d.desc }
	if d.pop then
		fields.q = d.pop.q
	end
	for name, f in fields do
		if ev.id == f.id then
			if ev.ev == "edit" then
				if Field.apply_edit(f, ev) == "text" and name == "q" then
					(d.pop :: Pop).cursor = 1
				end
			elseif ev.ev == "undo" then
				Field.undo_step(f, false)
			elseif ev.ev == "focus" and name ~= "q" then
				-- A click into the title or description takes the keys back from an open list.
				d.focus, d.pop = name :: any, nil
			end
			return true
		end
	end
	if ev.ev == "focus" then
		d.focus = nil
	end
	return false
end

-- View ------------------------------------------------------------------------

local function chipText(d: Draft, kind: Kind, c: Ctx): (string, boolean)
	local meta = c.meta or {}
	if kind == "status" then
		local s = Model.stateById(c.states, d.stateId)
		return if s then s.name else "Status", true
	elseif kind == "priority" then
		for _, p in Model.PRIORITIES do
			if p.value == d.priority and p.value ~= 0 then
				return p.label, true
			end
		end
		return "Priority", false
	elseif kind == "assignee" then
		local u = byId(meta.members, d.assigneeId)
		return if u then u.name elseif d.assigneeId then "Assigned" else "Assignee", d.assigneeId ~= nil
	elseif kind == "labels" then
		if #d.labelIds == 0 then
			return "Labels", false
		end
		local names = {}
		for _, id in d.labelIds do
			local l = byId(meta.labels, id)
			table.insert(names, if l then l.name else "?")
		end
		if #names > 2 then
			return names[1] .. ", " .. names[2] .. " +" .. (#names - 2), true
		end
		return table.concat(names, ", "), true
	elseif kind == "estimate" then
		return if d.estimate then Model.estimateLabel(meta.estimation and meta.estimation.type, d.estimate) else "Estimate", d.estimate ~= nil
	elseif kind == "project" then
		local p = byId(meta.projects, d.projectId)
		return if p then p.name else "Project", d.projectId ~= nil
	elseif kind == "cycle" then
		local cy = byId(meta.cycles, d.cycleId)
		return if cy then cycleName(cy) else "Cycle", d.cycleId ~= nil
	elseif kind == "due" then
		return if d.dueDate then "Due " .. d.dueDate else "Due date", d.dueDate ~= nil
	end
	return d.templateName or "Template", d.templateId ~= nil
end

local KEYS: { [Kind]: string } = {
	status = "S", priority = "P", assignee = "A", labels = "L", estimate = "E",
	project = "Shift+P", cycle = "Shift+C", due = "Shift+D", template = "T",
}

function M.chip(d: Draft, kind: Kind, c: Ctx): Node
	local text, set = chipText(d, kind, c)
	local lead: Node? = nil
	if kind == "status" then
		local s = Model.stateById(c.states, d.stateId)
		lead = el("span", "state", "icon", { class = "lt-state", attrs = { ["data-type"] = s and s.type } })
	elseif kind == "priority" then
		lead = el("span", "prio-dot", "icon", { class = "lt-chip-icon", text = if d.priority == 1 then "!" else "▮" })
	end
	return el("button", "chip", kind, {
		class = "lt-chip",
		attrs = { ["data-set"] = flag(set), ["data-open"] = flag(d.pop ~= nil and (d.pop :: Pop).kind == kind) },
		title = text .. " (" .. KEYS[kind] .. ")",
		aria = text,
		actions = { click = "cm-pop=" .. kind },
	}, if lead then { lead, el("span", "chip-text", "text", { class = "lt-chip-text", text = text }) } else { el("span", "chip-text", "text", { class = "lt-chip-text", text = text }) })
end

local PLACEHOLDER: { [Kind]: string } = {
	status = "Change status…", priority = "Set priority…", assignee = "Assign to…", labels = "Add labels…",
	estimate = "Set estimate…", project = "Add to project…", cycle = "Add to cycle…",
	due = "YYYY-MM-DD or pick below", template = "Use a template…",
}

function M.popover(d: Draft, c: Ctx): Node
	local pop = d.pop :: Pop
	local rows: { Node } = {}
	-- Status, priority and due date need nothing fetched.
	local waiting = not c.meta and pop.kind ~= "status" and pop.kind ~= "priority" and pop.kind ~= "due"
	if waiting then
		table.insert(rows, el("div", "pop-none", "loading", { class = "lt-pop-none", text = "Loading…" }))
	else
		for i, o in options(d, c) do
			local kids: { Node } = {}
			if pop.kind == "labels" then
				table.insert(kids, el("span", "check", "check", { class = "lt-check", text = if o.on then "✓" else "" }))
				table.insert(kids, el("span", "dot", "dot", { class = "lt-label lt-label-bare", attrs = { ["data-c"] = o.icon } }, { el("span", "dot", "dot", { class = "lt-dot" }) }))
			elseif pop.kind == "status" then
				table.insert(kids, el("span", "state", "icon", { class = "lt-state", attrs = { ["data-type"] = o.icon } }))
			end
			table.insert(kids, el("span", "pop-label", "label", { class = "lt-pop-label", text = o.label }))
			if o.hint then
				table.insert(kids, el("span", "pop-hint", "hint", { class = "lt-pop-hint", text = o.hint }))
			end
			if o.on and pop.kind ~= "labels" then
				table.insert(kids, el("span", "pop-on", "on", { class = "lt-pop-on", text = "✓" }))
			end
			table.insert(rows, el("button", "pop-row", "o" .. i, {
				class = "lt-pop-row",
				attrs = { ["data-cursor"] = flag(i == pop.cursor) },
				actions = { click = "cm-pick=" .. o.id },
			}, kids))
		end
		if #rows == 0 then
			table.insert(rows, el("div", "pop-none", "none", { class = "lt-pop-none", text = "No matches" }))
		end
	end
	return {
		k = "overlay",
		p = { key = "pop", role = ROLE .. "pop", aria = PLACEHOLDER[pop.kind], anchor = { node = d.anchor .. "." .. pop.kind, side = "below" }, size = "sm" },
		c = {
			Field.node("input", { key = "q", role = ROLE .. "pop-q", placeholder = PLACEHOLDER[pop.kind] }, pop.q, "", SEARCH),
			el("div", "pop-list", "opts", { class = "lt-pop-list" }, rows),
		},
	} :: any
end

-- The property chips the team uses, in Linear's order (estimate and cycle only when on).
function M.kinds(c: Ctx): { Kind }
	local kinds: { Kind } = { "status", "priority", "assignee", "labels" }
	local meta = c.meta
	if meta and #Model.estimateOptions(meta.estimation) > 0 then
		table.insert(kinds, "estimate")
	end
	table.insert(kinds, "project")
	if meta and meta.cyclesEnabled then
		table.insert(kinds, "cycle")
	end
	table.insert(kinds, "due")
	return kinds
end

-- The layer's children: the modal, and the open popover anchored to its chip.
function M.view(d: Draft, c: Ctx): { Node }
	local chips: { Node } = {}
	for _, kind in M.kinds(c) do
		table.insert(chips, M.chip(d, kind :: Kind, c))
	end
	local body: { Node } = {
		el("div", "modal-top", "top", { class = "lt-modal-top" }, {
			el("span", "ws", "team", { class = "lt-ws", text = c.teamKey }),
			el("span", "modal-crumb", "crumb", { class = "lt-modal-crumb", text = "› New issue" }),
			el("span", "spacer", "sp", { class = "lt-spacer" }),
			M.chip(d, "template", c),
		}),
		Field.node("input", { key = "title", role = ROLE .. "modal-title", placeholder = "Issue title" }, d.title, "", fieldPath(d, "title")),
		Field.node("editor", { key = "desc", role = ROLE .. "modal-desc", placeholder = "Add description…" }, d.desc, "", fieldPath(d, "desc")),
		el("div", "chips", "chips", { class = "lt-modal-chips" }, chips),
	}
	if d.error then
		table.insert(body, el("div", "modal-error", "error", { class = "lt-modal-error", tone = "error", text = d.error }))
	end
	table.insert(body, el("div", "modal-foot", "foot", { class = "lt-modal-foot" }, {
		el("span", "spacer", "sp", { class = "lt-spacer" }),
		el("button", "more", "more", {
			class = "lt-more",
			text = "Create more",
			attrs = { ["data-on"] = flag(d.more), ["aria-pressed"] = if d.more then "true" else "false" },
			actions = { click = "cm-more" },
		}),
		el("button", "submit", "submit", { class = "lt-submit", text = "Create issue", title = "Ctrl+Enter", actions = { click = "cm-submit" } }),
	}))
	local out: { Node } = {
		ui.node("overlay", { key = "create", role = ROLE .. "modal", aria = "New issue", size = "lg", modal = true }, body),
	}
	if d.pop then
		table.insert(out, M.popover(d, c))
	end
	return out
end

-- Clicks inside the modal: "submit", "close", or whether it was the modal's.
function M.act(d: Draft, name: string, value: string, c: Ctx, cx: BlockCx): ("submit" | "close" | boolean)
	if name == "cm-pop" then
		if d.pop and d.pop.kind == value then
			M.closePop(d, cx)
		else
			M.openPop(d, value :: Kind, cx)
		end
	elseif name == "cm-pick" then
		M.choose(d, value, c, cx)
	elseif name == "cm-more" then
		d.more = not d.more
	elseif name == "cm-submit" then
		return "submit"
	elseif name == "cm-close" then
		return "close"
	else
		return false
	end
	return true
end

return M
