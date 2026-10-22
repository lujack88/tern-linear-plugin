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

local function boardPanes(cx: WindowCx): { number }
	local out: { number } = {}
	for _, p in cx.session:panes() do
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

-- "Send to chat" targets: Carly, then every open agent chat ({pane, label}), labelled by Model.chatLabel.
local function chatList(cx: WindowCx): { { pane: any, label: string } }
	local titles: { [number]: string } = {}
	for _, p in cx.session:panes() do
		titles[p.pane] = p.title
	end
	local out: { { pane: any, label: string } } = { { pane = "carly", label = "Carly" } }
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
			table.insert(out, { pane = a.pane, label = Model.chatLabel(titles[a.pane] or "", str(a.cwd) or "", str(a.command), str(a.model), a.state) })
		end
	end
	return out
end

-- Puts `prompt` into chat `pane` (a pane id, or "carly") and shows it.
local function sendTo(cx: WindowCx, pane: number | string, label: string, prompt: string)
	local ok, err = pcall(function()
		if pane == "carly" then
			cx:ask_carly(prompt)
		else
			cx.agents:ask(pane :: number, prompt)
		end
	end)
	if not ok then
		cx:toast("error", "Could not send to " .. label, tostring(err))
		return
	end
	-- Carly's own panel opens on ask_carly; an agent pane needs revealing.
	if pane ~= "carly" then
		pcall(function()
			cx.layout:focus(pane :: number)
		end)
		cx:toast("success", "Sent to " .. label)
	end
end

-- The board's "Add workspace…", "Start" and "Send to chat": it sets its title to one of Model's
-- *_TITLE sentinels, the window takes that as the request and acknowledges it (the title reverts),
-- then runs the key prompt, opens an omp chat on kv `start`, lists the open chats, or sends kv
-- `send` to one of them.
tern.on("title", function(ev: TitleEvent, cx: WindowCx)
	local t = ev.title
	if t ~= Model.ADD_TITLE and t ~= Model.START_TITLE and t ~= Model.CHATS_TITLE and t ~= Model.SEND_TITLE then
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
			sendTo(cx, s.pane, tostring(s.label), s.prompt)
		end
		return
	end
	send(cx, panes, { ev = "action", act = "started" })
	local prompt = kvGet(P .. "start")
	kvSet(P .. "start", nil)
	if type(prompt) ~= "string" then
		return
	end
	local cwd = "~"
	for _, p in cx.session:panes() do
		if p.pane == ev.pane and p.cwd and p.cwd ~= "" then
			cwd = p.cwd
		end
	end
	-- omp has no plan-mode flag; this overlay sets plan.defaultOnStartup for the new chat only.
	local command = 'omp --config "' .. tern.plugin.dir .. '/plan-mode.yml"'
	local ok, err = pcall(cx.agents.start, cx.agents, { prompt = prompt, cwd = cwd, command = command })
	if not ok then
		cx:toast("error", "Could not start omp", tostring(err))
	end
end)

local function start(cx: WindowCx)
	upgrade(cx)
	inject(cx)
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
