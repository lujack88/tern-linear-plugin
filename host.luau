--!strict
-- The Linear board block: every Issue of one team, one column per workflow State, shown as a
-- Kanban or a List View. Every edit writes to Linear at once (optimistic overlay, then
-- reconcile) with one-step undo.
-- The API key arrives from the window half and lives in memory only: never saved, kv'd or logged.

local Linear = require("./linear")
local Model = require("./model")
local Field = require("./field")
local Create = require("./create")
local Detail = require("./detail")

local ui = tern.ui
local ROLE = "linear-todo."
local UNDO_MS = 10000
local PRIO_NAME = { [0] = "No priority", "Urgent", "High", "Medium", "Low" }

type Overlay = Model.Overlay
type Column = Model.Column
type ViewName = "kanban" | "list"
type Edit = { stateId: string, issueId: string, field: Field.Field }
type Undo = { label: string, at: number, revert: () -> () }
type State = {
	cx: BlockCx,
	-- Bumped when the team changes or the key is withdrawn: callbacks of an older gen are dropped.
	gen: number,
	-- Bumped whenever the poll chain restarts (also on a new key for the same team).
	poll: number,
	-- Successful writes so far; a fetch that saw one land meanwhile is stale and is redone.
	edits: number,
	-- Fetches started, and the newest one whose answer was applied.
	fetchSeq: number,
	fetchApplied: number,
	teamId: string?,
	key: string?,
	issues: { any },
	states: { any },
	fetchedAt: number?,
	loading: boolean,
	error: string?,
	failures: number,
	overlay: { [string]: Overlay },
	sel: string?,
	lift: string?,
	dropState: string?,
	confirm: string?,
	edit: Edit?,
	undo: Undo?,
	creating: { [string]: { stateId: string, title: string } },
	-- The open "New issue" modal, and the choices it offers (fetched when it opens).
	draft: Create.Draft?,
	-- A modal closed without creating (Esc or a click outside): reopened as it was, like Linear's draft.
	kept: Create.Draft?,
	meta: any?,
	-- Every workspace's API key by organization id (in memory only), and whether the header's
	-- workspace switcher is open.
	keys: { [string]: string },
	switcher: boolean,
	-- "Add workspace…" was picked: the title asks the window half to run its key prompt.
	adding: boolean,
	-- "Start" was clicked: the title asks the window half to open an omp chat on kv `linear-todo.start`.
	starting: boolean,
	-- The issue opened from the board (Linear's issue view), drawn instead of the board.
	detail: Detail.Detail?,
	view: ViewName,
	mine: boolean,
	-- Collapsed columns / List groups by State id (remembered in kv).
	folded: { [string]: boolean },
}

local function nowSec(): number
	local ok, t = pcall(os.time)
	if ok and type(t) == "number" then
		return t
	end
	return math.floor(tern.now() / 1000)
end

local function alive(pane: number): boolean
	local ok, panes = pcall(tern.pane.list)
	if not ok then
		return true
	end
	for _, p in panes do
		if p.pane == pane then
			return true
		end
	end
	return false
end

-- kv raises on read/write errors; the board must not stop syncing over one (the window half guards the same way).
local function kvGet(key: string): any
	local ok, value = pcall(tern.kv.get, key)
	return if ok then value else nil
end

local function kvSet(key: string, value: any)
	pcall(tern.kv.set, key, value)
end

-- The Setup written by the window half, read fresh from kv.
local function setupOf(): any
	local s = kvGet("linear-todo.setup")
	return if type(s) == "table" and type(s.teamId) == "string" then s else nil
end

-- Every workspace the window half added, in the order they were added.
local function workspaces(): { any }
	local out = {}
	local list = kvGet("linear-todo.workspaces")
	for _, w in (if type(list) == "table" then list else {}) do
		if type(w) == "table" and type(w.orgId) == "string" and type(w.teamId) == "string" then
			table.insert(out, w)
		end
	end
	return out
end

local function find(state: State, id: string?): (any, number?)
	if not id then
		return nil, nil
	end
	for i, issue in state.issues do
		if issue.id == id then
			return issue, i
		end
	end
	return nil, nil
end

local function upsert(state: State, issue: any)
	local _, i = find(state, issue.id)
	if i then
		state.issues[i] = issue
	else
		table.insert(state.issues, issue)
	end
end

local function remove(state: State, id: string)
	local _, i = find(state, id)
	if i then
		table.remove(state.issues, i)
	end
end

local function saveCache(state: State)
	if state.teamId then
		kvSet("linear-todo.cache." .. state.teamId, {
			teamId = state.teamId,
			states = tern.json.array(state.states),
			issues = tern.json.array(state.issues),
		})
	end
end

-- The cached issues and States of `teamId` (one cache per team, so switching workspaces paints at once).
local function cached(teamId: string): ({ any }, { any })
	local c = kvGet("linear-todo.cache." .. teamId)
	if type(c) == "table" and c.teamId == teamId and type(c.issues) == "table" and type(c.states) == "table" then
		return c.issues, c.states
	end
	return {}, {}
end

-- Drops everything tied to the shown issues (on a team change or disconnect).
local function resetBoard(state: State)
	state.overlay, state.creating, state.draft, state.kept, state.meta, state.detail = {}, {}, nil, nil, nil, nil
	state.sel, state.lift, state.dropState, state.confirm, state.edit, state.undo = nil, nil, nil, nil, nil, nil
	state.error, state.failures, state.loading, state.fetchedAt = nil, 0, false, nil
end

local function columnsOf(state: State): { Column }
	local s = if state.mine then setupOf() else nil
	return Model.columns(state.issues, state.states, state.overlay, { mine = s and s.viewerId })
end

-- The State an issue is shown in, overlay included.
local function stateIdOf(state: State, id: string?): string?
	local issue = find(state, id)
	return if issue then Model.effective(issue, state.overlay) else nil
end

local function visible(cols: { Column }, id: string?): boolean
	for _, col in cols do
		for _, issue in col.issues do
			if issue.id == id then
				return true
			end
		end
	end
	return false
end

-- Sync ----------------------------------------------------------------------

-- `after` runs once the fetch finished (not when a newer gen superseded it).
local function fetch(state: State, manual: boolean, after: (() -> ())?)
	local key, teamId = state.key, state.teamId
	if not key or not teamId then
		state.error = "No workspace — run Linear: add workspace"
		state.cx:render()
		return
	end
	state.loading = true
	state.cx:render()
	local g, edits = state.gen, state.edits
	state.fetchSeq += 1
	local seq = state.fetchSeq
	Linear.fetchBoard(key, teamId, function(issues: { any }?, states: { any }?, err: string?)
		if g ~= state.gen or not alive(state.cx.pane) then
			return
		end
		if issues and state.edits ~= edits then
			-- A write landed while this fetch ran, so its pages may predate it: fetch again.
			fetch(state, manual, after)
			return
		end
		if issues and states and seq < state.fetchApplied then
			-- A fetch started later already answered; this older snapshot would undo it.
		elseif issues and states then
			state.fetchApplied = seq
			state.issues, state.states, state.fetchedAt, state.error, state.failures = issues, states, nowSec(), nil, 0
			saveCache(state)
			kvSet("linear-todo.status", { at = nowSec(), ok = true, issues = #issues })
			if not find(state, state.sel) then
				state.sel = nil
			end
			if not find(state, state.lift) then
				state.lift, state.dropState = nil, nil
			end
			if manual then
				state.cx:toast("success", "Linear synced", #issues .. " issues")
			end
		else
			local msg = err or "unknown error"
			local prev = state.error
			state.error = msg
			state.failures += 1
			kvSet("linear-todo.status", { at = nowSec(), ok = false, error = msg, issues = #state.issues })
			if manual or msg ~= prev then
				state.cx:toast("error", "Linear sync failed", msg)
			end
		end
		state.loading = false
		state.cx:render()
		if after then
			after()
		end
	end)
end

local schedule: (state: State, p: number) -> ()

-- Shows `teamId` with `key` and (re)starts its poll. A new team clears the board; a new key for
-- the same team only restarts the poll, so writes in flight still land on this board.
local function connect(state: State, teamId: string, key: string?)
	if teamId == state.teamId and key == state.key then
		return
	end
	if teamId ~= state.teamId then
		state.teamId = teamId
		state.issues, state.states = cached(teamId)
		resetBoard(state)
		state.gen += 1
	end
	state.key = key
	state.poll += 1
	local p = state.poll
	fetch(state, false, function()
		schedule(state, p)
	end)
end

schedule = function(state: State, p: number)
	local iv = kvGet("linear-todo.interval")
	if type(iv) ~= "number" or iv < 30 then
		iv = 60
	end
	local delay = if state.failures > 0 and Linear.retryable(state.error) then math.min(iv * 2 ^ state.failures, 600) else iv
	tern.timer(delay * 1000, function()
		if p == state.poll and alive(state.cx.pane) and state.key then
			-- The next delay is computed after this fetch, so backoff sees its failure.
			fetch(state, false, function()
				schedule(state, p)
			end)
		end
	end)
end

-- Shows workspace `orgId` (a no-op for the one shown), with the key the window half handed over.
local function switchTo(state: State, orgId: string)
	local s = setupOf()
	if s and s.orgId == orgId then
		return
	end
	for _, w in workspaces() do
		if w.orgId == orgId then
			local key = state.keys[orgId]
			if not key then
				state.cx:toast("error", "No API key for " .. tostring(w.orgName), "Add the workspace again from this menu")
				return
			end
			kvSet("linear-todo.setup", w)
			connect(state, w.teamId, key)
			return
		end
	end
end

-- Mutations -----------------------------------------------------------------

-- Offers `revert` for UNDO_MS; the bar hides itself on the re-render after that.
local function offer(state: State, label: string, revert: () -> ())
	local u: Undo = { label = label, at = tern.now(), revert = revert }
	state.undo = u
	tern.timer(UNDO_MS + 500, function()
		if state.undo == u and alive(state.cx.pane) then
			state.cx:render()
		end
	end)
end

-- Optimistic update: shows `ov` now, writes `input`, then takes Linear's answer.
-- `ov.gone` removes the issue on success; `done` runs after a success, `failed` after a refusal.
local function push(state: State, id: string, ov: Overlay, input: any, verb: string, done: ((issue: any) -> ())?, failed: (() -> ())?)
	local key = state.key
	if not key then
		return
	end
	local g = state.gen
	state.overlay[id] = ov
	state.cx:render()
	Linear.update(key, id, input, function(issue: any?, err: string?)
		if g ~= state.gen or not alive(state.cx.pane) then
			return
		end
		if state.overlay[id] == ov then
			state.overlay[id] = nil
		end
		if not issue then
			state.cx:toast("error", verb .. " failed", err)
			if failed then
				failed()
			end
		else
			if ov.gone then
				remove(state, id)
			else
				upsert(state, issue)
			end
			state.edits += 1
			saveCache(state)
			if done then
				done(issue)
			end
		end
		state.cx:render()
	end)
end

local function move(state: State, id: string, stateId: string)
	local issue = find(state, id)
	local target = Model.stateById(state.states, stateId)
	if not issue or not target or Model.effective(issue, state.overlay) == stateId then
		return
	end
	local ident, prevId = issue.identifier, issue.state.id
	push(state, id, { stateId = stateId }, { stateId = stateId }, "Move", function()
		offer(state, "Moved " .. ident .. " to " .. target.name, function()
			push(state, id, { stateId = prevId }, { stateId = prevId }, "Undo")
		end)
	end)
end

local function rename(state: State, id: string, text: string)
	local title = string.match(text, "^%s*(.-)%s*$") or ""
	local issue = find(state, id)
	if not issue or title == "" then
		return
	end
	local _, shown = Model.effective(issue, state.overlay)
	if title == shown then
		return
	end
	local ident, prev = issue.identifier, issue.title
	push(state, id, { title = title }, { title = title }, "Rename", function()
		offer(state, "Renamed " .. ident, function()
			push(state, id, { title = prev }, { title = prev }, "Undo")
		end)
	end)
end

local function cancel(state: State, id: string)
	local issue = find(state, id)
	if not issue then
		return
	end
	local cancelId = Model.cancelState(state.states)
	if not cancelId then
		state.cx:toast("error", "Cancel failed", "This team has no canceled state")
		return
	end
	local ident, prevId = issue.identifier, issue.state.id
	push(state, id, { gone = true }, { stateId = cancelId }, "Cancel", function()
		offer(state, "Canceled " .. ident, function()
			-- The issue left state.issues; push's success upserts it back.
			push(state, id, { stateId = prevId }, { stateId = prevId }, "Undo")
		end)
	end)
end

-- Editing -------------------------------------------------------------------

-- The node path of a column's item list, from the main region root.
local function listPath(state: State, stateId: string): string
	return "main." .. (if state.view == "list" then "rows" else "board") .. "." .. stateId .. ".list"
end

local function fieldPath(state: State, e: Edit): string
	return listPath(state, stateIdOf(state, e.issueId) or e.stateId) .. "." .. e.issueId .. ".title"
end

local function startEdit(state: State, e: Edit)
	state.edit, state.confirm = e, nil
	state.cx:frame({ { "focus", fieldPath(state, e) .. "_" .. e.field.rev } })
end

local function endEdit(state: State, refocus: boolean)
	state.edit = nil
	if refocus then
		state.cx:frame({ { "focus", tern.json.null } })
	end
end

local function commitEdit(state: State)
	local e = state.edit
	if not e then
		return
	end
	endEdit(state, true)
	rename(state, e.issueId, e.field.text)
end

local function startRename(state: State, id: string)
	local issue = find(state, id)
	if not issue then
		return
	end
	local stateId, title = Model.effective(issue, state.overlay)
	if not stateId then
		return
	end
	local f = Field.new(title, false, 255)
	f.anchor, f.cur = 0, Field.length_of(title)
	state.sel = id
	startEdit(state, { stateId = stateId, issueId = id, field = f })
end

-- Create modal --------------------------------------------------------------

local function ctxOf(state: State): Create.Ctx
	local s = setupOf()
	return {
		states = state.states,
		meta = state.meta,
		teamKey = if s then s.teamKey else "",
		teamId = state.teamId or "",
		viewerId = s and s.viewerId,
	}
end

-- Fetches the property choices (people, labels, projects, cycles, templates) for the modal and
-- the issue view; the last ones stay shown meanwhile.
local function loadMeta(state: State)
	local key, teamId = state.key, state.teamId
	if not key or not teamId then
		return
	end
	local g = state.gen
	Linear.meta(key, teamId, function(meta: any?, err: string?)
		if g ~= state.gen or not alive(state.cx.pane) then
			return
		end
		if meta then
			state.meta = meta
		elseif state.draft or state.detail then
			state.cx:toast("error", "Could not load issue options", err)
		end
		state.cx:render()
	end)
end

-- Opens the "New issue" modal in `stateId`; `template` opens the template list first.
-- The choices are fetched on every open (templates and people change), the last ones shown meanwhile.
local function openDraft(state: State, stateId: string, template: boolean)
	local s = setupOf()
	local key, teamId = state.key, state.teamId
	if not s or not key or not teamId or s.teamId ~= teamId then
		state.cx:toast("error", "No Linear workspace yet", "Run Linear: add workspace")
		return
	end
	if not Model.stateById(state.states, stateId) then
		return
	end
	if state.edit then
		endEdit(state, false)
	end
	-- A kept draft comes back whole (its own State included).
	local d = state.kept or Create.new(stateId, if state.mine then s.viewerId else nil)
	state.kept, d.pop, d.error = nil, nil, nil
	state.draft, state.lift, state.dropState, state.confirm, state.switcher = d, nil, nil, nil, false
	if template then
		Create.openPop(d, "template", state.cx)
	else
		Create.focus(d, "title", state.cx)
	end
	loadMeta(state)
end

-- Closes the modal; `keep` holds on to what was typed for the next open.
local function closeDraft(state: State, keep: boolean)
	local d = state.draft
	state.draft = nil
	if keep and d and (d.title.text ~= "" or d.desc.text ~= "") then
		state.kept = d
	end
	state.cx:frame({ { "focus", tern.json.null } })
end

-- Sends the modal's issue. The modal closes at once (or clears for "Create more"); a failure
-- reopens it with the text intact when it was closed.
local function submitDraft(state: State)
	local d = state.draft
	local key, teamId = state.key, state.teamId
	if not d or not key or not teamId then
		return
	end
	local input, err = Create.input(d, teamId)
	if not input then
		d.error = err
		return
	end
	local cancelId = Model.cancelState(state.states)
	local g = state.gen
	-- Node keys join into dotted ids, so the placeholder key must not contain ".".
	local tmp = string.format("new-%d", math.floor(tern.now() * 1000))
	state.creating[tmp] = { stateId = d.stateId, title = input.title }
	if d.more then
		Create.again(d, state.cx)
	else
		closeDraft(state, false)
	end
	Linear.create(key, input, function(issue: any?, cerr: string?)
		state.creating[tmp] = nil
		if not alive(state.cx.pane) then
			return
		end
		if not issue then
			-- Said even after a team change, so a lost draft never goes unmentioned.
			state.cx:toast("error", "Create failed: " .. input.title, cerr)
			if g == state.gen and not state.draft then
				d.error = cerr
				state.draft = d
			end
		elseif g == state.gen then
			upsert(state, issue)
			state.edits += 1
			saveCache(state)
			local newId = issue.id
			if cancelId then
				offer(state, "Created " .. issue.identifier, function()
					push(state, newId, { gone = true }, { stateId = cancelId }, "Undo")
				end)
			end
		end
		state.cx:render()
	end)
end

-- Rewrites the draft's description with omp's default model; never logs the prompt or reply.
local function rewriteDraft(state: State, d: Create.Draft)
	if d.rewriting then
		return
	end
	if not string.find(d.title.text, "%S") and not string.find(d.desc.text, "%S") then
		d.error = "Write a title or description first"
		return
	end
	local sent = d.desc.text
	d.rewriting, d.error = true, nil
	state.cx:render()
	local argv = {
		"omp", "-p", "--no-session", "--no-tools", "--no-skills", "--no-rules", "--no-extensions",
		Model.rewritePrompt(d.title.text, sent, (setupOf() or {}).teamKey or ""),
	}
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = 120000 }, function(res: any)
		d.rewriting = false
		-- A late reply for a draft that was created or cleared meanwhile is dropped.
		if not alive(state.cx.pane) or (d ~= state.draft and d ~= state.kept) then
			return
		end
		local text = Model.cleanRewrite(res.stdout or "")
		if res.timed_out then
			d.error = "Rewrite timed out"
		elseif res.status ~= 0 then
			local line = string.match(string.match(res.stderr or "", "^%s*(.-)%s*$") or "", "^[^\r\n]+")
			d.error = "Rewrite failed: " .. (line or ("omp exited " .. tostring(res.status)))
		elseif not text then
			d.error = "Rewrite returned nothing"
		elseif d.desc.text ~= sent then
			d.error = "Description changed while rewriting; try again"
		else
			d.beforeRewrite, d.rewritten = sent, text
			Field.reset(d.desc, text)
		end
		state.cx:render()
	end)
	if not ok then
		d.rewriting = false
		d.error = "Could not start omp: " .. tostring(err)
		state.cx:render()
	end
end

-- The undo step, while it is still offered.
local function fresh(state: State): Undo?
	local u = state.undo
	return if u and tern.now() - u.at <= UNDO_MS then u else nil
end

-- Issue view ----------------------------------------------------------------

-- A write that keeps whatever the issue's pending overlay already shows (a move, a rename).
local function overlayFor(state: State, id: string): Overlay
	local base = state.overlay[id]
	return if base then table.clone(base) else {}
end

-- Opens issue `id` in place of the board and fetches its description and comments.
local function openDetail(state: State, id: string)
	local issue = find(state, id)
	local key = state.key
	if not issue or not key then
		return
	end
	if state.edit then
		endEdit(state, false)
	end
	local stateId, title = Model.effective(issue, state.overlay)
	local dt = Detail.new(issue, stateId or issue.state.id, title)
	state.detail, state.sel, state.lift, state.dropState, state.confirm, state.switcher = dt, id, nil, nil, nil, false
	state.cx:frame({ { "focus", tern.json.null } })
	if not state.meta then
		loadMeta(state)
	end
	local g = state.gen
	Linear.detail(key, id, function(info: any?, err: string?)
		if g ~= state.gen or state.detail ~= dt or not alive(state.cx.pane) then
			return
		end
		if info then
			dt.info = info
		else
			dt.error = err
		end
		state.cx:render()
	end)
end

local function closeDetail(state: State)
	state.detail = nil
	state.cx:frame({ { "focus", tern.json.null } })
end

-- Hands issue `id` to the window half, which opens an omp chat on it (Model.START_TITLE).
local function startAgent(state: State, id: string)
	local issue = find(state, id)
	if not issue then
		return
	end
	local key = state.key
	if not key or not setupOf() then
		state.cx:toast("error", "No Linear workspace yet", "Run Linear: add workspace")
		return
	end
	local stateId, title = Model.effective(issue, state.overlay)
	local st = Model.stateById(state.states, stateId)
	local function go(description: string?)
		kvSet("linear-todo.start", Model.startPrompt(issue, title, st and st.name, description))
		state.starting = true
		state.cx:render()
	end
	state.cx:toast("info", "Starting " .. issue.identifier .. " in omp…")
	local dt = state.detail
	if dt and dt.id == id and dt.info then
		go(if type(dt.info.description) == "string" then dt.info.description else "")
		return
	end
	Linear.detail(key, id, function(info: any?)
		if alive(state.cx.pane) then
			go(if not info then nil elseif type(info.description) == "string" then info.description else "")
		end
	end)
end

-- j / k: the next or previous issue in the board's own order.
local function stepDetail(state: State, dt: Detail.Detail, dir: number)
	local list = Model.list(columnsOf(state))
	for i, issue in list do
		if issue.id == dt.id then
			local to = list[i + dir]
			if to then
				openDetail(state, to.id)
			end
			return
		end
	end
end

local function saveDescription(state: State, dt: Detail.Detail)
	local info = dt.info
	local issue = find(state, dt.id)
	if not info or not issue then
		return
	end
	local text, prev = dt.d.desc.text, if type(info.description) == "string" then info.description else ""
	if text == prev then
		return
	end
	local id, ident = dt.id, issue.identifier
	info.description = text
	push(state, id, overlayFor(state, id), { description = text }, "Description", function()
		offer(state, "Edited the description of " .. ident, function()
			push(state, id, overlayFor(state, id), { description = prev }, "Undo", function()
				info.description = prev
			end)
		end)
	end, function()
		-- Keep what was typed: reopen the editor on it, so leaving it again retries the save.
		info.description = prev
		if state.detail == dt and dt.d.desc.text == text and not dt.d.focus then
			dt.commenting = false
			Create.focus(dt.d, "desc", state.cx)
		end
	end)
end

local function sendComment(state: State, dt: Detail.Detail)
	local key = state.key
	local body = string.match(dt.comment.text, "^%s*(.-)%s*$") or ""
	if not key or body == "" or dt.sending then
		return
	end
	local sent = dt.comment.text
	dt.sending = true
	local g = state.gen
	Linear.comment(key, dt.id, body, function(comment: any?, err: string?)
		dt.sending = false
		if g ~= state.gen or not alive(state.cx.pane) then
			return
		end
		if not comment then
			state.cx:toast("error", "Comment failed", err)
		else
			if dt.info and type(dt.info.comments) == "table" then
				table.insert(dt.info.comments, comment)
			end
			-- Text typed while sending is kept.
			if dt.comment.text == sent then
				Field.reset(dt.comment, "")
			end
		end
		state.cx:render()
	end)
	state.cx:render()
end

-- Writes what a property list changed: a State through `move`, the rest as one update with undo.
local function saveProps(state: State, dt: Detail.Detail, before: any)
	local after = Detail.snapshot(dt.d)
	local issue = find(state, dt.id)
	if not issue then
		return
	end
	if after.stateId ~= before.stateId then
		move(state, dt.id, after.stateId)
	end
	local input, back = Detail.changes(before, after)
	local labels = issue.labels
	if input and input.labelIds and type(labels) == "table" and type(labels.pageInfo) == "table" and labels.pageInfo.hasNextPage then
		-- The board knows only the first 50 labels; writing the list would drop the rest.
		input.labelIds = nil
		local b: any = back
		b.labelIds = nil
		state.cx:toast("error", "Edit this issue's labels in Linear", "It has more than 50, more than the board loads")
		if next(input) == nil then
			input = nil
		end
	end
	if input then
		local id, ident = dt.id, issue.identifier
		push(state, id, overlayFor(state, id), input, "Update", function()
			offer(state, "Updated " .. ident, function()
				push(state, id, overlayFor(state, id), back, "Undo")
			end)
		end)
	end
end

-- Carries out what the issue view asked for.
local function runDetail(state: State, dt: Detail.Detail, intent: Detail.Intent)
	if intent == "close" then
		closeDetail(state)
	elseif intent == "title" then
		rename(state, dt.id, dt.d.title.text)
	elseif intent == "desc" then
		saveDescription(state, dt)
	elseif intent == "comment" then
		sendComment(state, dt)
	elseif intent == "next" or intent == "prev" then
		stepDetail(state, dt, if intent == "next" then 1 else -1)
	elseif intent == "undo" then
		local u = fresh(state)
		if u then
			state.undo = nil
			u.revert()
		end
	elseif intent == "web" then
		local issue = find(state, dt.id)
		if issue and type(issue.url) == "string" then
			state.cx:open(issue.url)
		end
	elseif intent == "start" then
		startAgent(state, dt.id)
	end
end

-- Actions -------------------------------------------------------------------

local function act(state: State, name: string, value: string, cx: BlockCx)
	local d = state.draft
	if d and string.sub(name, 1, 3) == "cm-" then
		local r = Create.act(d, name, value, ctxOf(state), cx)
		if r == "submit" then
			submitDraft(state)
		elseif r == "close" then
			closeDraft(state, true)
		elseif r == "rewrite" then
			rewriteDraft(state, d)
		end
		return
	end
	local dt = state.detail
	if dt and (string.sub(name, 1, 3) == "cm-" or string.sub(name, 1, 3) == "dt-") then
		local before, left = Detail.snapshot(dt.d), dt.d.focus
		local r = Detail.act(dt, name, value, ctxOf(state), cx)
		-- A click that takes the caret out of the title or description (or closes the view)
		-- saves that field first; `refresh` would otherwise put Linear's value back.
		if left and (dt.d.focus ~= left or r == "close") then
			runDetail(state, dt, left)
		end
		if type(r) == "string" then
			runDetail(state, dt, r)
		end
		saveProps(state, dt, before)
		return
	end
	if name ~= "ws-pop" then
		state.switcher = false
	end
	if name == "ws-pop" then
		state.switcher = not state.switcher
		return
	elseif name == "ws-add" then
		-- Storing a key needs the keychain, which only the window half reaches. Blocks can't call
		-- it, so the title says Model.ADD_TITLE and the window answers with its key prompt.
		state.adding = true
		return
	elseif name == "ws-added" then
		state.adding = false
		return
	elseif name == "started" then
		state.starting = false
		return
	elseif name == "start" then
		startAgent(state, value)
		return
	elseif name == "ws" then
		switchTo(state, value)
		return
	end
	if state.lift and name ~= "sel" and name ~= "lift" and name ~= "drop" then
		state.lift, state.dropState = nil, nil
	end
	if name == "sel" then
		if state.lift then
			local to, from = stateIdOf(state, value), stateIdOf(state, state.lift)
			if to and to ~= from then
				move(state, state.lift, to)
			end
			state.lift, state.dropState = nil, nil
			return
		end
		state.confirm = nil
		openDetail(state, value)
	elseif name == "lift" then
		if state.lift == value then
			state.lift, state.dropState = nil, nil
		else
			state.lift, state.sel, state.confirm = value, value, nil
			state.dropState = stateIdOf(state, value)
		end
	elseif name == "drop" then
		local lifted = state.lift
		if lifted then
			move(state, lifted, value)
		end
		state.lift, state.dropState = nil, nil
	elseif name == "add" then
		openDraft(state, value, false)
	elseif name == "rename" then
		startRename(state, value)
	elseif name == "cancel" then
		state.sel = value
		if state.confirm == value then
			state.confirm = nil
			cancel(state, value)
		else
			state.confirm = value
		end
	elseif name == "undo" then
		local u = fresh(state)
		if u then
			state.undo = nil
			u.revert()
		end
	elseif name == "sync" then
		fetch(state, true)
	elseif name == "view" then
		if value == "kanban" or value == "list" then
			-- The field's node path depends on the View.
			state.view, state.edit = value, nil
			kvSet("linear-todo.view", value)
		end
	elseif name == "fold" then
		if state.folded[value] then
			state.folded[value] = nil
		else
			state.folded[value] = true
		end
		kvSet("linear-todo.folded", state.folded)
		return
	elseif name == "mine" then
		state.mine = not state.mine
		kvSet("linear-todo.mine", state.mine)
		local cols = columnsOf(state)
		if not visible(cols, state.sel) then
			state.sel, state.confirm = nil, nil
		end
	end
end

-- The first column from index `from` stepping `dir` that has an issue, else nil.
local function nextFilled(cols: { Column }, from: number, dir: number): Column?
	local i = from + dir
	while i >= 1 and i <= #cols do
		if #cols[i].issues > 0 then
			return cols[i]
		end
		i += dir
	end
	return nil
end

-- Where `c` creates: the selected issue's column, else the first unstarted one, else the first.
local function defaultColumn(cols: { Column }, selIdx: number?): Column?
	if selIdx then
		return cols[selIdx]
	end
	for _, col in cols do
		if col.state.type == "unstarted" then
			return col
		end
	end
	return cols[1]
end

local function onKey(state: State, k: Key, cx: BlockCx): boolean?
	local d = state.draft
	if d then
		local r = Create.key(d, k, ctxOf(state), cx)
		if r == "submit" then
			submitDraft(state)
			return true
		elseif r == "close" then
			closeDraft(state, true)
			return true
		end
		return r :: boolean
	end
	local dt = state.detail
	if dt then
		local before = Detail.snapshot(dt.d)
		local r = Detail.key(dt, k, ctxOf(state), cx)
		if type(r) == "string" then
			runDetail(state, dt, r)
		end
		saveProps(state, dt, before)
		return r ~= false
	end
	if state.switcher then
		local n = tonumber(k.name)
		if k.name == "escape" then
			state.switcher = false
			return true
		elseif n and n >= 1 and n <= 9 and not (k.ctrl or k.meta or k.alt) then
			local w = workspaces()[n]
			state.switcher = false
			if w then
				switchTo(state, w.orgId)
			end
			return true
		end
		-- The open menu takes every other key too, so nothing acts on the board behind it.
		return true
	end
	local e = state.edit
	if e then
		local what = Field.edit_key(e.field, k, cx)
		if what == "submit" then
			commitEdit(state)
		elseif what == "blur" then
			endEdit(state, true)
		elseif what == nil then
			return false
		end
		return true
	end
	local name = k.name
	local mod = k.ctrl or k.meta
	if mod and not k.alt and name == "z" then
		if not fresh(state) then
			return false
		end
		act(state, "undo", "", cx)
		return true
	end
	-- Keys skip collapsed columns and groups, as if they were empty.
	local cols: { Column } = {}
	for _, col in columnsOf(state) do
		table.insert(cols, if state.folded[col.state.id] then { state = col.state, issues = {} } else col)
	end
	local selIdx = if visible(cols, state.sel) then Model.columnIndex(cols, stateIdOf(state, state.sel)) else nil
	if k.alt and not mod and name == "c" then
		-- Linear's "create from template".
		local col = defaultColumn(cols, selIdx)
		if not col then
			return false
		end
		openDraft(state, col.state.id, true)
		return true
	end
	if mod or k.alt then
		return false
	end
	local horizontal = if name == "left" or name == "h" then -1 elseif name == "right" or name == "l" then 1 else 0
	if horizontal ~= 0 then
		if k.shift and (name == "left" or name == "right") then
			local to = if selIdx then cols[selIdx + horizontal] else nil
			if not to or not state.sel then
				return false
			end
			move(state, state.sel, to.state.id)
			return true
		end
		if state.lift then
			local at = Model.columnIndex(cols, state.dropState)
			local to = if at then cols[at + horizontal] else nil
			if not to then
				return false
			end
			state.dropState = to.state.id
			return true
		end
		local to = nextFilled(cols, selIdx or (if horizontal > 0 then 0 else #cols + 1), horizontal)
		if not to then
			return false
		end
		state.sel, state.confirm = to.issues[1].id, nil
		return true
	end
	if name == "up" or name == "k" or name == "down" or name == "j" then
		local dir = if name == "up" or name == "k" then -1 else 1
		if not selIdx then
			local to = nextFilled(cols, 0, 1)
			if not to then
				return false
			end
			state.sel, state.confirm = to.issues[1].id, nil
			return true
		end
		-- Kanban steps within the column; List runs on across the State groups.
		local seq: { any } = if state.view == "list" then Model.list(cols) else cols[selIdx].issues
		for i, issue in seq do
			if issue.id == state.sel then
				local nxt = seq[i + dir]
				if not nxt then
					return false
				end
				state.sel, state.confirm = nxt.id, nil
				return true
			end
		end
		return false
	end
	if name == "enter" then
		if state.lift then
			act(state, "drop", state.dropState or "", cx)
		elseif state.sel then
			openDetail(state, state.sel)
		else
			return false
		end
		return true
	elseif name == "space" then
		if state.lift then
			act(state, "drop", state.dropState or "", cx)
		elseif state.sel then
			act(state, "lift", state.sel, cx)
		else
			return false
		end
		return true
	elseif name == "escape" then
		if state.lift then
			state.lift, state.dropState = nil, nil
		elseif state.confirm then
			state.confirm = nil
		elseif state.sel then
			state.sel = nil
		else
			return false
		end
		return true
	elseif (name == "r" or name == "f2") and state.sel then
		act(state, "rename", state.sel, cx)
		return true
	elseif name == "c" then
		local col = defaultColumn(cols, selIdx)
		if not col then
			return false
		end
		act(state, "add", col.state.id, cx)
		return true
	elseif (name == "delete" or name == "backspace") and state.sel then
		act(state, "cancel", state.sel, cx)
		return true
	end
	return false
end

-- View ----------------------------------------------------------------------

local function el(tag: string, role: string, key: string, props: { [string]: any }?, children: { Node }?): Node
	local p: { [string]: any } = props or {}
	p.role = ROLE .. role
	p.key = key
	return ui.el(tag, p, children)
end

local function region(role: string, kids: { Node }): Node
	local n: any = ui.col(kids)
	n.p = n.p or {}
	n.p.role = ROLE .. role
	return n
end

local function flag(on: boolean): string?
	return if on then "true" else nil
end

-- A workspace's initials on a colour of its own, as Linear's workspace menu draws it.
local function wsAvatar(w: any, key: string): Node
	local sum = 0
	for i = 1, #w.orgId do
		sum += string.byte(w.orgId, i)
	end
	local colours = { "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink" }
	return el("span", "ws-avatar", key, { class = "lt-ws-avatar", attrs = { ["data-c"] = colours[sum % #colours + 1] }, text = Model.initials(w.orgName) })
end

-- Grip, rename, start and cancel: the per-issue controls of a card or row.
local function controls(state: State, id: string, into: { Node })
	local armed = state.confirm == id
	table.insert(into, el("button", "grip", "grip", {
		class = "lt-grip",
		text = "⠿",
		aria = "Move",
		title = if state.lift == id then "Cancel move" else "Pick up, then click a column",
		actions = { click = "lift=" .. id },
	}))
	table.insert(into, el("button", "act", "rename", { class = "lt-act", text = "✎", aria = "Rename", title = "Rename", actions = { click = "rename=" .. id } }))
	table.insert(into, el("button", "start", "start", { class = "lt-start", text = "▷ Start", aria = "Start in omp", title = "Start in omp", actions = { click = "start=" .. id } }))
	table.insert(into, el("button", "act", "cancel", {
		class = "lt-act lt-del",
		text = if armed then "Cancel?" else "✕",
		aria = "Cancel issue",
		title = if armed then "Click again to cancel the issue" else "Cancel issue",
		attrs = { ["data-confirm"] = flag(armed) },
		actions = { click = "cancel=" .. id },
	}))
end

local function avatar(issue: any): Node?
	local a = issue.assignee
	if type(a) ~= "table" then
		return nil
	end
	-- The full name gives Linear's two-letter initials; displayName is a one-word handle.
	return el("span", "avatar", "avatar", { class = "lt-avatar", text = Model.initials(a.name or a.displayName), title = a.name })
end

local function prio(issue: any): Node
	local pc = Model.prioClass(issue.priority)
	local bars: { Node }? = nil
	if pc ~= "p1" then
		bars = {
			el("span", "bar", "b1", { class = "lt-bar" }),
			el("span", "bar", "b2", { class = "lt-bar" }),
			el("span", "bar", "b3", { class = "lt-bar" }),
		}
	end
	return el("span", "prio", "prio", {
		class = "lt-prio",
		attrs = { ["data-p"] = pc },
		text = if pc == "p1" then "!" else nil,
		title = PRIO_NAME[tonumber(string.sub(pc, 2)) or 0],
	}, bars)
end

-- Labels, then the estimate.
local function extras(issue: any, into: { Node })
	local labels = issue.labels and issue.labels.nodes
	if type(labels) == "table" then
		for i, l in labels do
			table.insert(into, el("span", "label", "l" .. i, { class = "lt-label", attrs = { ["data-c"] = Model.labelClass(l.color) } }, {
				el("span", "dot", "dot", { class = "lt-dot" }),
				el("span", "label-name", "name", { class = "lt-label-name", text = l.name }),
			}))
		end
	end
	local est = Model.estimate(issue.estimate)
	if est then
		table.insert(into, el("span", "est", "est", { class = "lt-est", text = est, title = "Estimate" }))
	end
end

local function titleNode(state: State, issue: any, stateId: string, title: string, max: any): Node
	local e = state.edit
	if e and e.issueId == issue.id then
		return Field.node("input", { key = "title", role = ROLE .. "input" }, e.field, title, listPath(state, stateId) .. "." .. issue.id .. ".title")
	end
	return el("div", "title", "title", { class = "lt-title", text = title, max = max })
end

-- Props shared by a card and a row: selection, pending and drop marks, click and open.
local function itemProps(state: State, issue: any, class: string, dropHere: boolean): { [string]: any }
	local id = issue.id
	return {
		class = class,
		attrs = {
			["data-sel"] = flag(state.sel == id),
			["data-confirm"] = flag(state.confirm == id),
			["data-pending"] = flag(state.overlay[id] ~= nil),
			["data-drop"] = flag(dropHere),
		},
		mark = if state.lift == id then "pick" else nil,
		title = issue.url,
		actions = { click = "sel=" .. id },
	}
end

local function card(state: State, issue: any, col: Column, liftState: string?): Node
	local id = issue.id
	local _, title = Model.effective(issue, state.overlay)
	local top: { Node } = {
		el("span", "id", "id", { class = "lt-id", text = issue.identifier }),
		el("span", "spacer", "sp", { class = "lt-spacer" }),
	}
	controls(state, id, top)
	local av = avatar(issue)
	if av then
		table.insert(top, av)
	end
	local chips: { Node } = {
		prio(issue),
		el("span", "state", "state", { class = "lt-state", attrs = { ["data-type"] = col.state.type }, title = col.state.name }),
	}
	extras(issue, chips)
	return el("div", "card", id, itemProps(state, issue, "lt-card", liftState ~= nil and col.state.id ~= liftState), {
		el("div", "top", "top", { class = "lt-top" }, top),
		titleNode(state, issue, col.state.id, title, { h = "2lines" }),
		el("div", "chips", "chips", { class = "lt-chips" }, chips),
	})
end

local function row(state: State, issue: any, col: Column, liftState: string?): Node
	local id = issue.id
	local _, title = Model.effective(issue, state.overlay)
	local kids: { Node } = {
		prio(issue),
		el("span", "id", "id", { class = "lt-id", text = issue.identifier }),
		titleNode(state, issue, col.state.id, title, nil),
	}
	extras(issue, kids)
	local av = avatar(issue)
	if av then
		table.insert(kids, av)
	end
	controls(state, id, kids)
	return el("div", "row", id, itemProps(state, issue, "lt-row", liftState ~= nil and col.state.id ~= liftState), kids)
end

-- A Kanban column, or a List group when `list`: the same head, with cards or rows under it.
local function column(state: State, col: Column, liftState: string?, list: boolean): Node
	local stateId = col.state.id
	local items: { Node } = {}
	local itemClass = if list then "lt-row" else "lt-card"
	for tmp, c in state.creating do
		if c.stateId == stateId then
			table.insert(items, el("div", "card", tmp, { class = itemClass, attrs = { ["data-pending"] = "true" } }, {
				el("div", "title", "title", { class = "lt-title", text = c.title, max = { h = "2lines" } }),
				el("div", "creating", "creating", { class = "lt-creating", text = "Creating…" }),
			}))
		end
	end
	local folded = state.folded[stateId] == true
	local shown: { any } = if folded then {} else col.issues
	for _, issue in shown do
		table.insert(items, if list then row(state, issue, col, liftState) else card(state, issue, col, liftState))
	end
	if #items == 0 and not list and not folded then
		table.insert(items, el("div", "none", "empty", { class = "lt-none", text = "No issues" }))
	end
	local lifted = liftState ~= nil
	return el("div", if list then "group" else "col", stateId, {
		class = if list then "lt-group" else "lt-col",
		attrs = {
			["data-folded"] = flag(folded),
			["data-drop"] = flag(lifted and stateId ~= liftState),
			["data-target"] = flag(lifted and stateId == state.dropState),
		},
		actions = if lifted then { click = "drop=" .. stateId } else nil,
	}, {
		el("div", "col-head", "head", { class = "lt-col-head" }, {
			el("button", "fold", "fold", {
				class = "lt-fold",
				text = if folded then "▸" else "▾",
				aria = if folded then "Expand " .. col.state.name else "Collapse " .. col.state.name,
				title = if folded then "Expand" else "Collapse",
				attrs = { ["aria-expanded"] = if folded then "false" else "true" },
				actions = { click = "fold=" .. stateId },
			}),
			el("span", "state", "icon", { class = "lt-state", attrs = { ["data-type"] = col.state.type } }),
			el("span", "col-title", "label", { class = "lt-col-title", text = col.state.name }),
			el("span", "col-count", "count", { class = "lt-col-count", text = tostring(#col.issues) }),
			el("span", "spacer", "sp", { class = "lt-spacer" }),
			el("button", "add", "add", { class = "lt-add", text = "+", aria = "New issue", title = "New issue in " .. col.state.name, actions = { click = "add=" .. stateId } }),
		}),
		el("div", "list", "list", { class = if list then "lt-rows" else "lt-list" }, items),
	})
end

local function tab(state: State, name: ViewName, text: string): Node
	local on = state.view == name
	return el("button", "tab", name, { class = "lt-tab", text = text, attrs = { ["data-on"] = flag(on), ["aria-pressed"] = if on then "true" else "false" }, actions = { click = "view=" .. name } })
end

local function header(state: State, count: number): { Node }
	local s = setupOf()
	local status: Node
	if state.loading then
		status = el("span", "status", "status", { class = "lt-sync" }, { ui.node("spinner", { style = "dots" }) })
	else
		local at = state.fetchedAt
		local ok, hm = pcall(os.date, "%H:%M", at)
		status = el("span", "status", "status", { class = "lt-sync", text = if at and ok and type(hm) == "string" then "Synced " .. hm else "" })
	end
	local out: { Node } = {
		el("div", "head", "head", { class = "lt-head" }, {
			el("button", "ws", "ws", {
				class = "lt-ws lt-ws-button",
				title = "Switch workspace",
				attrs = { ["data-open"] = flag(state.switcher) },
				actions = { click = "ws-pop" },
			}, if s and s.orgName then {
				wsAvatar(s, "avatar"),
				el("span", "ws-name", "name", { class = "lt-ws-name", text = s.orgName }),
				el("span", "ws-team", "team", { class = "lt-ws-team", text = s.teamKey .. " ▾" }),
			} else { el("span", "ws-name", "name", { class = "lt-ws-name", text = if s then s.teamKey .. " ▾" else "Linear ▾" }) }),
			el("div", "tabs", "tabs", { class = "lt-tabs" }, { tab(state, "kanban", "Kanban"), tab(state, "list", "List") }),
			el("button", "mine", "mine", {
				class = "lt-tab lt-mine",
				text = "Mine",
				title = if state.mine then "Showing your issues; click for the whole team" else "Show only your issues",
				attrs = { ["data-on"] = flag(state.mine), ["aria-pressed"] = if state.mine then "true" else "false" },
				actions = { click = "mine" },
			}),
			el("span", "count", "count", { class = "lt-count", text = tostring(count) }),
			el("span", "spacer", "sp", { class = "lt-spacer" }),
			status,
			el("button", "refresh", "sync", { class = "lt-refresh", text = "↻", aria = "Sync now", title = "Sync now", actions = { click = "sync" } }),
		}),
	}
	if state.error then
		table.insert(out, el("div", "error", "error", { class = "lt-error", tone = "error", text = state.error }))
	end
	return out
end

-- The workspace dropdown under the header's workspace button: each workspace (1–9 pick
-- one while it is open), then "Add workspace…".
local function switcher(state: State): Node
	local s = setupOf()
	local rows: { Node } = { el("div", "ws-section", "title", { class = "lt-ws-section", text = "Switch workspace" }) }
	for i, w in workspaces() do
		local kids: { Node } = {
			wsAvatar(w, "avatar"),
			el("span", "pop-label", "label", { class = "lt-pop-label", text = w.orgName }),
			el("span", "pop-hint", "team", { class = "lt-pop-hint", text = w.teamKey }),
		}
		if s and s.orgId == w.orgId then
			table.insert(kids, el("span", "pop-on", "on", { class = "lt-pop-on", text = "✓" }))
		end
		if i <= 9 then
			table.insert(kids, el("span", "pop-hint", "n", { class = "lt-pop-hint lt-ws-n", text = tostring(i) }))
		end
		table.insert(rows, el("button", "pop-row", "w" .. i, { class = "lt-pop-row", actions = { click = "ws=" .. w.orgId } }, kids))
	end
	table.insert(rows, el("div", "ws-section", "more", { class = "lt-ws-section", text = "Workspaces" }))
	table.insert(rows, el("button", "pop-row", "add", { class = "lt-pop-row", actions = { click = "ws-add" } }, {
		el("span", "pop-label", "label", { class = "lt-pop-label", text = "Add workspace…" }),
	}))
	return {
		k = "overlay",
		p = { key = "switcher", role = ROLE .. "switcher", aria = "Linear workspaces", anchor = { node = "main.head.ws", side = "below" }, size = "sm" },
		c = { el("div", "pop-list", "list", { class = "lt-pop-list" }, rows) },
	} :: any
end

local function dock(state: State): Node?
	local function ident(id: string?): string
		local issue = find(state, id)
		return if issue then issue.identifier else "issue"
	end
	local kid: Node
	if state.confirm then
		local again = if state.detail then "Click Cancel issue again to cancel " else "Press Delete again to cancel "
		kid = el("div", "hint", "hint", { class = "lt-hint", text = again .. ident(state.confirm) })
	elseif state.lift then
		local target = Model.stateById(state.states, state.dropState)
		local to = if target then " to " .. target.name else ""
		kid = el("div", "hint", "hint", { class = "lt-hint", text = "Moving " .. ident(state.lift) .. to .. " — click a State or press Enter · Esc cancels" })
	else
		local u = fresh(state)
		if not u then
			return nil
		end
		kid = el("div", "undo", "undo", { class = "lt-undo" }, {
			el("span", "undo-label", "label", { class = "lt-undo-label", text = u.label }),
			el("button", "undo-btn", "btn", { class = "lt-undo-btn", text = "Undo", aria = "Undo", actions = { click = "undo" } }),
		})
	end
	return region("dock", { kid })
end

local function empty(kids: { Node }, text: string): BlockView
	table.insert(kids, el("div", "empty", "empty", { class = "lt-empty", text = text }))
	return { main = region("main", kids) }
end

local function view(state: State): BlockView
	local dt = state.detail
	local opened = dt and find(state, dt.id)
	if dt and opened then
		-- Linear's values flow into every field the caret is not in (and into the chips while
		-- no write to the issue is in flight).
		local stateId, title = Model.effective(opened, state.overlay)
		Detail.refresh(dt, opened, stateId or opened.state.id, title, state.overlay[dt.id] == nil)
		local c = ctxOf(state)
		return {
			main = region("main", Detail.view(dt, opened, c, state.confirm == dt.id)),
			dock = dock(state),
			layer = if dt.d.pop then region("layer", { Create.scrim("cm-unpop"), Create.popover(dt.d, c) }) else nil,
		}
	elseif dt then
		-- The issue left the board (canceled here or elsewhere, or moved out by a sync).
		state.detail = nil
	end
	local cols = columnsOf(state)
	local kids = header(state, #Model.list(cols))
	if not state.teamId then
		return empty(kids, "No Linear workspace yet. Run Linear: add workspace and paste a personal API key.")
	elseif not state.key then
		return empty(kids, "Connecting…")
	elseif #cols == 0 then
		return empty(kids, if state.loading then "Loading…" else "No workflow states loaded yet.")
	end
	local liftState = stateIdOf(state, state.lift)
	local list = state.view == "list"
	local nodes: { Node } = {}
	for _, col in cols do
		table.insert(nodes, column(state, col, liftState, list))
	end
	if list then
		table.insert(kids, el("div", "rows", "rows", { class = "lt-listview" }, nodes))
	else
		table.insert(kids, el("div", "board", "board", { class = "lt-board" }, nodes))
	end
	local d = state.draft
	local layer = if d then region("layer", Create.view(d, ctxOf(state)))
		elseif state.switcher then region("layer", { Create.scrim("ws-pop"), switcher(state) })
		else nil
	return { main = region("main", kids), dock = dock(state), layer = layer }
end

-- Block ---------------------------------------------------------------------

tern.block.define("board", {
	features = { "edit", "undo" },

	init = function(cx: BlockCx, _args: { string }, _saved: any): State
		local state: State = {
			cx = cx,
			gen = 0,
			poll = 0,
			edits = 0,
			fetchSeq = 0,
			fetchApplied = 0,
			issues = {},
			states = {},
			overlay = {},
			creating = {},
			keys = {},
			switcher = false,
			adding = false,
			starting = false,
			loading = false,
			failures = 0,
			view = if kvGet("linear-todo.view") == "list" then "list" else "kanban",
			mine = kvGet("linear-todo.mine") == true,
			folded = {},
		}
		-- Copied key by key: stored tables may be read-only.
		local folded = kvGet("linear-todo.folded")
		for id, on in (if type(folded) == "table" then folded else {}) do
			if on == true then
				state.folded[id] = true
			end
		end
		local s = setupOf()
		if s then
			state.teamId = s.teamId
			state.issues, state.states = cached(s.teamId)
			local st = kvGet("linear-todo.status")
			if type(st) == "table" and st.ok and type(st.at) == "number" then
				state.fetchedAt = st.at
			end
		end
		return state
	end,

	title = function(state: State): string?
		if state.adding then
			return Model.ADD_TITLE
		elseif state.starting then
			return Model.START_TITLE
		end
		local s = setupOf()
		return "Linear · " .. (if s and s.teamKey then (s.orgName or "") .. " · " .. s.teamKey else "not set up")
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		return view(state)
	end,

	key = onKey,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		local d = state.draft
		if d and (ev.ev == "edit" or ev.ev == "undo" or ev.ev == "focus") then
			local was = d.focus
			Create.event(d, ev)
			-- A click into the description editor reports focus without taking Tern's caret off
			-- the title, so a later click on the title sent nothing. Move the caret explicitly.
			if d.focus and d.focus ~= was then
				Create.focus(d, d.focus, cx)
			end
			return
		end
		local dt = state.detail
		if dt and (ev.ev == "edit" or ev.ev == "undo" or ev.ev == "focus") then
			local mine, left = Detail.event(dt, ev)
			if left then
				runDetail(state, dt, left)
			end
			-- ⌃Z/⌘Z outside the fields arrives as an id-less "undo": the board's one-step undo.
			if not mine and ev.ev == "undo" then
				act(state, "undo", "", cx)
			end
			return
		end
		local e = state.edit
		if ev.ev == "edit" or ev.ev == "undo" then
			if e and ev.id == e.field.id then
				if ev.ev == "undo" then
					Field.undo_step(e.field, false)
				else
					Field.apply_edit(e.field, ev)
				end
			elseif ev.ev == "undo" and not e then
				-- The "undo" feature turns ⌃Z/⌘Z into this event, so it never reaches `key`.
				act(state, "undo", "", cx)
			end
			return
		end
		if ev.ev == "focus" then
			if e and ev.id ~= e.field.id then
				endEdit(state, false)
			end
			return
		end
		if ev.ev ~= "action" or type(ev.act) ~= "string" then
			return
		end
		local value = if type(ev.value) == "string" then ev.value else ""
		-- From the window half: `value` is the Setup's team id, `key` the API key; never log this event.
		if ev.act == "key" then
			if value == "" then
				state.key, state.teamId, state.issues, state.states, state.keys = nil, nil, {}, {}, {}
				resetBoard(state)
				state.gen += 1
				state.poll += 1
				return
			end
			if type(ev.keys) == "table" then
				state.keys = ev.keys
			end
			connect(state, value, if type(ev.key) == "string" and ev.key ~= "" then ev.key else nil)
			return
		end
		act(state, ev.act, value, cx)
	end,
})
