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

-- Deepest indentation of a sub-issue row; deeper descendants stay at this depth.
local MAX_DEPTH = 3

-- A List row's place in the sub-issue tree: `depth` 0 is top level; `last` marks its parent's last
-- shown child (the rounded elbow); `rails[k]` (k < depth) whether the connector line of the
-- ancestor at depth k runs on past this row to a later sibling.
export type Tree = { depth: number, last: boolean, rails: { boolean } }

local function parentId(issue: any): string?
	local p = issue.parent
	return if type(p) == "table" and type(p.id) == "string" then p.id else nil
end

-- One List group's rows: `issues` (sorted) with every sub-issue whose parent is in the same group
-- moved right after that parent, siblings in their sorted order, recursively; and each id's Tree.
-- A sub-issue whose parent is not in `issues` stays where it sorted, at depth 0.
function M.nest(issues: { any }): ({ any }, { [string]: Tree })
	local here: { [string]: boolean } = {}
	for _, issue in issues do
		here[issue.id] = true
	end
	local kids: { [string]: { any } } = {}
	local roots: { any } = {}
	for _, issue in issues do
		local p = parentId(issue)
		if p and p ~= issue.id and here[p] then
			kids[p] = kids[p] or {}
			table.insert(kids[p], issue)
		else
			table.insert(roots, issue)
		end
	end
	local out: { any } = {}
	local tree: { [string]: Tree } = {}
	local function visit(issue: any, depth: number, last: boolean, rails: { boolean })
		if tree[issue.id] then
			return
		end
		tree[issue.id] = { depth = math.min(depth, MAX_DEPTH), last = last, rails = rails }
		table.insert(out, issue)
		local list = kids[issue.id]
		if not list then
			return
		end
		local sub = table.clone(rails)
		if depth >= 1 and depth < MAX_DEPTH then
			table.insert(sub, not last)
		end
		for i, c in list do
			visit(c, depth + 1, i == #list, sub)
		end
	end
	for _, issue in roots do
		visit(issue, 0, false, {})
	end
	-- A parent loop has no root: start it at its first member rather than drop it.
	for _, issue in issues do
		visit(issue, 0, false, {})
	end
	return out, tree
end

-- The List View's rows top to bottom: every column's issues nested, groups in board order.
function M.list(cols: { Column }): { any }
	local out: { any } = {}
	for _, col in cols do
		for _, issue in (M.nest(col.issues)) do
			table.insert(out, issue)
		end
	end
	return out
end

-- State types whose sub-issues count as done: canceled ones too, as nothing is left to do on them.
local CLOSED = { completed = true, canceled = true, duplicate = true }

-- An issue's sub-issue progress: done and total (0 without sub-issues; Linear sends up to 50).
function M.progress(issue: any): (number, number)
	local c = issue.children
	local nodes = if type(c) == "table" and type(c.nodes) == "table" then c.nodes else {}
	local done = 0
	for _, n in nodes do
		if type(n.state) == "table" and CLOSED[n.state.type] then
			done += 1
		end
	end
	return done, #nodes
end

-- The ids of `list` from `a` to `b` inclusive, in list order either way (a Shift-click range);
-- just `b` when `a` is not in the list, nothing when `b` is not.
function M.range(list: { any }, a: string, b: string): { string }
	local ia: number?, ib: number? = nil, nil
	for i, x in list do
		if x.id == a then
			ia = i
		end
		if x.id == b then
			ib = i
		end
	end
	if not ib then
		return {}
	elseif not ia then
		return { b }
	end
	local out: { string } = {}
	for i = math.min(ia, ib), math.max(ia, ib) do
		table.insert(out, list[i].id)
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

-- The board's pane title while it asks the window half to add a workspace: blocks cannot reach
-- the keychain or open prompts, so the window watches board titles for this one.
M.ADD_TITLE = "Linear · adding a workspace…"

-- The board's pane title while it asks the window half to start an omp chat on the issue in kv
-- `linear-todo.start`: only the window can open agents.
M.START_TITLE = "Linear · starting an omp chat…"

-- "Send to chat": the board asks the window half for the open chats (it answers with
-- `{act = "chats"}`), then to send kv `linear-todo.send` ({pane, label, prompt}) to one of them.
M.CHATS_TITLE = "Linear · listing chats…"
M.SEND_TITLE = "Linear · sending to a chat…"

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

-- The issue fields an issue template's `templateData` sets, read defensively. `descData`:
-- its `descriptionData` already decoded when Linear sent it as a JSON string.
function M.templateFields(data: any, descData: any?): { [string]: any }
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
		-- A copy: decoded JSON is read-only.
		local ids: { string } = {}
		for _, id in data.labelIds do
			table.insert(ids, id)
		end
		out.labelIds = ids
	end
	out.description = if type(data.description) == "string" then data.description else M.markdown(descData or data.descriptionData)
	return out
end

-- `t` plus `days`, as Linear's YYYY-MM-DD; `t` is a `*t` date table.
function M.addDays(t: any, days: number): string
	return os.date("%Y-%m-%d", os.time({ year = t.year, month = t.month, day = t.day + days, hour = 12 })) :: string
end

function M.isDate(s: string): boolean
	return string.match(s, "^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

function M.rewritePrompt(title: string, description: string, teamKey: string): string
	local desc = if string.match(description, "%S") then description else "(empty)"
	return "Rewrite the description of a Linear issue for team " .. teamKey .. ". Keep every fact, link, name and code snippet; invent nothing.\n"
		.. "Make it clear and well structured Markdown: a one-line summary, then short sections (## headings) or bullet lists where they help, and an acceptance checklist (- [ ]) when the text implies one.\n"
		.. "Reply with the new description only: no preamble, no title line, no closing remarks, not wrapped in a code fence.\n\n"
		.. "Title: " .. title .. "\n\nCurrent description:\n" .. desc
end

-- The model's reply as a description: trimmed, one wrapping code fence removed; nil when empty.
function M.cleanRewrite(out: string): string?
	local s = string.match(out, "^%s*(.-)%s*$") or ""
	local inner = string.match(s, "^```%w*\n(.-)\n```$")
	if inner and not string.find(inner, "\n```", 1, true) then
		s = string.match(inner, "^%s*(.-)%s*$") or ""
	end
	return if s == "" then nil else s
end

-- The workflow closing every Start and Send to chat message; `plan` is what to write ("the plan", "ONE plan covering all of them").
local function brief(plan: string): string
	return "How to work this:\n"
		.. "1. Load the `grill-with-docs` skill (skill://grill-with-docs): read the relevant code, then interrogate me about the approach. Note the decisions for the docs it keeps, and write them once I approve the plan.\n"
		.. "2. Load the `show-me` skill (skill://show-me) to show me the approach visually, then write " .. plan .. ". Do not implement anything until I approve the plan.\n"
		.. "3. Once approved, orchestrate: split the work into independent slices and delegate them to subagents, in parallel where they do not depend on each other. Verify each slice's result as it lands. Do the work on a branch and open a PR.\n"
		.. "4. Before merging, have reviewer subagents review the PR and fix what they find. Then load the `visual-pr` skill (skill://visual-pr) for the PR, and merge it.\n\n"
		.. "At any step, as soon as you see the work is very complicated or needs human QA, stop, tell me why, and wait for my go-ahead. Never merge such work until I say so."
end

-- URL, State, Priority, Assignee and Labels of `issue`, one "- " line each; unset ones are left out.
local function startFacts(issue: any, stateName: string?): string
	local lines = { "- URL: " .. tostring(issue.url) }
	if stateName then
		table.insert(lines, "- State: " .. stateName)
	end
	for _, p in M.PRIORITIES do
		if p.value == issue.priority and p.value ~= 0 then
			table.insert(lines, "- Priority: " .. p.label)
		end
	end
	local a = issue.assignee
	if type(a) == "table" and a.name then
		table.insert(lines, "- Assignee: " .. a.name)
	end
	local labels = {}
	for _, l in (if type(issue.labels) == "table" and type(issue.labels.nodes) == "table" then issue.labels.nodes else {}) do
		table.insert(labels, l.name)
	end
	if #labels > 0 then
		table.insert(lines, "- Labels: " .. table.concat(labels, ", "))
	end
	return table.concat(lines, "\n") .. "\n"
end

local function startDescription(description: string?): string
	return if description == nil
		then "(the description could not be loaded; read it in Linear)"
		elseif string.match(description, "%S") then description
		else "(no description)"
end

-- One issue's facts and description: the body of a single-issue message (the lead line names it).
local function issueBody(issue: any, stateName: string?, description: string?): string
	return startFacts(issue, stateName) .. "\n## Description\n\n" .. startDescription(description)
end

-- The first message of an omp chat started on `issue`; `description` nil means it could not be loaded.
function M.startPrompt(issue: any, title: string, stateName: string?, description: string?): string
	return "Start working on Linear issue " .. issue.identifier .. ": " .. title .. ".\n\n"
		.. issueBody(issue, stateName, description) .. "\n\n"
		.. brief("the plan")
end

-- One issue of a multi-issue message; `description` nil means it could not be loaded.
export type StartEntry = { issue: any, title: string, stateName: string?, description: string? }

-- "TES-4, TES-11" and one "## TES-4: title" section per entry, each ending in a blank line.
local function sections(entries: { StartEntry }): (string, string)
	local idents, parts = {}, {}
	for _, e in entries do
		table.insert(idents, e.issue.identifier)
		table.insert(parts, "## " .. e.issue.identifier .. ": " .. e.title .. "\n\n"
			.. startFacts(e.issue, e.stateName) .. "\n"
			.. "### Description\n\n" .. startDescription(e.description) .. "\n\n")
	end
	return table.concat(idents, ", "), table.concat(parts)
end

-- The first message of one omp chat started on all of `entries`, in their order.
function M.startPromptMany(entries: { StartEntry }): string
	local idents, parts = sections(entries)
	return "Start working on these " .. #entries .. " Linear issues together: " .. idents .. ".\n\n"
		.. parts
		.. brief("ONE plan covering all of them")
end

-- "Send to chat": `entries` handed to an open chat, with the same workflow as Start.
function M.contextPrompt(entries: { StartEntry }): string
	if #entries == 1 then
		local e = entries[1]
		return "Here is Linear issue " .. e.issue.identifier .. ": " .. e.title .. ".\n\n"
			.. issueBody(e.issue, e.stateName, e.description) .. "\n\n"
			.. brief("the plan")
	end
	local idents, parts = sections(entries)
	return "Here are " .. #entries .. " Linear issues: " .. idents .. ".\n\n" .. parts .. brief("ONE plan covering all of them")
end

-- Agents with their own tile icon in Tern's tab list; others get the generic agent tile.
local AGENT_TILES = { omp = true, claude = true, codex = true, hermes = true }

-- A "Send to chat" target as Tern's tab list shows it: the tab's name, else the pane title (the
-- program's name, e.g. "omp", when the chat is untitled), else the cwd's last folder; `meta` is that
-- folder, the model (without its provider) and the agent's state; `icon` the program's tile icon.
function M.chatRow(tabName: string?, title: string, cwd: string, command: string?, model: string?, agentState: string): { label: string, meta: string, icon: string }
	local program = string.match(command or "", "^%s*\"?([^\"%s]+)") or ""
	program = string.lower((string.gsub(string.match(program, "[^/\\]+$") or "", "%.exe$", "")))
	local dir = (string.gsub(cwd, "[/\\]+$", ""))
	dir = string.match(dir, "[^/\\]+$") or cwd
	local label = if tabName and tabName ~= "" then tabName elseif title ~= "" then title elseif program ~= "" then program else dir
	local parts = if dir ~= "" then { dir } else {}
	if model and model ~= "" then
		table.insert(parts, string.match(model, "[^/]+$") or model)
	end
	table.insert(parts, (string.gsub(agentState, "_input$", "")))
	return { label = label, meta = table.concat(parts, " · "), icon = if AGENT_TILES[program] then "tile-" .. program else "tile-agent" }
end

-- Issue view ------------------------------------------------------------------

-- Seconds since the epoch of Linear's "2026-10-22T08:15:00.000Z" (UTC); nil when not one.
function M.epoch(iso: any): number?
	if type(iso) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, s = string.match(iso, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
	if not y then
		return nil
	end
	-- Days from the civil date (Howard Hinnant's algorithm), so the local time zone never enters.
	local yy, m = tonumber(y) :: number, tonumber(mo) :: number
	if m <= 2 then
		yy -= 1
	end
	local era = yy // 400
	local yoe = yy - era * 400
	local doy = (153 * ((m + 9) % 12) + 2) // 5 + (tonumber(d) :: number) - 1
	local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
	return days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(s) :: number)
end

local AGO_UNITS: { { secs: number, suffix: string } } = {
	{ secs = 365 * 86400, suffix = "y" },
	{ secs = 30 * 86400, suffix = "mo" },
	{ secs = 86400, suffix = "d" },
	{ secs = 3600, suffix = "h" },
	{ secs = 60, suffix = "m" },
}

-- Linear's activity times: "just now", "5m ago", "2h ago", "3d ago", "4mo ago", "2y ago"; "" when
-- `iso` is not a time. `now` is seconds since the epoch.
function M.ago(iso: any, now: number): string
	local t = M.epoch(iso)
	if not t then
		return ""
	end
	local s = math.max(now - t, 0)
	for _, unit in AGO_UNITS do
		if s >= unit.secs then
			return math.floor(s / unit.secs) .. unit.suffix .. " ago"
		end
	end
	return "just now"
end

-- A relation change in Linear's history: `type` is "a" (added) or "r" (removed), then the
-- relation's letter. "ar" (added related) is confirmed against Linear; the other letters follow
-- the same pattern unconfirmed, and an unknown one still says added/removed.
local RELATION_NAMES: { [string]: string } = { r = "related issue", b = "blocking issue", d = "duplicate", s = "similar issue" }

function M.relationVerb(code: any): string
	local op, rel = string.match(if type(code) == "string" then code else "", "^([ar])(%a)$")
	if not op then
		return "changed a relation with"
	end
	return (if op == "a" then "added " else "removed ") .. (RELATION_NAMES[rel :: string] or "a relation with")
end

-- One line of the issue view's activity: `who` did `text` at `at` (Linear's ISO time); a State
-- change carries the new State's type, a relation change the other issue, a comment itself.
export type Entry = { at: string, kind: "created" | "state" | "relation" | "comment", who: string, text: string, stateType: string?, ident: string?, title: string?, comment: any? }

local function listOf(v: any): { any }
	return if type(v) == "table" then v else {}
end

local function nameOf(user: any, bot: any, fallback: string): string
	if type(user) == "table" and type(user.name) == "string" then
		return user.name
	elseif type(bot) == "table" and type(bot.name) == "string" then
		return bot.name
	end
	return fallback
end

-- The activity of `info` (Linear.detail's answer) oldest first: the creation, State changes,
-- relation changes and comments; equal times keep that order. Malformed entries are skipped.
function M.timeline(info: any): { Entry }
	local out: { Entry } = {}
	if type(info.createdAt) == "string" then
		table.insert(out, { at = info.createdAt, kind = "created", who = nameOf(info.creator, nil, "Someone"), text = "created the issue" })
	end
	local titles: { [string]: string } = {}
	for _, r in listOf(info.related) do
		local other = r.issue
		if type(other) == "table" and type(other.identifier) == "string" and type(other.title) == "string" then
			titles[other.identifier] = other.title
		end
	end
	for _, h in listOf(info.history) do
		if type(h) ~= "table" or type(h.createdAt) ~= "string" then
			continue
		end
		local who = nameOf(h.actor, h.botActor, "Linear")
		local from, to = h.fromState, h.toState
		if type(from) == "table" and type(to) == "table" and type(from.name) == "string" and type(to.name) == "string" then
			table.insert(out, { at = h.createdAt, kind = "state", who = who, text = "moved from " .. from.name .. " to " .. to.name, stateType = if type(to.type) == "string" then to.type else nil })
		end
		for _, rc in listOf(h.relationChanges) do
			if type(rc) == "table" and type(rc.identifier) == "string" then
				table.insert(out, { at = h.createdAt, kind = "relation", who = who, text = M.relationVerb(rc.type), ident = rc.identifier, title = titles[rc.identifier] })
			end
		end
	end
	for _, c in listOf(info.comments) do
		if type(c) == "table" and type(c.createdAt) == "string" then
			table.insert(out, { at = c.createdAt, kind = "comment", who = nameOf(c.user, c.botActor, "Linear"), text = "", comment = c })
		end
	end
	local order: { [Entry]: number } = {}
	for i, e in out do
		order[e] = i
	end
	table.sort(out, function(a: Entry, b: Entry): boolean
		if a.at ~= b.at then
			return a.at < b.at
		end
		return order[a] < order[b]
	end)
	return out
end

return M
