--!strict
-- linear-todo window half: commands, keychain and the workspaces (one Linear API key plus a
-- team each). Injects the keys into board blocks (secrets are window-only), which then poll
-- and edit Linear.

local Linear = require("./linear")
local Model = require("./model")
local Selftest = require("./selftest")

local P = "linear-todo."
local GROUP = "Linear"
local ICON = "check"
local BLOCK = "linear-todo.board"
local NO_SETUP = "No Linear workspace yet"

-- One Linear workspace (organization), the team its board shows, and whose key it holds.
type Workspace = { orgId: string, orgName: string, orgUrlKey: string, viewerId: string, teamId: string, teamKey: string }

-- Helpers ---------------------------------------------------------------

local function nowSec(): number
	local ok, t = pcall(os.time)
	if ok and type(t) == "number" then
		return t
	end
	return math.floor(tern.now() / 1000)
end

local function kvGet(key: string): any
	local ok, value = pcall(tern.kv.get, key)
	return if ok then value else nil
end

local function kvSet(key: string, value: any): boolean
	local ok = pcall(tern.kv.set, key, value)
	return ok
end

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

-- Keychain account `plugin.linear-todo.key.<orgId>`: each workspace has its own key.
local function secretName(orgId: string): string
	return "key." .. orgId
end

local function valid(w: any): boolean
	return type(w) == "table" and type(w.orgId) == "string" and type(w.teamId) == "string"
end

local function workspaces(): { Workspace }
	local out: { Workspace } = {}
	local list = kvGet(P .. "workspaces")
	if type(list) == "table" then
		for _, w in list do
			if valid(w) then
				table.insert(out, w)
			end
		end
	end
	return out
end

-- The workspace the board shows (kv `setup`, which the host half reads).
local function active(): Workspace?
	local s = kvGet(P .. "setup")
	return if valid(s) then s else nil
end

local function label(w: Workspace): string
	return w.orgName .. " · " .. w.teamKey
end

local function interval(): number
	local v = kvGet(P .. "interval")
	if type(v) == "number" and v >= 30 then
		return v
	end
	return 60
end

local function agoText(s: number): string
	if s < 60 then
		return math.max(0, s) .. "s ago"
	elseif s < 3600 then
		return math.floor(s / 60) .. "m ago"
	elseif s < 86400 then
		return math.floor(s / 3600) .. "h ago"
	end
	return math.floor(s / 86400) .. "d ago"
end

-- Board blocks -----------------------------------------------------------

-- `list`: a `cx.session:panes()` result already read.
local function boardPanes(cx: WindowCx, list: { PaneInfo }?): { number }
	local out: { number } = {}
	for _, p in list or cx.session:panes() do
		if p.block == BLOCK then
			table.insert(out, p.pane)
		end
	end
	return out
end

local function send(cx: WindowCx, panes: { number }, ev: { [string]: any })
	for _, pane in panes do
		cx.session:event(pane, ev)
	end
end

-- kv `links`: Issue id → the pane of the omp chat started for or sent that Issue. Copied key by
-- key: stored tables may be read-only.
local function links(): { [string]: number }
	local out: { [string]: number } = {}
	local stored = kvGet(P .. "links")
	if type(stored) == "table" then
		for id, pane in stored do
			if type(id) == "string" and type(pane) == "number" then
				out[id] = pane
			end
		end
	end
	return out
end

local lastSig, lastSent = "", 0

-- Sends the boards each linked Issue's chat ({issue, pane, state, cwd?}, by Issue id) when it
-- changed, 4 s passed or `force`; drops links whose pane is gone. Kept to panes, agents and the
-- board events as it runs in a timer (50 ms budget); callers pcall it.
local function pushAgents(cx: WindowCx, force: boolean?)
	local all = cx.session:panes()
	local boards = boardPanes(cx, all)
	if #boards == 0 then
		return
	end
	local map = links()
	local rows: { [number]: AgentBlock } = {}
	for _, a in cx.agents:list() do
		rows[a.pane] = a
	end
	local alive: { [number]: boolean } = {}
	for _, p in all do
		alive[p.pane] = true
	end
	local list: { { [string]: any } } = {}
	local pruned = false
	for id, pane in map do
		local a = rows[pane]
		if a then
			table.insert(list, { issue = id, pane = pane, state = a.state, cwd = if type(a.cwd) == "string" and a.cwd ~= "" then a.cwd else nil })
		elseif alive[pane] then
			table.insert(list, { issue = id, pane = pane, state = "exited" })
		else
			map[id], pruned = nil, true
		end
	end
	if pruned then
		kvSet(P .. "links", map)
	end
	table.sort(list, function(x, y)
		return x.issue < y.issue
	end)
	local parts: { string } = {}
	for _, r in list do
		table.insert(parts, r.issue .. ":" .. r.pane .. ":" .. tostring(r.state) .. ":" .. (r.cwd or ""))
	end
	local sig, now = table.concat(parts, "|"), tern.now()
	if force or sig ~= lastSig or now - lastSent >= 4000 then
		lastSig, lastSent = sig, now
		send(cx, boards, { ev = "action", act = "agents", agents = tern.json.array(list) })
	end
end

local sampling = false

-- Once per window VM: every second, the linked chats' states for the boards' Tasks View. Errors
-- are swallowed so the timer always re-arms.
local function sample()
	if sampling then
		return
	end
	sampling = true
	local function tick(cx: WindowCx?)
		if cx then
			pcall(pushAgents, cx)
		end
		tern.timer(1000, tick)
	end
	tern.timer(1000, tick)
end

-- Hands every workspace's key to every board block, so its switcher needs no round trip. The
-- keys never leave this VM except as the block's in-memory event payload.
local function inject(cx: WindowCx)
	local s = active()
	local panes = boardPanes(cx)
	if not s then
		-- While 0.5's setup awaits its upgrade the board keeps what it shows.
		if kvGet(P .. "legacy") == nil then
			send(cx, panes, { ev = "action", act = "key", value = "" })
		end
		return
	end
	if #panes == 0 then
		return
	end
	local list = workspaces()
	local keys: { [string]: string } = {}
	local function step(i: number, cx2: WindowCx)
		local w = list[i]
		if not w then
			-- Re-read: the board may have switched workspace while the keychain answered.
			local cur = active()
			local key = cur and keys[cur.orgId]
			if not cur or not key then
				-- A workspace newer than this read gets its own inject.
				if cur and cur.orgId == s.orgId then
					cx2:toast("error", "Missing Linear API key for " .. cur.orgName, "Add the workspace again")
					send(cx2, boardPanes(cx2), { ev = "action", act = "nokey" })
				end
				return
			end
			send(cx2, boardPanes(cx2), { ev = "action", act = "key", value = cur.teamId, key = key, keys = keys })
			return
		end
		tern.secrets.get(secretName(w.orgId)):next(function(key, err, cx3)
			if not cx3 then
				return
			end
			if not err and type(key) == "string" and key ~= "" then
				keys[w.orgId] = key
			end
			step(i + 1, cx3)
		end)
	end
	step(1, cx)
end

-- Makes `w` the board's workspace and hands the boards its key.
local function activate(cx: WindowCx, w: Workspace)
	if not kvSet(P .. "setup", w) then
		cx:toast("error", "Could not switch the Linear workspace")
		return
	end
	inject(cx)
end

-- Setup -------------------------------------------------------------------

-- Continues a picker/prompt in its fresh cx; errors become toasts.
local function ask(aw: Awaitable<any>, fn: (value: any, cx: WindowCx) -> ())
	aw:next(function(value, err, cx)
		if not cx then
			return
		end
		if err then
			cx:toast("error", "Linear", err)
			return
		end
		local ok, perr = pcall(fn, value, cx)
		if not ok then
			cx:toast("error", "Linear: internal error", tostring(perr))
		end
	end)
end

-- Runs a GraphQL call and continues only on success; failures toast `title`.
local function query(key: string, q: string, title: string, fn: (data: any, cx: WindowCx) -> ())
	Linear.call(key, q, nil, function(data, err, cx)
		if not cx then
			return
		end
		if err then
			cx:toast("error", title, err)
			return
		end
		local ok, perr = pcall(fn, data, cx)
		if not ok then
			cx:toast("error", "Linear: internal error", tostring(perr))
		end
	end)
end

-- Stores the key and the workspace (replacing an earlier one of the same organization), then
-- makes it the board's.
local function save(cx: WindowCx, key: string, viewer: any, team: any)
	local org = viewer.organization
	tern.secrets.set(secretName(org.id), key):next(function(_, err, cx)
		if not cx then
			return
		end
		if err then
			cx:toast("error", "Could not update the keychain", err)
			return
		end
		local w: Workspace = { orgId = org.id, orgName = org.name, orgUrlKey = org.urlKey, viewerId = viewer.id, teamId = team.id, teamKey = team.key }
		local list = workspaces()
		local placed = false
		for i, other in list do
			if other.orgId == w.orgId then
				list[i], placed = w, true
			end
		end
		if not placed then
			table.insert(list, w)
		end
		if not kvSet(P .. "workspaces", tern.json.array(list)) then
			cx:toast("error", "Could not save the Linear workspace")
			return
		end
		cx:toast("success", "Linear: " .. org.name .. " · " .. team.key .. " " .. team.name)
		activate(cx, w)
	end)
end

-- Asks for a team key until it names a team `key` can see; dismissing the prompt stops.
local function askTeam(cx: WindowCx, key: string, viewer: any, prefill: string?)
	query(key, Linear.TEAMS, "Could not load teams", function(data, cx)
		local teams = (data.teams and data.teams.nodes) or {}
		if #teams == 0 then
			cx:toast("error", "No teams visible to this key")
			return
		end
		local function prompt(cx: WindowCx, value: string?)
			ask(cx:prompt({ value = value, placeholder = "Team key, e.g. ENG", icon = "users" }), function(input, cx)
				if type(input) ~= "string" then
					return
				end
				local want = string.upper(trim(input))
				if want == "" then
					return
				end
				local keys: { string } = {}
				for _, t in teams do
					if string.upper(t.key) == want then
						save(cx, key, viewer, t)
						return
					end
					table.insert(keys, t.key)
				end
				table.sort(keys)
				cx:toast("error", "No team " .. want, "Teams: " .. table.concat(keys, ", "))
				prompt(cx, want)
			end)
		end
		prompt(cx, prefill)
	end)
end

-- Adds a workspace from a pasted key; a key of a known workspace replaces its key and team.
local function addWorkspace(cx: WindowCx)
	ask(cx:prompt({ placeholder = "Linear personal API key (lin_api_…)", icon = "key" }), function(input, cx)
		if type(input) ~= "string" then
			return
		end
		local key = trim(input)
		if key == "" then
			return
		end
		query(key, Linear.VIEWER, "Key rejected", function(data, cx)
			local known: string? = nil
			for _, w in workspaces() do
				if w.orgId == data.viewer.organization.id then
					known = w.teamKey
				end
			end
			askTeam(cx, key, data.viewer, known)
		end)
	end)
end

local function switchWorkspace(cx: WindowCx)
	local list = workspaces()
	if #list == 0 then
		cx:toast("info", NO_SETUP, "Run Linear: add workspace")
		return
	end
	local cur = active()
	local items: { PickItem } = {}
	for _, w in list do
		table.insert(items, { label = label(w), detail = w.orgUrlKey, current = cur ~= nil and cur.orgId == w.orgId, ws = w })
	end
	ask(cx:pick({ items = items, placeholder = "Linear workspace", icon = ICON }), function(item, cx)
		if item then
			activate(cx, item.ws)
		end
	end)
end

-- Upgrade from 0.5 (one key `key`, a Setup without its organization) -------------

local upgrading = false

-- Files 0.5's key under its organization. The old team is first parked in kv `legacy`, so
-- neither a failed attempt (retried on the next window start) nor a workspace added
-- meanwhile loses it; nothing old is deleted before the new entries are stored.
local function upgrade(cx: WindowCx)
	local s = kvGet(P .. "setup")
	if type(s) == "table" and type(s.teamId) == "string" and not valid(s) then
		kvSet(P .. "legacy", { teamId = s.teamId, teamKey = s.teamKey })
	end
	local legacy = kvGet(P .. "legacy")
	if upgrading or type(legacy) ~= "table" or type(legacy.teamId) ~= "string" then
		return
	end
	upgrading = true
	local function fail(cx: WindowCx?, title: string, sub: string?)
		upgrading = false
		if cx then
			cx:toast("error", title, sub)
		end
	end
	tern.secrets.get("key"):next(function(key, err, cx)
		if err or type(key) ~= "string" or key == "" then
			-- No old key: nothing to carry over.
			kvSet(P .. "legacy", nil)
			upgrading = false
			if cx then
				inject(cx)
			end
			return
		end
		Linear.call(key, Linear.VIEWER, nil, function(data, qerr, cx)
			if qerr or type(data) ~= "table" or type(data.viewer) ~= "table" then
				fail(cx, "Linear Taskboard: could not upgrade the stored key", qerr)
				return
			end
			local org = data.viewer.organization
			tern.secrets.set(secretName(org.id), key):next(function(_, serr, cx)
				if serr or not cx then
					fail(cx, "Could not update the keychain", serr)
					return
				end
				local w: Workspace = { orgId = org.id, orgName = org.name, orgUrlKey = org.urlKey, viewerId = data.viewer.id, teamId = legacy.teamId, teamKey = legacy.teamKey }
				-- Merge into the list as it is now; a workspace added meanwhile wins over the old one.
				local list = workspaces()
				local known = false
				for _, other in list do
					if other.orgId == w.orgId then
						known = true
					end
				end
				if not known then
					table.insert(list, w)
				end
				if not kvSet(P .. "workspaces", tern.json.array(list)) or (not active() and not kvSet(P .. "setup", w)) then
					fail(cx, "Could not save the Linear workspace")
					return
				end
				kvSet(P .. "legacy", nil)
				kvSet(P .. "cache", nil)
				tern.secrets.set("key", nil)
				upgrading = false
				inject(cx)
			end)
		end)
	end)
end

-- "Send to chat" targets: Carly, then every open agent chat ({pane, label, meta, icon, state}),
-- named as Tern's tab list names them (Model.chatRow).
local function chatList(cx: WindowCx): { { [string]: any } }
	local tabNames: { [number]: string } = {}
	for _, t in cx.session:tabs() do
		tabNames[t.id] = t.name or ""
	end
	local panes: { [number]: PaneInfo } = {}
	for _, p in cx.session:panes() do
		panes[p.pane] = p
	end
	local out: { { [string]: any } } = { { pane = "carly", label = "Carly", icon = "tile-carly" } }
	-- Unknown optional fields are tern.json.null.
	local function str(v: any): string?
		return if type(v) == "string" then v else nil
	end
	local ok, agents = pcall(cx.agents.list, cx.agents)
	if not ok then
		return out
	end
	for _, a in agents :: { AgentBlock } do
		if a.state ~= "exited" then
			local p = panes[a.pane]
			local row: { [string]: any } = Model.chatRow(p and p.tab and tabNames[p.tab], if p then p.title else "", str(a.cwd) or "", str(a.command), str(a.model), a.state)
			row.pane, row.state = a.pane, a.state
			table.insert(out, row)
		end
	end
	return out
end

-- Puts `prompt` into chat `pane` (a pane id, or "carly") and shows it; false when it failed.
local function sendTo(cx: WindowCx, pane: number | string, label: string, prompt: string, quiet: boolean?): boolean
	local ok, err = pcall(function()
		if pane == "carly" then
			cx:ask_carly(prompt)
		else
			cx.agents:ask(pane :: number, prompt)
		end
	end)
	if not ok then
		cx:toast("error", "Could not send to " .. label, tostring(err))
		return false
	end
	-- Carly's own panel opens on ask_carly; an agent pane needs revealing.
	if pane ~= "carly" and not quiet then
		pcall(function()
			cx.layout:focus(pane :: number)
		end)
		cx:toast("success", "Sent to " .. label)
	end
	return true
end

-- Stores the Issue → chat links (kv `links`) and tells the boards at once.
local function link(cx: WindowCx, map: { [string]: number })
	kvSet(P .. "links", map)
	pcall(pushAgents, cx, true)
end

-- The board's "Add workspace…", "Start", "Send to chat" and a linked chat's focus: it sets its
-- title to one of Model's *_TITLE sentinels, the window takes that as the request and
-- acknowledges it (the title reverts), then runs the key prompt, opens an omp chat per kv
-- `start` item, lists the open chats, sends kv `send` to one of them, or focuses kv `focus`.
tern.on("title", function(ev: TitleEvent, cx: WindowCx)
	local t = ev.title
	if t ~= Model.ADD_TITLE and t ~= Model.START_TITLE and t ~= Model.CHATS_TITLE and t ~= Model.SEND_TITLE and t ~= Model.FOCUS_TITLE then
		return
	end
	local panes = boardPanes(cx)
	if not table.find(panes, ev.pane) then
		return
	end
	if t == Model.ADD_TITLE then
		send(cx, panes, { ev = "action", act = "ws-added" })
		addWorkspace(cx)
		return
	elseif t == Model.CHATS_TITLE then
		send(cx, panes, { ev = "action", act = "chats", chats = chatList(cx) })
		return
	elseif t == Model.SEND_TITLE then
		send(cx, panes, { ev = "action", act = "sent" })
		local s = kvGet(P .. "send")
		kvSet(P .. "send", nil)
		if type(s) == "table" and type(s.prompt) == "string" and (type(s.pane) == "number" or s.pane == "carly") then
			if sendTo(cx, s.pane, tostring(s.label), s.prompt, s.quiet == true) and type(s.pane) == "number" and type(s.ids) == "table" then
				local map = links()
				for _, id in s.ids do
					if type(id) == "string" then
						map[id] = s.pane
					end
				end
				link(cx, map)
			end
		end
		return
	elseif t == Model.FOCUS_TITLE then
		send(cx, panes, { ev = "action", act = "focused" })
		local pane = kvGet(P .. "focus")
		kvSet(P .. "focus", nil)
		if type(pane) == "number" and not pcall(cx.layout.focus, cx.layout, pane) then
			cx:toast("error", "That chat is closed")
		end
		return
	end
	send(cx, panes, { ev = "action", act = "started" })
	local items = kvGet(P .. "start")
	kvSet(P .. "start", nil)
	if type(items) ~= "table" then
		return
	end
	local boardCwd = "~"
	for _, p in cx.session:panes() do
		if p.pane == ev.pane and p.cwd and p.cwd ~= "" then
			boardCwd = p.cwd
		end
	end
	local map = links()
	local started = false
	-- Each in its own tab, not a split of the board's tab, so it shows in the tab list.
	for _, item in items do
		if type(item) == "table" and type(item.prompt) == "string" and type(item.issueId) == "string" then
			local cwd = if type(item.cwd) == "string" and item.cwd ~= "" then item.cwd else boardCwd
			local command = Model.startCommand(tern.plugin.dir, item.model, item.thinking)
			local ok, pane = pcall(cx.agents.start, cx.agents, { prompt = item.prompt, cwd = cwd, command = command, how = "tab" })
			if not ok then
				cx:toast("error", "Could not start omp", tostring(pane))
				break
			end
			map[item.issueId], started = pane, true
		end
	end
	if started then
		link(cx, map)
	end
end)

local function start(cx: WindowCx)
	upgrade(cx)
	inject(cx)
	sample()
end

tern.on("window_start", start)

-- Reloading into an existing window does not deliver window_start.
tern.timer(300, function(cx)
	if cx then
		start(cx)
	end
end)

-- Commands ----------------------------------------------------------------

local function changeInterval(cx: WindowCx)
	ask(cx:prompt({ value = tostring(interval()), placeholder = "Poll interval in seconds (≥ 30)", icon = "clock" }), function(input, cx)
		if type(input) ~= "string" then
			return
		end
		local n = tonumber(trim(input))
		if not n or n ~= math.floor(n) or n < 30 then
			cx:toast("error", "Interval must be ≥ 30 seconds")
			return
		end
		kvSet(P .. "interval", n)
		cx:toast("success", "Linear sync every " .. n .. " s")
	end)
end

local function slotsText(n: number): string
	return n .. (if n == 1 then " slot" else " slots")
end

local function toggleAuto(cx: WindowCx)
	local a = Model.autoSettings(kvGet(P .. "auto"))
	a.on = not a.on
	kvSet(P .. "auto", { on = a.on, max = a.max })
	cx:toast("success", if a.on then "Auto-start on · " .. slotsText(a.max) else "Auto-start off")
	send(cx, boardPanes(cx), { ev = "action", act = "auto-changed" })
end

local function changeSlots(cx: WindowCx)
	local a = Model.autoSettings(kvGet(P .. "auto"))
	local hint = "Chats auto-start may run at once (1–" .. Model.AUTO_MAX .. ")"
	ask(cx:prompt({ value = tostring(a.max), placeholder = hint, icon = "clock" }), function(input, cx)
		if type(input) ~= "string" then
			return
		end
		local n = tonumber(trim(input))
		if not n or n ~= math.floor(n) or n < 1 or n > Model.AUTO_MAX then
			cx:toast("error", "Slots must be 1–" .. Model.AUTO_MAX)
			return
		end
		kvSet(P .. "auto", { on = a.on, max = n })
		cx:toast("success", "Auto-start " .. slotsText(n))
		send(cx, boardPanes(cx), { ev = "action", act = "auto-changed" })
	end)
end

local function cleanup(cx: WindowCx)
	local panes = boardPanes(cx)
	if #panes == 0 then
		cx:toast("info", "Open the board first: Linear: open board")
		return
	end
	cx.session:event(panes[1], { ev = "action", act = "cleanup" })
	pcall(cx.layout.focus, cx.layout, panes[1])
end

local function openBoard(cx: WindowCx)
	local panes = boardPanes(cx)
	if #panes > 0 then
		inject(cx)
		cx.session:event(panes[1], { ev = "action", act = "sync" })
		cx:toast("info", "Linear board is already open")
		return
	end
	local pane = cx:new_block(BLOCK, {}, "beside")
	if not pane then
		cx:toast("error", "Could not open the Linear board")
		return
	end
	inject(cx)
	-- The block may not accept events until it finished init.
	tern.timer(1000, function(cx2)
		if cx2 then
			inject(cx2)
		end
	end)
	tern.timer(3000, function(cx2)
		if cx2 then
			inject(cx2)
		end
	end)
end

local function syncNow(cx: WindowCx)
	local panes = boardPanes(cx)
	if #panes == 0 then
		cx:toast("info", "Open the board first: Linear: open board")
		return
	end
	send(cx, panes, { ev = "action", act = "sync" })
end

local function status(cx: WindowCx)
	local s = active()
	if not s then
		cx:toast("info", NO_SETUP, "Run Linear: add workspace")
		return
	end
	local st = kvGet(P .. "status")
	if type(st) ~= "table" or type(st.at) ~= "number" then
		cx:toast("info", "Linear · " .. label(s) .. " · never synced")
		return
	end
	local title = "Linear · " .. label(s) .. " · " .. (if st.ok then "OK" else "FAILED") .. " " .. agoText(nowSec() - st.at)
	local sub = (st.issues or 0) .. " issues" .. (if st.error then " · " .. st.error else "")
	cx:toast(if st.ok then "success" else "error", title, sub)
end

local function selftest(cx: WindowCx)
	local passed, failure = Selftest.run()
	kvSet(P .. "selftest", failure or "ok")
	if failure then
		cx:toast("error", "selftest failed", failure)
	else
		cx:toast("success", "selftest: " .. passed .. " passed")
	end
end

tern.command({ id = "open", title = "Linear: open board", group = GROUP, icon = ICON, run = openBoard })
tern.command({ id = "now", title = "Linear: sync now", group = GROUP, icon = ICON, run = syncNow })
tern.command({ id = "add", title = "Linear: add workspace", group = GROUP, icon = ICON, run = addWorkspace })
tern.command({ id = "switch", title = "Linear: switch workspace", group = GROUP, icon = ICON, run = switchWorkspace })
tern.command({ id = "interval", title = "Linear: poll interval", group = GROUP, icon = ICON, run = changeInterval })
tern.command({ id = "status", title = "Linear: status", group = GROUP, icon = ICON, run = status })
tern.command({ id = "selftest", title = "Linear: self-test", group = GROUP, icon = ICON, run = selftest })
tern.command({ id = "auto", title = "Linear: auto-start on/off", group = GROUP, icon = ICON, run = toggleAuto })
tern.command({ id = "slots", title = "Linear: auto-start slots", group = GROUP, icon = ICON, run = changeSlots })
tern.command({ id = "cleanup", title = "Linear: clean up worktrees", group = GROUP, icon = ICON, run = cleanup })
