--!strict
-- linear-todo window half: commands, keychain and the Setup (API key plus team). Injects the API
-- key into board blocks (secrets are window-only), which then poll and edit Linear.

local Linear = require("./linear")
local Selftest = require("./selftest")

local P = "linear-todo."
local GROUP = "Linear"
local ICON = "check"
local BLOCK = "linear-todo.board"
local SECRET = "key"
local NO_SETUP = "Linear is not set up"

type Setup = { teamId: string, teamKey: string, orgUrlKey: string, viewerId: string }

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

local function setup(): Setup?
	local s = kvGet(P .. "setup")
	return if type(s) == "table" and type(s.teamId) == "string" then s else nil
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

-- Hands the key to every board block. The key never leaves this VM except as the block's
-- in-memory event payload.
local function inject(cx: WindowCx)
	local s = setup()
	local panes = boardPanes(cx)
	if not s then
		send(cx, panes, { ev = "action", act = "key", value = "" })
		return
	end
	if #panes == 0 then
		return
	end
	tern.secrets.get(SECRET):next(function(key, err, cx2)
		if not cx2 then
			return
		end
		if err or not key or key == "" then
			cx2:toast("error", "Missing Linear API key", "Run Linear: setup")
			return
		end
		send(cx2, boardPanes(cx2), { ev = "action", act = "key", value = s.teamId, key = key })
	end)
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

-- Deletes 0.2's kv keys and keychain entries once the Setup holds the carried-over key.
local function dropOld(old: { any })
	for _, w in old do
		if type(w) == "table" and type(w.id) == "string" then
			kvSet(P .. "cache." .. w.id, nil)
			kvSet(P .. "status." .. w.id, nil)
			tern.secrets.set("key." .. w.id, nil):next(function(_, err, cx)
				if err and cx then
					cx:toast("error", "Could not remove an old Linear key from the keychain", err)
				end
			end)
		end
	end
	kvSet(P .. "workspaces", nil)
	kvSet(P .. "active", nil)
end

-- Stores the key and the Setup; a different team drops the old team's cache and status.
local function save(cx: WindowCx, key: string, viewer: any, team: any)
	tern.secrets.set(SECRET, key):next(function(_, err, cx)
		if not cx then
			return
		end
		if err then
			cx:toast("error", "Could not update the keychain", err)
			return
		end
		local prev = setup()
		local s: Setup = { teamId = team.id, teamKey = team.key, orgUrlKey = viewer.organization.urlKey, viewerId = viewer.id }
		if not kvSet(P .. "setup", s) then
			cx:toast("error", "Could not save the Linear setup")
			return
		end
		if not prev or prev.teamId ~= s.teamId then
			kvSet(P .. "cache", nil)
			kvSet(P .. "status", nil)
		end
		cx:toast("success", "Linear: " .. team.key .. " · " .. team.name)
		-- Setup supersedes 0.2's workspaces, whether it came from the migration or the command.
		local old = kvGet(P .. "workspaces")
		if type(old) == "table" then
			dropOld(old)
		end
		inject(cx)
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

local function runSetup(cx: WindowCx)
	ask(cx:prompt({ placeholder = "Linear personal API key (lin_api_…)", icon = "key" }), function(input, cx)
		if type(input) ~= "string" then
			return
		end
		local key = trim(input)
		if key == "" then
			return
		end
		query(key, Linear.VIEWER, "Key rejected", function(data, cx)
			local cur = setup()
			askTeam(cx, key, data.viewer, cur and cur.teamKey)
		end)
	end)
end

-- Migration from 0.2 (several workspaces) -----------------------------------


local migrating = false

-- Carries the active workspace's key over and asks once (per window start) for the team key.
local function migrate(cx: WindowCx)
	local old = kvGet(P .. "workspaces")
	if migrating or type(old) ~= "table" or setup() then
		return
	end
	migrating = true
	local activeId = kvGet(P .. "active")
	local active: any = old[1]
	for _, w in old do
		if type(w) == "table" and w.id == activeId then
			active = w
		end
	end
	if type(active) ~= "table" or type(active.id) ~= "string" then
		dropOld(old)
		return
	end
	tern.secrets.get("key." .. active.id):next(function(key, err, cx)
		if not cx then
			return
		end
		if err or not key or key == "" then
			cx:toast("info", "Linear Taskboard: the old key is gone", "Run Linear: setup")
			return
		end
		query(key, Linear.VIEWER, "Linear Taskboard: the stored key was rejected", function(data, cx)
			cx:toast("info", "Linear Taskboard now shows one team's board", "Confirm the team key to finish the upgrade")
			askTeam(cx, key, data.viewer, active.createTeamKey)
		end)
	end)
end

local function start(cx: WindowCx)
	migrate(cx)
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
	local s = setup()
	if not s then
		cx:toast("info", NO_SETUP, "Run Linear: setup")
		return
	end
	local st = kvGet(P .. "status")
	if type(st) ~= "table" or type(st.at) ~= "number" then
		cx:toast("info", "Linear · " .. s.teamKey .. " · never synced")
		return
	end
	local title = "Linear · " .. s.teamKey .. " · " .. (if st.ok then "OK" else "FAILED") .. " " .. agoText(nowSec() - st.at)
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
tern.command({ id = "setup", title = "Linear: setup", group = GROUP, icon = ICON, run = runSetup })
tern.command({ id = "interval", title = "Linear: poll interval", group = GROUP, icon = ICON, run = changeInterval })
tern.command({ id = "status", title = "Linear: status", group = GROUP, icon = ICON, run = status })
tern.command({ id = "selftest", title = "Linear: self-test", group = GROUP, icon = ICON, run = selftest })
