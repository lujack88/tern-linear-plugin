--!strict
-- Pure board model: States, columns, overlays and presentation helpers. No tern calls.

local M = {}

export type Overlay = { stateId: string?, title: string?, gone: boolean? }
export type Column = { state: any, issues: { any } }
export type Opts = { mine: string? }

-- Board order of the visible State types; canceled, duplicate and triage have no column.
local TYPE_ORDER = { backlog = 1, unstarted = 2, started = 3, completed = 4 }

-- Visible States in board order: by type, then Linear's `position`.
function M.visibleStates(states: { any }): { any }
	local out: { any } = {}
	for _, s in states do
		if TYPE_ORDER[s.type] then
			table.insert(out, s)
		end
	end
	table.sort(out, function(a: any, b: any): boolean
		local ta, tb = TYPE_ORDER[a.type], TYPE_ORDER[b.type]
		if ta ~= tb then
			return ta < tb
		end
		local pa, pb = a.position or 0, b.position or 0
		if pa ~= pb then
			return pa < pb
		end
		return (a.name or "") < (b.name or "")
	end)
	return out
end

function M.stateById(states: { any }, id: string?): any
	for _, s in states do
		if s.id == id then
			return s
		end
	end
	return nil
end

-- The lowest-positioned canceled State: where "cancel" moves an issue.
function M.cancelState(states: { any }): string?
	local best: any = nil
	for _, s in states do
		if s.type == "canceled" and (best == nil or (s.position or 0) < (best.position or 0)) then
			best = s
		end
	end
	return best and best.id
end

-- Overlay wins over the issue: an optimistic local move/rename, or gone when Linear dropped it.
function M.effective(issue: any, overlay: { [string]: Overlay }?): (string?, string, boolean)
	local o = if overlay then overlay[issue.id] else nil
	local stateId = (o and o.stateId) or (issue.state and issue.state.id)
	local title = (o and o.title) or issue.title
	return stateId, title, (o and o.gone == true) or false
end

-- Priority rank: 1 Urgent … 4 Low, everything else (0 = none) last.
local function rank(p: any): number
	if type(p) == "number" and p >= 1 and p <= 4 then
		return p
	end
	return 5
end

local function before(a: any, b: any): boolean
	local ra, rb = rank(a.priority), rank(b.priority)
	if ra ~= rb then
		return ra < rb
	end
	local ua, ub = a.updatedAt or "", b.updatedAt or ""
	if ua ~= ub then
		return ua > ub
	end
	return (a.identifier or "") < (b.identifier or "")
end

-- One column per visible State, in board order; `opts.mine` keeps only that assignee's issues.
function M.columns(issues: { any }, states: { any }, overlay: { [string]: Overlay }?, opts: Opts?): { Column }
	local mine = opts and opts.mine
	local cols: { Column } = {}
	local byId: { [string]: { any } } = {}
	for _, s in M.visibleStates(states) do
		local col: Column = { state = s, issues = {} }
		table.insert(cols, col)
		byId[s.id] = col.issues
	end
	for _, issue in issues do
		local stateId, _, gone = M.effective(issue, overlay)
		local list = if stateId then byId[stateId] else nil
		local a = issue.assignee
		if list and not gone and (not mine or (type(a) == "table" and a.id == mine)) then
			table.insert(list, issue)
		end
	end
	for _, col in cols do
		table.sort(col.issues, before)
	end
	return cols
end

-- The List View's rows top to bottom: every column's issues, groups in board order.
function M.list(cols: { Column }): { any }
	local out: { any } = {}
	for _, col in cols do
		for _, issue in col.issues do
			table.insert(out, issue)
		end
	end
	return out
end

-- Index of the column holding `stateId`, or nil.
function M.columnIndex(cols: { Column }, stateId: string?): number?
	for i, col in cols do
		if col.state.id == stateId then
			return i
		end
	end
	return nil
end

function M.prioClass(p: number?): string
	if type(p) == "number" and p == math.floor(p) and p >= 1 and p <= 4 then
		return "p" .. p
	end
	return "p0"
end

-- Hue buckets of an "#rrggbb" label colour; low saturation reads as gray.
function M.labelClass(hex: string?): string
	if type(hex) ~= "string" then
		return "gray"
	end
	local rh, gh, bh = string.match(string.lower(hex), "^#(%x%x)(%x%x)(%x%x)$")
	if not rh or not gh or not bh then
		return "gray"
	end
	local r = tonumber(rh, 16) :: number / 255
	local g = tonumber(gh, 16) :: number / 255
	local b = tonumber(bh, 16) :: number / 255
	local max = math.max(r, g, b)
	local min = math.min(r, g, b)
	local d = max - min
	-- Chroma over (max + min); unlike the |2l-1| form it reads washed-out tints as gray.
	local s = if max + min > 0 then d / (max + min) else 0
	local h = 0
	if d > 0 then
		if max == r then
			h = ((g - b) / d) % 6
		elseif max == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h *= 60
	end
	if s < 0.15 then
		return "gray"
	end
	if h < 15 or h >= 345 then
		return "red"
	elseif h < 45 then
		return "orange"
	elseif h < 70 then
		return "yellow"
	elseif h < 160 then
		return "green"
	elseif h < 195 then
		return "teal"
	elseif h < 245 then
		return "blue"
	elseif h < 290 then
		return "purple"
	end
	return "pink"
end

function M.initials(name: string?): string
	if type(name) ~= "string" then
		return "?"
	end
	local first, second = string.match(name, "^%s*(%S+)%s+(%S+)")
	if first and second then
		return string.upper(string.sub(first, 1, 1) .. string.sub(second, 1, 1))
	end
	local one = string.match(name, "^%s*(%S+)")
	if not one then
		return "?"
	end
	return string.upper(string.sub(one, 1, 2))
end

function M.estimate(e: number?): string?
	if type(e) ~= "number" then
		return nil
	end
	if e == math.floor(e) then
		return tostring(e)
	end
	return string.format("%.1f", e)
end

-- Create modal ----------------------------------------------------------------

M.PRIORITIES = { { value = 0, label = "No priority" }, { value = 1, label = "Urgent" }, { value = 2, label = "High" }, { value = 3, label = "Medium" }, { value = 4, label = "Low" } }

local SCALES: { [string]: { number } } = {
	exponential = { 1, 2, 4, 8, 16, 32, 64 },
	fibonacci = { 1, 2, 3, 5, 8, 13, 21 },
	linear = { 1, 2, 3, 4, 5, 6, 7 },
	-- shortcut: T-shirt sizes are assumed to store Linear's fibonacci points; check against a T-shirt team if one appears.
	tShirt = { 1, 2, 3, 5, 8, 13, 21 },
}
local SIZES: { [number]: string } = { [1] = "XS", [2] = "S", [3] = "M", [5] = "L", [8] = "XL", [13] = "XXL", [21] = "XXXL" }

export type Estimation = { type: string?, allowZero: boolean, extended: boolean }

function M.estimateLabel(scale: string?, value: number): string
	if scale == "tShirt" and SIZES[value] then
		return SIZES[value]
	end
	return value .. (if value == 1 then " point" else " points")
end

-- The team's estimate choices, empty when it does not estimate ("notUsed").
function M.estimateOptions(est: Estimation?): { { value: number, label: string } }
	local scale = est and est.type and SCALES[est.type]
	if not est or not scale then
		return {}
	end
	local out = {}
	if est.allowZero then
		table.insert(out, { value = 0, label = M.estimateLabel(est.type, 0) })
	end
	for i = 1, if est.extended then 7 else 5 do
		table.insert(out, { value = scale[i], label = M.estimateLabel(est.type, scale[i]) })
	end
	return out
end

-- Case-insensitive substring match; an empty query matches everything.
function M.matches(text: string, query: string): boolean
	return query == "" or string.find(string.lower(text), string.lower(query), 1, true) ~= nil
end

-- ProseMirror node names arrive as `bullet_list` or `bulletList`.
local function kind(n: any): string
	return if type(n) == "table" and type(n.type) == "string" then string.lower((string.gsub(n.type, "_", ""))) else ""
end

local function children(n: any): { any }
	return if type(n.content) == "table" then n.content else {}
end

local function inline(n: any): string
	local k = kind(n)
	if k == "text" then
		local t = if type(n.text) == "string" then n.text else ""
		for _, mark in (if type(n.marks) == "table" then n.marks else {}) do
			local m = kind(mark)
			if m == "code" then
				t = "`" .. t .. "`"
			elseif m == "bold" or m == "strong" then
				t = "**" .. t .. "**"
			elseif m == "italic" or m == "em" then
				t = "_" .. t .. "_"
			elseif m == "strike" or m == "strikethrough" then
				t = "~~" .. t .. "~~"
			elseif m == "link" and type(mark.attrs) == "table" and type(mark.attrs.href) == "string" then
				t = "[" .. t .. "](" .. mark.attrs.href .. ")"
			end
		end
		return t
	elseif k == "hardbreak" then
		return "\n"
	end
	local parts = {}
	for _, c in children(n) do
		table.insert(parts, inline(c))
	end
	if #parts == 0 and type(n.attrs) == "table" and type(n.attrs.label) == "string" then
		return n.attrs.label
	end
	return table.concat(parts)
end

local block: (n: any) -> string

-- `lead` starts the item's first line; later lines are indented under it.
local function item(n: any, lead: string): string
	local parts = {}
	for _, c in children(n) do
		table.insert(parts, block(c))
	end
	local text = table.concat(parts, "\n")
	return lead .. (string.gsub(text, "\n", "\n" .. string.rep(" ", #lead)))
end

block = function(n: any): string
	local k = kind(n)
	local attrs = if type(n.attrs) == "table" then n.attrs else {}
	if k == "paragraph" then
		return inline(n)
	elseif k == "heading" then
		return string.rep("#", tonumber(attrs.level) or 1) .. " " .. inline(n)
	elseif k == "bulletlist" or k == "orderedlist" or k == "todolist" or k == "tasklist" then
		local lines = {}
		for i, it in children(n) do
			local ia = if type(it.attrs) == "table" then it.attrs else {}
			local lead = if k == "orderedlist" then i .. ". "
				elseif k == "bulletlist" then "- "
				else (if ia.done or ia.checked then "- [x] " else "- [ ] ")
			table.insert(lines, item(it, lead))
		end
		return table.concat(lines, "\n")
	elseif k == "codeblock" then
		return "```" .. (if type(attrs.language) == "string" then attrs.language else "") .. "\n" .. inline(n) .. "\n```"
	elseif k == "blockquote" then
		local inner = {}
		for _, c in children(n) do
			table.insert(inner, block(c))
		end
		return "> " .. (string.gsub(table.concat(inner, "\n\n"), "\n", "\n> "))
	elseif k == "horizontalrule" then
		return "---"
	elseif #children(n) > 0 and kind(children(n)[1]) ~= "text" then
		local inner = {}
		for _, c in children(n) do
			table.insert(inner, block(c))
		end
		return table.concat(inner, "\n\n")
	end
	return inline(n)
end

-- Markdown of a ProseMirror document (Linear's `descriptionData`); nil when it is not one.
function M.markdown(doc: any): string?
	if type(doc) ~= "table" or kind(doc) ~= "doc" then
		return nil
	end
	return block(doc)
end

-- The issue fields an issue template's `templateData` sets, read defensively.
function M.templateFields(data: any): { [string]: any }
	local out: { [string]: any } = {}
	if type(data) ~= "table" then
		return out
	end
	for _, f in { "title", "stateId", "assigneeId", "projectId", "cycleId", "dueDate" } do
		if type(data[f]) == "string" and data[f] ~= "" then
			out[f] = data[f]
		end
	end
	for _, f in { "priority", "estimate" } do
		if type(data[f]) == "number" then
			out[f] = data[f]
		end
	end
	if type(data.labelIds) == "table" then
		out.labelIds = table.clone(data.labelIds)
	end
	out.description = if type(data.description) == "string" then data.description else M.markdown(data.descriptionData)
	return out
end

-- `t` plus `days`, as Linear's YYYY-MM-DD; `t` is a `*t` date table.
function M.addDays(t: any, days: number): string
	return os.date("%Y-%m-%d", os.time({ year = t.year, month = t.month, day = t.day + days, hour = 12 })) :: string
end

function M.isDate(s: string): boolean
	return string.match(s, "^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

return M
