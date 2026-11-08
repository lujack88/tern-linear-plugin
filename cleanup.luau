--!strict
-- Worktree clean-up: every worktree of the project's repository with whether it would be removed
-- and why (Model.cleanupVerdict), then Remove N on two clicks. Never passes --force: git refuses
-- a worktree with changes, and `branch -d` keeps a branch git does not see as merged.

local Model = require("./model")

local ui = tern.ui
local ROLE = "linear-todo."
local TIMEOUT_MS = 30000
local M = {}

export type Row = { wt: Model.Worktree, remove: boolean, reason: string, result: string? }
-- phase: "loading" | "ready" | "removing" | "done"
export type Cleanup = {
	phase: string,
	repo: string?,
	rows: { Row },
	armed: boolean,
	error: string?,
	gen: number,
	-- The folders it was opened with (a refresh searches them again), and how many worktrees git listed.
	folders: { string }?,
	total: number?,
}
export type Host = {
	render: () -> (),
	toast: (kind: string, title: string, body: string?) -> (),
	-- A linked chat on this branch is working or waiting for you.
	busy: (branch: string) -> boolean,
	-- The board pane still exists; callbacks stop when false.
	alive: () -> boolean,
}

local function trim(s: string?): string
	return string.match(s or "", "^%s*(.-)%s*$") or ""
end

-- The first non-empty stderr line of `res` (nil: the command could not start).
local function firstLine(res: any): string
	for line in string.gmatch(if res and type(res.stderr) == "string" then res.stderr else "", "[^\r\n]+") do
		local t = trim(line)
		if t ~= "" then
			return t
		end
	end
	return if res then "exit " .. tostring(res.status) else "could not run the command"
end

-- Runs `argv`; `done` gets its result, or nil when it could not start.
local function run(argv: { string }, cwd: string?, done: (res: any?) -> ())
	local ok = pcall(tern.process.run, argv, { cwd = cwd, timeout_ms = TIMEOUT_MS }, function(res: any)
		done(res)
	end)
	if not ok then
		done(nil)
	end
end

-- True while `c` is still on the run started now and the board pane exists.
local function liveOf(c: Cleanup, host: Host): () -> boolean
	local gen = c.gen
	return function()
		return c.gen == gen and host.alive()
	end
end

local function fail(c: Cleanup, host: Host, err: string)
	c.phase, c.error = "done", err
	host.render()
end

-- One worktree's facts, its three commands run at once; `done` gets them once all answered.
local function factsOf(c: Cleanup, wt: Model.Worktree, host: Host, live: () -> boolean, done: (f: Model.WorktreeFacts) -> ())
	local f: Model.WorktreeFacts = { busy = false }
	local branch = wt.branch
	-- cleanupVerdict keeps these without looking at any fact.
	if wt.main or wt.bare or wt.detached or wt.locked or wt.prunable or not branch then
		done(f)
		return
	end
	f.busy = host.busy(branch)
	local left = 3
	local function settle()
		left -= 1
		if left == 0 then
			done(f)
		end
	end
	run({ "git", "-C", wt.path, "status", "--porcelain" }, c.repo, function(res)
		if not live() then
			return
		end
		if res and res.status == 0 then
			f.dirty = string.find(res.stdout or "", "%S") ~= nil
		end
		settle()
	end)
	run({ "git", "-C", wt.path, "rev-list", "--count", "HEAD", "--not", "--remotes" }, c.repo, function(res)
		if not live() then
			return
		end
		if res and res.status == 0 then
			f.unpushed = tonumber(trim(res.stdout))
		end
		settle()
	end)
	run({ "gh", "pr", "view", branch, "--json", "state" }, c.repo, function(res)
		if not live() then
			return
		end
		if res and res.status == 0 then
			local ok, data = pcall(tern.json.decode, res.stdout or "")
			if ok and type(data) == "table" and type(data.state) == "string" then
				f.pr = data.state
			end
		elseif res and string.find(res.stderr or "", "no pull requests found", 1, true) then
			f.pr = "NONE"
		end
		settle()
	end)
end

-- Starts over: finds the repository, lists its worktrees and reads them one at a time.
function M.refresh(c: Cleanup, host: Host)
	c.gen += 1
	c.phase, c.repo, c.rows, c.armed, c.error, c.total = "loading", nil, {}, false, nil, nil
	local live = liveOf(c, host)
	local function read(wts: { Model.Worktree }, i: number)
		local wt = wts[i]
		if not wt then
			c.phase = "ready"
			host.render()
			return
		end
		factsOf(c, wt, host, live, function(f)
			local remove, reason = Model.cleanupVerdict(wt, f)
			table.insert(c.rows, { wt = wt, remove = remove, reason = reason })
			host.render()
			read(wts, i + 1)
		end)
	end
	local folders = c.folders or {}
	local function find(i: number)
		local dir = folders[i]
		if not dir then
			fail(c, host, "No git repository found. Start an issue from a project folder first.")
			return
		end
		run({ "git", "rev-parse", "--show-toplevel" }, dir, function(res)
			if not live() then
				return
			end
			local top = if res and res.status == 0 then trim(res.stdout) else ""
			if top == "" then
				find(i + 1)
				return
			end
			local repo = string.gsub(top, "\\", "/")
			c.repo = repo
			host.render()
			run({ "git", "worktree", "list", "--porcelain" }, repo, function(lr)
				if not live() then
					return
				end
				if not lr or lr.status ~= 0 then
					fail(c, host, firstLine(lr))
					return
				end
				local wts = Model.worktrees(lr.stdout or "")
				c.total = #wts
				read(wts, 1)
			end)
		end)
	end
	host.render()
	find(1)
end

function M.open(folders: { string }, host: Host): Cleanup
	local c: Cleanup = { phase = "loading", rows = {}, armed = false, gen = 0, folders = folders }
	M.refresh(c, host)
	return c
end

function M.close(c: Cleanup)
	c.gen += 1
end

local function removable(c: Cleanup): number
	local n = 0
	for _, r in c.rows do
		if r.remove then
			n += 1
		end
	end
	return n
end

-- Removes every row the verdict marked, one after another: the worktree, then its branch.
local function removeAll(c: Cleanup, host: Host)
	c.phase, c.armed = "removing", false
	host.render()
	local live = liveOf(c, host)
	local todo: { Row } = {}
	for _, r in c.rows do
		if r.remove then
			table.insert(todo, r)
		end
	end
	local removed, failed = 0, 0
	local function step(i: number)
		local r = todo[i]
		if not r then
			c.phase, c.armed = "done", false
			local text = "Removed " .. removed .. (if removed == 1 then " worktree" else " worktrees")
			host.toast(if removed == 0 then "error" else "success", if failed > 0 then text .. "; " .. failed .. " failed" else text)
			host.render()
			return
		end
		run({ "git", "worktree", "remove", r.wt.path }, c.repo, function(res)
			if not live() then
				return
			end
			if not res or res.status ~= 0 then
				-- On Windows a dev server still holding files in the folder is the usual cause.
				r.result, failed = "failed: " .. firstLine(res), failed + 1
				host.render()
				step(i + 1)
				return
			end
			removed += 1
			-- The verdict marks only worktrees on a branch.
			run({ "git", "branch", "-d", r.wt.branch :: string }, c.repo, function(br)
				if not live() then
					return
				end
				r.result = if br and br.status == 0 then "removed" else "removed; branch kept: " .. firstLine(br)
				host.render()
				step(i + 1)
			end)
		end)
	end
	step(1)
end

function M.act(c: Cleanup, name: string, host: Host): string | boolean
	if name == "wt-close" then
		return "close"
	elseif name == "wt-refresh" then
		M.refresh(c, host)
		return true
	elseif name == "wt-remove" then
		if c.phase == "ready" and removable(c) > 0 then
			if c.armed then
				removeAll(c, host)
			else
				c.armed = true
				host.render()
			end
		end
		return true
	end
	return false
end

function M.key(c: Cleanup, k: Key, host: Host): string | boolean
	if k.name == "escape" then
		return "close"
	elseif k.name == "r" and not (k.ctrl or k.meta or k.alt or k.shift) then
		M.refresh(c, host)
		return true
	end
	return false
end

-- View ------------------------------------------------------------------------------

local function el(tag: string, role: string, key: string, props: { [string]: any }?, children: { Node }?): Node
	local p: { [string]: any } = props or {}
	p.role = ROLE .. role
	p.key = key
	return ui.el(tag, p, children)
end

local function plural(n: number, word: string): string
	return n .. " " .. word .. (if n == 1 then "" else "s")
end

local function rowNode(r: Row, key: string): Node
	local wt = r.wt
	local name = wt.branch or string.match(wt.path, "([^/\\]+)[/\\]*$") or wt.path
	local text = r.result or r.reason
	return el("div", "wt-row", key, { class = "lt-wt-row" }, {
		el("span", "wt-branch", "branch", { class = "lt-wt-branch", text = name, title = name }),
		el("span", "wt-path", "path", { class = "lt-wt-path", text = wt.path, title = wt.path }),
		el("span", "wt-reason", "reason", {
			class = "lt-wt-reason",
			text = text,
			title = text,
			attrs = { ["data-failed"] = if r.result and string.sub(r.result, 1, 7) == "failed:" then "true" else nil },
		}),
	})
end

local function section(c: Cleanup, key: string, title: string, remove: boolean): Node
	local rows: { Node } = {}
	for i, r in c.rows do
		if r.remove == remove then
			table.insert(rows, rowNode(r, "r" .. i))
		end
	end
	return el("div", "wt-section", key, { class = "lt-wt-section" }, {
		el("div", "wt-heading", "title", { class = "lt-wt-heading", text = title .. " (" .. #rows .. ")" }),
		el("div", "wt-list", "list", { class = "lt-wt-list" }, rows),
	})
end

-- Children for the board's main region, in place of the board.
function M.view(c: Cleanup): { Node }
	local body: { Node } = {}
	if c.phase == "loading" or c.phase == "removing" then
		local text = if c.phase == "removing" then "Removing…"
			elseif c.total then "Reading " .. plural(c.total, "worktree") .. "…"
			else "Finding the repository…"
		table.insert(body, el("div", "wt-status", "status", { class = "lt-wt-status" }, {
			ui.node("spinner", { style = "dots" }),
			el("span", "wt-status-text", "text", { text = text }),
		}))
	end
	if c.error then
		table.insert(body, el("div", "wt-error", "error", { class = "lt-wt-error", text = c.error }))
	end
	if #c.rows > 0 then
		table.insert(body, section(c, "remove", "Will remove", true))
		table.insert(body, section(c, "keep", "Keeping", false))
	end
	local foot: { Node } = {}
	local n = removable(c)
	if c.phase == "ready" and n > 0 then
		table.insert(foot, el("button", "wt-remove", "remove", {
			class = "lt-wt-remove",
			text = if c.armed then "Click again to remove " .. n else "Remove " .. n,
			attrs = { ["data-armed"] = if c.armed then "true" else nil },
			actions = { click = "wt-remove" },
		}))
	end
	table.insert(foot, el("span", "wt-note", "note", {
		class = "lt-wt-note",
		text = "Uses git worktree remove without --force; a branch is deleted only when git agrees it is merged.",
	}))
	return {
		el("div", "head", "head", { class = "lt-head lt-wt-head" }, {
			el("span", "wt-title", "title", { class = "lt-wt-title", text = "Clean up worktrees" }),
			el("span", "wt-repo", "repo", { class = "lt-wt-repo", text = c.repo or "", title = c.repo }),
			el("span", "spacer", "sp", { class = "lt-spacer" }),
			el("button", "wt-icon", "refresh", { class = "lt-wt-icon", text = "↻", aria = "Refresh", title = "Refresh (R)", actions = { click = "wt-refresh" } }),
			el("button", "wt-icon", "close", { class = "lt-wt-icon", text = "×", aria = "Close", title = "Back to the board (Esc)", actions = { click = "wt-close" } }),
		}),
		el("div", "wt-body", "body", { class = "lt-wt-body" }, body),
		el("div", "wt-foot", "foot", { class = "lt-wt-foot" }, foot),
	}
end

return M
