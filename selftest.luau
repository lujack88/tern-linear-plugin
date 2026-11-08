--!strict
-- In-Tern checks of model.luau (no Luau runner is installed).

local Model = require("./model")

local M = {}

local function check(cond: boolean, msg: string)
	if not cond then
		error(msg, 0)
	end
end

type IssueOpts = { title: string?, priority: number?, updatedAt: string?, assignee: string?, parent: number? }

local function issue(n: number, stateId: string, opts: IssueOpts?): any
	local o: IssueOpts = opts or {}
	return {
		id = "i" .. n,
		identifier = "ENG-" .. n,
		title = o.title or ("Issue " .. n),
		url = "https://linear.app/x/issue/ENG-" .. n,
		updatedAt = o.updatedAt or "2026-01-01T00:00:00.000Z",
		priority = o.priority,
		state = { id = stateId },
		assignee = if o.assignee then { id = o.assignee, name = o.assignee } else nil,
		parent = if o.parent then { id = "i" .. o.parent, identifier = "ENG-" .. o.parent } else nil,
	}
end

local function state(id: string, stype: string, position: number): any
	return { id = id, name = id, type = stype, position = position }
end

-- A team's workflow, deliberately out of order.
local STATES = {
	state("done", "completed", 0),
	state("review", "started", 2),
	state("todo", "unstarted", 0),
	state("x2", "canceled", 5),
	state("prog", "started", 1),
	state("dup", "duplicate", 0),
	state("x1", "canceled", 3),
	state("tri", "triage", 0),
	state("back", "backlog", 9),
}

local function ids(list: { any }, field: string): string
	local out: { string } = {}
	for _, x in list do
		table.insert(out, x[field])
	end
	return table.concat(out, ",")
end

local cases: { { name: string, fn: () -> () } } = {
	{
		name = "state order",
		fn = function()
			local order = ids(Model.visibleStates(STATES), "id")
			check(order == "back,todo,prog,review,done", "order " .. order)
			local cols = Model.columns({}, STATES, {})
			check(#cols == 5 and cols[3].state.id == "prog", "columns follow visibleStates")
		end,
	},
	{
		name = "hidden types",
		fn = function()
			local cols = Model.columns({ issue(1, "x1"), issue(2, "dup"), issue(3, "tri"), issue(4, "todo"), issue(5, "gone-state") }, STATES, {})
			local shown = ids(Model.list(cols), "identifier")
			check(shown == "ENG-4", "shown " .. shown)
		end,
	},
	{
		name = "columns grouping",
		fn = function()
			local cols = Model.columns({ issue(1, "prog"), issue(2, "review"), issue(3, "done") }, STATES, {})
			check(#cols[3].issues == 1 and cols[3].issues[1].identifier == "ENG-1", "In Progress")
			check(#cols[4].issues == 1 and cols[4].issues[1].identifier == "ENG-2", "In Review")
			check(#cols[5].issues == 1 and cols[5].issues[1].identifier == "ENG-3", "Done")
		end,
	},
	{
		name = "columns sort",
		fn = function()
			local cols = Model.columns({
				issue(1, "todo", { priority = 0, updatedAt = "2026-01-04T00:00:00.000Z" }),
				issue(2, "todo", { priority = 3, updatedAt = "2026-01-01T00:00:00.000Z" }),
				issue(3, "todo", { priority = 1, updatedAt = "2026-01-02T00:00:00.000Z" }),
				issue(4, "todo", { priority = 2, updatedAt = "2026-01-03T00:00:00.000Z" }),
				issue(5, "todo", { priority = 2, updatedAt = "2026-01-05T00:00:00.000Z" }),
				issue(6, "todo", { priority = 2, updatedAt = "2026-01-05T00:00:00.000Z" }),
			}, STATES, {})
			local order = ids(cols[2].issues, "identifier")
			check(order == "ENG-3,ENG-5,ENG-6,ENG-4,ENG-2,ENG-1", "order " .. order)
		end,
	},
	{
		name = "move to a specific State",
		fn = function()
			local issue1 = issue(1, "todo")
			local cols = Model.columns({ issue1 }, STATES, { i1 = { stateId = "review" } })
			check(#cols[2].issues == 0 and #cols[3].issues == 0, "left in Todo or landed in the first started State")
			check(cols[4].issues[1] == issue1, "not in In Review")
			check(Model.columnIndex(cols, "review") == 4 and Model.columnIndex(cols, "x1") == nil, "columnIndex")
		end,
	},
	{
		name = "overlay gone",
		fn = function()
			local cols = Model.columns({ issue(1, "todo") }, STATES, { i1 = { gone = true } })
			check(#Model.list(cols) == 0, "gone issue still shown")
			local _, _, gone = Model.effective(issue(1, "todo"), { i1 = { gone = true } })
			check(gone, "effective not gone")
		end,
	},
	{
		name = "overlay title",
		fn = function()
			local _, title = Model.effective(issue(1, "todo"), { i1 = { title = "Renamed" } })
			check(title == "Renamed", "title " .. title)
		end,
	},
	{
		name = "mine filter",
		fn = function()
			local issues = { issue(1, "todo", { assignee = "me" }), issue(2, "todo", { assignee = "you" }), issue(3, "todo") }
			check(#Model.list(Model.columns(issues, STATES, {})) == 3, "all without mine")
			local mine = ids(Model.list(Model.columns(issues, STATES, {}, { mine = "me" })), "identifier")
			check(mine == "ENG-1", "mine " .. mine)
		end,
	},
	{
		name = "list grouping",
		fn = function()
			local cols = Model.columns({
				issue(1, "done", { priority = 1 }),
				issue(2, "back"),
				issue(3, "prog", { priority = 4 }),
				issue(4, "prog", { priority = 2 }),
				issue(5, "todo"),
			}, STATES, {})
			local order = ids(Model.list(cols), "identifier")
			check(order == "ENG-2,ENG-5,ENG-4,ENG-3,ENG-1", "order " .. order)
		end,
	},
	{
		name = "cancelState",
		fn = function()
			check(Model.cancelState(STATES) == "x1", "lowest canceled")
			check(Model.cancelState({ state("todo", "unstarted", 0) }) == nil, "none")
		end,
	},
	{
		name = "estimate scale",
		fn = function()
			local function values(est: any): string
				local out = {}
				for _, o in Model.estimateOptions(est) do
					table.insert(out, o.label)
				end
				return table.concat(out, ",")
			end
			check(values({ type = "notUsed", allowZero = true, extended = true }) == "", "notUsed has no scale")
			check(values(nil) == "", "no estimation")
			check(values({ type = "fibonacci", allowZero = false, extended = false }) == "1 point,2 points,3 points,5 points,8 points", "fibonacci " .. values({ type = "fibonacci", allowZero = false, extended = false }))
			check(values({ type = "exponential", allowZero = true, extended = true }) == "0 points,1 point,2 points,4 points,8 points,16 points,32 points,64 points", "exponential extended with zero")
			check(values({ type = "tShirt", allowZero = false, extended = false }) == "XS,S,M,L,XL", "t-shirt")
		end,
	},
	{
		name = "template fields",
		fn = function()
			local f = Model.templateFields({
				title = "Bug: ",
				priority = 2,
				stateId = "todo",
				labelIds = { "l1" },
				assigneeId = "",
				estimate = "big",
				descriptionData = { type = "doc", content = { { type = "paragraph", content = { { type = "text", text = "Steps" } } } } },
			})
			check(f.title == "Bug: " and f.priority == 2 and f.stateId == "todo", "plain fields")
			check(f.assigneeId == nil and f.estimate == nil, "empty or mistyped fields dropped")
			check(f.labelIds and f.labelIds[1] == "l1", "labels")
			check(f.description == "Steps", "description from descriptionData: " .. tostring(f.description))
			check(Model.templateFields({ description = "md", descriptionData = { type = "doc" } }).description == "md", "markdown description wins")
			check(next(Model.templateFields("junk")) == nil, "non-table data")
		end,
	},
	{
		name = "markdown",
		fn = function()
			local function text(t: string, marks: { any }?): any
				return { type = "text", text = t, marks = marks }
			end
			local function para(...: any): any
				return { type = "paragraph", content = { ... } }
			end
			local blocks: { any } = {
				{ type = "heading", attrs = { level = 2 }, content = { text("Summary") } },
				para(text("Is "), text("bad", { { type = "bold" } }), text(", see "), text("docs", { { type = "link", attrs = { href = "https://x" } } })),
				{ type = "bullet_list", content = {
					{ type = "list_item", content = { para(text("one")), { type = "bulletList", content = { { type = "listItem", content = { para(text("nested")) } } } } } },
					{ type = "list_item", content = { para(text("two")) } },
				} },
				{ type = "orderedList", content = { { type = "listItem", content = { para(text("first")) } } } },
				{ type = "todo_list", content = { { type = "todo_item", attrs = { done = true }, content = { para(text("done")) } } } },
				{ type = "code_block", attrs = { language = "lua" }, content = { text("x = 1") } },
				{ type = "blockquote", content = { para(text("quoted")) } },
			}
			local md = Model.markdown({ type = "doc", content = blocks })
			local want = "## Summary\n\nIs **bad**, see [docs](https://x)\n\n- one\n  - nested\n- two\n\n1. first\n\n- [x] done\n\n```lua\nx = 1\n```\n\n> quoted"
			check(md == want, "got:\n" .. tostring(md))
			check(Model.markdown({ type = "paragraph" }) == nil, "not a doc")
		end,
	},
	{
		name = "dates",
		fn = function()
			check(Model.addDays({ year = 2026, month = 1, day = 31 }, 1) == "2026-02-01", "month rollover")
			check(Model.addDays({ year = 2026, month = 12, day = 31 }, 7) == "2027-01-07", "year rollover")
			check(Model.isDate("2026-10-21") and not Model.isDate("2026-1-2") and not Model.isDate("tomorrow"), "isDate")
			check(Model.matches("In Progress", "prog") and Model.matches("x", "") and not Model.matches("Todo", "done"), "matches")
		end,
	},
	{
		name = "rewrite text",
		fn = function()
			check(Model.cleanRewrite("  ## A\n\nb  \n") == "## A\n\nb", "trim")
			check(Model.cleanRewrite("```markdown\n## A\n```") == "## A", "fence")
			check(Model.cleanRewrite("   \n") == nil, "empty")
			local p = Model.rewritePrompt("T", "", "FIX")
			check(string.find(p, "Current description:\n(empty)", 1, true) ~= nil and string.find(p, "team FIX", 1, true) ~= nil, "prompt")
		end,
	},
	{
		name = "labelClass",
		fn = function()
			check(Model.labelClass("#eb5757") == "red", "red")
			check(Model.labelClass("#5e6ad2") == "blue", "blue")
			check(Model.labelClass("#95a2b3") == "gray", "gray")
			check(Model.labelClass(nil) == "gray", "nil")
			check(Model.labelClass("zzz") == "gray", "invalid")
		end,
	},
	{
		name = "initials",
		fn = function()
			check(Model.initials("Jack Lu") == "JL", "two words")
			check(Model.initials("jack") == "JA", "one word")
			check(Model.initials("") == "?", "empty")
		end,
	},
	{
		name = "estimate",
		fn = function()
			check(Model.estimate(3) == "3", "int")
			check(Model.estimate(0.5) == "0.5", "half")
			check(Model.estimate(nil) == nil, "nil")
		end,
	},
	{
		name = "retryable",
		fn = function()
			local Linear = require("./linear")
			check(Linear.retryable("network: x"), "network")
			check(Linear.retryable("rate limited (429)"), "429")
			check(Linear.retryable("HTTP 502"), "502")
			check(not Linear.retryable("HTTP 400: bad"), "400")
			check(not Linear.retryable("Linear: x"), "linear")
		end,
	},
	{
		name = "workflow brief",
		fn = function()
			local e = { issue = issue(4, "todo"), title = "Fix it", stateName = "Todo", description = "Steps here" }
			local e2 = { issue = issue(11, "todo"), title = "Other", stateName = "Todo", description = "More" }
			local prompts = {
				{ Model.startPrompt(e.issue, e.title, e.stateName, e.description), false },
				{ Model.contextPrompt({ e }), false },
				{ Model.contextPrompt({ e, e2 }), true },
			}
			local heads = { "## Before you start", "## Hard stops", "## 1. Plan", "## 2. Build", "## 3. Ship", "## 4. Handover" }
			local function find(p: string, s: string, from: number?): number?
				return (string.find(p, s, from or 1, true))
			end
			for i, item in prompts do
				local p, multi = item[1] :: string, item[2] :: boolean
				local at = find(p, "Steps here") or 0
				check(at > 0, i .. ": description")
				for _, h in heads do
					local s = find(p, h)
					check(s ~= nil and s > at and find(p, h, s + 1) == nil, i .. ": " .. h .. " once, after the issue")
					at = s or at
				end
				for _, want in { "skill://domain-modeling", "skill://show-me", "skill://visual-pr" } do
					check(find(p, want) ~= nil, i .. ": " .. want)
				end
				check((find(p, "skill://visual-pr") or 0) > (find(p, "## 4. Handover") or math.huge), i .. ": visual-pr after the handover")
				local tail = "Its output must be your final message."
				check(string.sub(p, -#tail) == tail, i .. ": ends with the final message")
				if multi then
					for _, want in { "Write ONE plan covering all of them.", "Fixes ENG-4", "Fixes ENG-11" } do
						check(find(p, want) ~= nil, i .. ": " .. want)
					end
				else
					for _, want in { "title `ENG-4: Fix it`", "Fixes ENG-4" } do
						check(find(p, want) ~= nil, i .. ": " .. want)
					end
				end
			end
		end,
	},
	{
		name = "startPrompt",
		fn = function()
			local it = issue(4, "todo", { priority = 2, assignee = "Ada" })
			it.labels = { nodes = { { name = "Bug" }, { name = "UI" } } }
			local p = Model.startPrompt(it, "Fix it", "Todo", "Steps here")
			check(string.find(p, "^Start working on Linear issue ENG%-4: Fix it%.") ~= nil, "lead")
			for _, want in { "- URL: https://linear.app/x/issue/ENG-4", "- State: Todo", "- Priority: High", "- Assignee: Ada", "- Labels: Bug, UI", "## Description\n\nSteps here" } do
				check(string.find(p, want, 1, true) ~= nil, want)
			end
			check(string.find(Model.startPrompt(issue(5, "todo"), "T", nil, " "), "(no description)", 1, true) ~= nil, "empty")
			local bare = Model.startPrompt(issue(5, "todo"), "T", nil, nil)
			check(string.find(bare, "could not be loaded", 1, true) ~= nil, "unloaded")
			for _, unset in { "Priority", "Assignee", "Labels", "State", "Identifier", "Title:" } do
				check(string.find(bare, unset, 1, true) == nil, "no " .. unset)
			end
		end,
	},
	{
		name = "startPrompts",
		fn = function()
			local a = issue(4, "todo", { priority = 2, assignee = "Ada" })
			local e = { issue = a, title = "Fix it", stateName = "Todo", description = "Steps here" }
			local e2 = { issue = issue(11, "todo"), title = "Other", stateName = nil, description = nil }
			local ps = Model.startPrompts({ e, e2 })
			check(#ps == 2, "one prompt per issue")
			check(ps[1].prompt == Model.startPrompt(e.issue, e.title, e.stateName, e.description), "first is ENG-4's Start")
			check(ps[2].prompt == Model.startPrompt(e2.issue, e2.title, e2.stateName, e2.description), "second is ENG-11's Start")
			check(string.find(ps[1].prompt, "ENG-11", 1, true) == nil and string.find(ps[2].prompt, "ENG-4", 1, true) == nil, "no other issue")
			for _, p in ps do
				check(string.find(p.prompt, "ONE plan", 1, true) == nil, "no shared plan")
			end
			check(ps[1].issueId == "i4" and ps[2].issueId == "i11", "issue ids")
			check(ps[1].model == nil and ps[1].thinking == nil and ps[1].cwd == nil, "no picks")
			local q = Model.startPrompts({ e }, { model = "a/b", thinking = "high", cwd = "C:/w" })
			check(q[1].model == "a/b" and q[1].thinking == "high" and q[1].cwd == "C:/w", "picks copied")
			check(#Model.startPrompts({}) == 0, "none")
		end,
	},
	{
		name = "contextPrompt",
		fn = function()
			local a = issue(4, "todo", { priority = 2, assignee = "Ada" })
			local one = Model.contextPrompt({ { issue = a, title = "Fix it", stateName = "Todo", description = "Steps here" } })
			check(string.find(one, "^Here is Linear issue ENG%-4: Fix it%.\n\n%- URL: ") ~= nil, "lead")
			check(string.find(one, "## Description\n\nSteps here\n\n", 1, true) ~= nil, "description then brief")
			local many = Model.contextPrompt({
				{ issue = a, title = "Fix it", stateName = "Todo", description = "Steps here" },
				{ issue = issue(11, "todo"), title = "Other", stateName = nil, description = nil },
			})
			check(string.find(many, "^Here are 2 Linear issues: ENG%-4, ENG%-11%.") ~= nil, "many lead")
			check(string.find(many, "## ENG-11: Other", 1, true) ~= nil and string.find(many, "ONE plan", 1, true) ~= nil, "many sections")
			for _, p in { one, many } do
				check(string.find(p, "Start working", 1, true) == nil, "no Start working")
			end
		end,
	},
	{
		name = "chatRow",
		fn = function()
			local r = Model.chatRow("", "omp", "C:\\Users\\me\\fixit-app", "omp --config x.yml", "anthropic/sonnet", "idle")
			check(r.label == "omp" and r.meta == "fixit-app · sonnet · idle" and r.icon == "tile-omp", "untitled omp")
			r = Model.chatRow("Fix 25", "omp", "/home/me/app/", "\"C:\\bin\\Claude.exe\"", nil, "waiting_input")
			check(r.label == "Fix 25" and r.meta == "app · waiting" and r.icon == "tile-claude", "tab name")
			r = Model.chatRow(nil, "Pull requests", "", "aider", "", "working")
			check(r.label == "Pull requests" and r.meta == "working" and r.icon == "tile-agent", "pane title")
			check(Model.chatRow(nil, "", "/srv/api/", nil, nil, "idle").label == "api", "no title")
		end,
	},
	{
		name = "range",
		fn = function()
			local list = { issue(1, "todo"), issue(2, "todo"), issue(3, "prog"), issue(4, "done") }
			check(table.concat(Model.range(list, "i2", "i4"), ",") == "i2,i3,i4", "down")
			check(table.concat(Model.range(list, "i3", "i1"), ",") == "i1,i2,i3", "up")
			check(table.concat(Model.range(list, "i2", "i2"), ",") == "i2", "one")
			check(table.concat(Model.range(list, "gone", "i3"), ",") == "i3", "anchor gone")
			check(#Model.range(list, "i1", "gone") == 0, "target gone")
		end,
	},
	{
		name = "nest",
		fn = function()
			-- Sorted by priority: children 3, 5 and grandchild 6 sort above their parents.
			local cols = Model.columns({
				issue(1, "todo", { priority = 4 }),
				issue(2, "todo", { priority = 3 }),
				issue(3, "todo", { priority = 1, parent = 1 }),
				issue(4, "todo", { priority = 4, parent = 1 }),
				issue(5, "todo", { priority = 2, parent = 4 }),
				issue(6, "todo", { priority = 1, parent = 9 }),
				issue(7, "prog", { parent = 2 }),
				issue(8, "todo", { priority = 2, parent = 8 }),
			}, STATES, {})
			local sorted = ids(cols[2].issues, "identifier")
			check(sorted == "ENG-3,ENG-6,ENG-5,ENG-8,ENG-2,ENG-1,ENG-4", "sorted " .. sorted)
			local rows, tree = Model.nest(cols[2].issues)
			local order = ids(rows, "identifier")
			check(order == "ENG-6,ENG-8,ENG-2,ENG-1,ENG-3,ENG-4,ENG-5", "nested " .. order)
			check(ids(Model.list(cols), "identifier") == order .. ",ENG-7", "list follows nest; parent in another group stays flat")
			check(tree.i6.depth == 0 and tree.i8.depth == 0 and tree.i1.depth == 0, "parent missing or itself: top level")
			check(tree.i3.depth == 1 and not tree.i3.last and tree.i4.depth == 1 and tree.i4.last, "children")
			check(tree.i5.depth == 2 and tree.i5.last and #tree.i5.rails == 1 and tree.i5.rails[1] == false, "grandchild under a last child")
			local loop = Model.nest({ issue(1, "todo", { parent = 2 }), issue(2, "todo", { parent = 1 }) })
			check(ids(loop, "identifier") == "ENG-1,ENG-2", "parent loop still shown")
			local deep = { issue(1, "todo") }
			for n = 2, 6 do
				table.insert(deep, issue(n, "todo", { parent = n - 1 }))
			end
			local _, dt = Model.nest(deep)
			check(dt.i4.depth == 3 and dt.i6.depth == 3 and #dt.i6.rails == 2, "depth capped")
		end,
	},
	{
		name = "progress",
		fn = function()
			local function kid(t: string): any
				return { id = t, state = { type = t } }
			end
			local done, total = Model.progress({ children = { nodes = { kid("completed"), kid("canceled"), kid("started"), kid("backlog") } } })
			check(done == 2 and total == 4, "done " .. done .. "/" .. total)
			done, total = Model.progress(issue(1, "todo"))
			check(done == 0 and total == 0, "no children field (old cache)")
		end,
	},
	{
		name = "epoch and ago",
		fn = function()
			check(Model.epoch("1970-01-01T00:00:00.000Z") == 0, "epoch zero")
			check(Model.epoch("2026-10-22T08:15:30.123Z") == 1792656930, "a 2026 time")
			check(Model.epoch("2000-02-29T23:59:59Z") == 951868799, "leap day")
			check(Model.epoch("2024-03-01T00:00:00.000Z") == 1709251200, "after a leap February")
			check(Model.epoch("yesterday") == nil and Model.epoch(nil) == nil, "not a time")
			local t = 1792656930
			local iso = "2026-10-22T08:15:30.000Z"
			check(Model.ago(iso, t + 30) == "just now", "seconds")
			check(Model.ago(iso, t + 5 * 60) == "5m ago", "minutes")
			check(Model.ago(iso, t + 2 * 3600 + 59) == "2h ago", "hours round down")
			check(Model.ago(iso, t + 3 * 86400) == "3d ago", "days")
			check(Model.ago(iso, t + 65 * 86400) == "2mo ago", "months")
			check(Model.ago(iso, t + 800 * 86400) == "2y ago", "years")
			check(Model.ago(iso, t - 100) == "just now", "clock skew: never negative")
			check(Model.ago(false, t) == "", "missing time")
		end,
	},
	{
		name = "timeline",
		fn = function()
			check(Model.relationVerb("ar") == "added related issue", "related added (Linear's code)")
			check(Model.relationVerb("rb") == "removed blocking issue", "blocks removed")
			check(Model.relationVerb("az") == "added a relation with", "unknown relation")
			check(Model.relationVerb(nil) == "changed a relation with", "no code")
			local null: any = {} -- stands for tern.json.null: any non-string, non-matching value
			local info: any = {
				createdAt = "2026-10-22T08:00:00.000Z",
				creator = { name = "Jack Lu" },
				related = { { type = "related", inverse = false, issue = { identifier = "FIX-39", title = "Sticky footer" } } },
				history = {
					{ createdAt = "2026-10-22T08:00:00.000Z", actor = { name = "Jack Lu" }, fromState = { name = "Backlog", type = "backlog" }, toState = { name = "Todo", type = "unstarted" } },
					{ createdAt = "2026-10-22T09:00:00.000Z", actor = null, botActor = { name = "GitHub" }, relationChanges = { { identifier = "FIX-39", type = "ar" }, { identifier = "FIX-7", type = "ar" } } },
					{ createdAt = "2026-10-22T07:00:00.000Z", toState = { name = "Todo" } },
					{ createdAt = null, fromState = { name = "A" }, toState = { name = "B" } },
				} :: { any },
				comments = { { id = "c1", body = "hi", createdAt = "2026-10-22T08:30:00.000Z", user = { name = "Ana" } }, { id = "c2", createdAt = null } } :: { any },
			}
			local tl = Model.timeline(info)
			check(#tl == 5, "kept " .. #tl .. " of the entries")
			check(tl[1].kind == "created" and tl[1].who == "Jack Lu", "creation first")
			check(tl[2].kind == "state" and tl[2].text == "moved from Backlog to Todo" and tl[2].stateType == "unstarted", "same-time State change after creation")
			check(tl[3].kind == "comment" and tl[3].who == "Ana", "comment merged by time")
			check(tl[4].kind == "relation" and tl[4].who == "GitHub" and tl[4].ident == "FIX-39" and tl[4].title == "Sticky footer", "relation with the related title")
			check(tl[5].ident == "FIX-7" and tl[5].title == nil, "relation to an issue not loaded")
			check(#Model.timeline({}) == 0, "nothing loaded")
		end,
	},
	{
		name = "taskGroups",
		fn = function()
			local cols = {
				{ state = state("todo", "unstarted", 0), issues = { issue(1, "todo"), issue(2, "todo") } },
				{ state = state("prog", "started", 1), issues = { issue(3, "prog") } },
				{ state = state("review", "started", 2), issues = { issue(4, "review") } },
				{ state = state("back", "backlog", 9), issues = { issue(5, "back") } },
				{ state = state("done", "completed", 0), issues = { issue(6, "done") } },
				{ state = state("x1", "canceled", 3), issues = { issue(7, "x1") } },
			}
			local g = Model.taskGroups(cols)
			check(ids(g.open, "id") == "i3,i4,i1,i2", "started before unstarted: " .. ids(g.open, "id"))
			check(ids(g.backlog, "id") == "i5", "backlog")
			check(ids(g.done, "id") == "i6", "done, canceled ignored")
			local e = Model.taskGroups({})
			check(#e.open == 0 and #e.backlog == 0 and #e.done == 0, "empty")
		end,
	},
	{
		name = "agentKind",
		fn = function()
			check(Model.agentKind("working") == "running", "working")
			check(Model.agentKind("waiting_input") == "needs", "waiting")
			check(Model.agentKind("idle") == "review", "idle")
			check(Model.agentKind("exited") == "stopped", "exited")
			check(Model.agentKind("weird") == nil and Model.agentKind(nil) == nil and Model.agentKind(3) == nil, "unknown")
		end,
	},
	{
		name = "agentLine",
		fn = function()
			check(Model.agentLine("running", nil) == "Working", "nil seconds")
			check(Model.agentLine("running", 59) == "Working", "59 s")
			check(Model.agentLine("running", 61) == "Working · 1m", "61 s")
			check(Model.agentLine("running", 3900) == "Working · 1h 5m", "1h 5m")
			check(Model.agentLine("needs", 5) == "Needs you", "needs")
			check(Model.agentLine("review", nil) == "Ready for you", "review")
			check(Model.agentLine("stopped", nil) == "Stopped", "stopped")
			check(Model.agentLine(nil, 10) == nil and Model.agentLine("x", nil) == nil, "none")
		end,
	},
	{
		name = "short",
		fn = function()
			local iso = "2026-01-01T00:00:00.000Z"
			local t = Model.epoch(iso) :: number
			local d = 86400
			check(Model.short("nope", t) == "" and Model.short(nil, t) == "", "not a time")
			check(Model.short(iso, t - 100) == "now", "future")
			check(Model.short(iso, t + 59) == "now", "59 s")
			check(Model.short(iso, t + 60) == "1m" and Model.short(iso, t + 3599) == "59m", "minutes")
			check(Model.short(iso, t + 3600) == "1h" and Model.short(iso, t + d - 1) == "23h", "hours")
			check(Model.short(iso, t + d) == "1d" and Model.short(iso, t + 7 * d - 1) == "6d", "days")
			check(Model.short(iso, t + 7 * d) == "1w" and Model.short(iso, t + 30 * d - 1) == "4w", "weeks")
			check(Model.short(iso, t + 30 * d) == "1mo" and Model.short(iso, t + 365 * d - 1) == "12mo", "months")
			check(Model.short(iso, t + 365 * d) == "1y" and Model.short(iso, t + 800 * d) == "2y", "years")
		end,
	},
	{
		name = "nextThinking",
		fn = function()
			local seq = { "off", "auto", "minimal", "low", "medium", "high", "xhigh", "max" }
			local cur: string? = nil
			for _, want in seq do
				cur = Model.nextThinking(cur, nil)
				check(cur == want, "default cycle at " .. want)
			end
			check(Model.nextThinking(cur, nil) == nil, "back to default")
			check(Model.nextThinking("auto", {}) == "minimal", "empty levels = default")
			local own = { "low", "high" }
			check(Model.nextThinking("auto", own) == "low" and Model.nextThinking("low", own) == "high", "own levels")
			check(Model.nextThinking("high", own) == nil, "own levels end")
			check(Model.nextThinking("medium", own) == "off" and Model.nextThinking("zzz", nil) == "off", "unknown restarts")
		end,
	},
	{
		name = "safeArg",
		fn = function()
			check(Model.safeArg("anthropic/claude-fable-5"), "selector")
			check(Model.safeArg("a:b.c_d"), "punctuation")
			check(not Model.safeArg(""), "empty")
			check(not Model.safeArg("a b"), "space")
			check(not Model.safeArg('a"b') and not Model.safeArg("a'b"), "quotes")
			check(not Model.safeArg("a;rm"), "semicolon")
			check(Model.safeArg(string.rep("a", 200)) and not Model.safeArg(string.rep("a", 201)), "length")
			check(not Model.safeArg(nil) and not Model.safeArg(5), "non-string")
		end,
	},
	{
		name = "startCommand",
		fn = function()
			local base = 'omp --plan --config "C:/p/plan-mode.yml"'
			check(Model.startCommand("C:/p", nil, nil) == base, "no picks")
			check(Model.startCommand("C:/p", "a/m-1", nil) == base .. " --model a/m-1", "model")
			check(Model.startCommand("C:/p", nil, "high") == base .. " --thinking high", "thinking")
			check(Model.startCommand("C:/p", "a m;x", "high") == base .. " --thinking high", "unsafe model dropped")
			check(Model.startCommand("C:/p", "a/m", "huge") == base .. " --model a/m", "unknown thinking dropped")
		end,
	},
	{
		name = "autoSettings",
		fn = function()
			local function is(s: any, on: boolean, max: number): boolean
				return s.on == on and s.max == max
			end
			check(is(Model.autoSettings(nil), false, 2) and is(Model.autoSettings("junk"), false, 2), "defaults")
			check(is(Model.autoSettings({ on = true, max = 3 }), true, 3), "valid")
			check(is(Model.autoSettings({ on = true, max = 7 }), true, 3) and is(Model.autoSettings({ max = 0 }), false, 1), "clamped")
			check(is(Model.autoSettings({ max = 2.9 }), false, 2) and is(Model.autoSettings({ max = -5 }), false, 1), "floored")
			check(is(Model.autoSettings({ on = "yes", max = "3" }), false, 2) and is(Model.autoSettings({ max = 0 / 0 }), false, 2), "malformed fields")
		end,
	},
	{
		name = "hasLabel and busySlots",
		fn = function()
			local i = { labels = { nodes = { { name = "Bug" }, { name = "Agent" } } } }
			check(Model.hasLabel(i, "agent") and Model.hasLabel(i, "AGENT"), "case-insensitive")
			check(not Model.hasLabel(i, "feature"), "other label")
			check(not Model.hasLabel({}, "agent") and not Model.hasLabel({ labels = {} }, "agent"), "no labels")
			check(Model.busySlots({ a = "working", b = "exited", c = "idle", d = "waiting_input" }) == 3, "exited ignored")
			check(Model.busySlots({}) == 0, "none")
		end,
	},
	{
		name = "autoCandidates",
		fn = function()
			local function opted(n: number, stateId: string, opts: IssueOpts?): any
				local x = issue(n, stateId, opts)
				x.labels = { nodes = { { name = "Agent" } } }
				return x
			end
			local cols = Model.columns({
				opted(1, "todo", { assignee = "me", priority = 3 }),
				opted(2, "prog", { assignee = "me" }),
				opted(3, "todo", { assignee = "you" }),
				issue(4, "todo", { assignee = "me" }),
				opted(5, "todo", { assignee = "me" }),
				opted(6, "todo", { assignee = "me" }),
				opted(7, "todo", { assignee = "me", priority = 1 }),
			}, STATES, {})
			local got = ids(Model.autoCandidates(cols, "me", { i5 = 1700000000 }, { i6 = "working", i7 = "exited" }), "identifier")
			check(got == "ENG-7,ENG-1", "candidates " .. got)
			check(#Model.autoCandidates(cols, nil, {}, {}) == 0, "nil viewerId")
			check(ids(Model.autoCandidates(cols, "me", {}, { i6 = "idle" }), "identifier") == "ENG-7,ENG-1,ENG-5", "idle chat holds its Issue")
		end,
	},
	{
		name = "budget",
		fn = function()
			local function lim(id: string, amount: string): string
				return '{"id":"' .. id .. '","window":{"id":"x"},"amount":' .. amount .. "}"
			end
			local function usage(...: string): string
				return '{"reports":[{"provider":"anthropic","limits":[' .. table.concat({ ... }, ",") .. "]}]}"
			end
			local function frac(f: number): string
				return '{"used":1,"limit":100,"usedFraction":' .. f .. ',"unit":"percent"}'
			end
			local b = Model.budget(usage(lim("anthropic:5h", frac(0.86)), lim("anthropic:7d", frac(0.14))), 0.8)
			check(b.blocked and b.reason == "Claude 5-hour window at 86%" and b.used == 0.86, "5h over: " .. tostring(b.reason))
			b = Model.budget(usage(lim("anthropic:5h", frac(0.5)), lim("anthropic:7d", frac(0.81)), lim("anthropic:7d:fable", frac(0.99))), 0.8)
			check(b.blocked and b.reason == "Claude 7-day window at 81%" and b.used == 0.81, "7d over is the highest: " .. tostring(b.reason))
			b = Model.budget(usage(lim("anthropic:5h", frac(0.5)), lim("anthropic:7d", frac(0.14)), lim("anthropic:7d:fable", frac(0.95))), 0.8)
			check(not b.blocked and b.reason == nil and b.used == 0.5, "fable ignored")
			b = Model.budget(usage(lim("anthropic:5h", '{"used":90,"limit":100}')), 0.8)
			check(b.blocked and b.reason == "Claude 5-hour window at 90%", "used/limit: " .. tostring(b.reason))
			b = Model.budget(usage(lim("anthropic:5h", frac(0.8))), 0.8)
			check(b.blocked and b.reason == "Claude 5-hour window at 80%", "exactly the limit blocks")
			for _, bad in { "nope", "", usage(), usage(lim("anthropic:7d:fable", frac(0.1))) } do
				b = Model.budget(bad, 0.8)
				check(b.blocked and b.reason == "usage unknown" and b.used == nil, "usage unknown: " .. bad)
			end
			check(Model.budget(nil, 0.8).reason == "usage unknown", "nil stdout")
		end,
	},
	{
		name = "prStatus",
		fn = function()
			local sample = '{"number":103,"url":"https://github.com/lujack88/fixit-app/pull/103","state":"OPEN","headRefOid":"01b3d57","statusCheckRollup":['
				.. '{"__typename":"CheckRun","name":"platform-guard","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/lujack88/fixit-app/actions/runs/42346208184/job/128324391752"},'
				.. '{"__typename":"CheckRun","name":"ci","status":"IN_PROGRESS","conclusion":""},'
				.. '{"__typename":"CheckRun","name":"Supabase Preview","status":"COMPLETED","conclusion":"SKIPPED"},'
				.. '{"__typename":"StatusContext","context":"Vercel","state":"SUCCESS","targetUrl":"x"}]}'
			local pr = Model.prStatus(sample) :: Model.Pr
			check(pr ~= nil and pr.number == 103 and pr.state == "OPEN" and pr.sha == "01b3d57", "fields")
			check(pr.ci == "pending" and table.concat(pr.failed, ",") == "platform-guard" and pr.runId == "42346208184", "sample: " .. tostring(pr.ci))
			local function rollup(entries: string): Model.Pr
				return Model.prStatus('{"number":1,"url":"u","state":"OPEN","headRefOid":"s","statusCheckRollup":[' .. entries .. "]}") :: Model.Pr
			end
			local ok = '{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}'
			check(rollup(ok .. ',{"__typename":"StatusContext","context":"V","state":"SUCCESS"}').ci == "green", "all success")
			local red = rollup(ok .. ',{"__typename":"CheckRun","name":"b","status":"COMPLETED","conclusion":"TIMED_OUT"},{"__typename":"CheckRun","name":"b","status":"COMPLETED","conclusion":"FAILURE"}')
			check(red.ci == "red" and table.concat(red.failed, ",") == "b" and red.runId == nil, "failure only, no duplicates, no runId")
			local err = rollup('{"__typename":"StatusContext","context":"Vercel","state":"ERROR"}')
			check(err.ci == "red" and err.failed[1] == "Vercel", "StatusContext ERROR")
			check(rollup('{"__typename":"StatusContext","context":"V","state":"EXPECTED"}').ci == "pending", "StatusContext EXPECTED")
			check(rollup("").ci == "none" and #rollup("").failed == 0, "empty rollup")
			check((Model.prStatus('{"number":2,"state":"MERGED"}') :: Model.Pr).ci == "none", "missing rollup")
			check(Model.prStatus("no pull requests found") == nil and Model.prStatus(nil) == nil and Model.prStatus('{"url":"x"}') == nil, "not a PR")
		end,
	},
	{
		name = "ciStep",
		fn = function()
			local function pr(st: string, ci: string, sha: string): Model.Pr
				return { number = 103, url = "u", state = st, sha = sha, ci = ci, failed = { "platform-guard" }, runId = nil }
			end
			local e: Model.CiEntry = { rounds = 1, sha = "a" }
			local function is(s: Model.CiStep, action: string, entry: Model.CiEntry?): boolean
				return s.action == action and s.entry == entry
			end
			check(is(Model.ciStep(e, nil, "idle", 2), "none", e), "no PR")
			check(is(Model.ciStep(e, pr("MERGED", "red", "b"), "idle", 2), "clear", nil) and is(Model.ciStep(nil, pr("CLOSED", "green", "b"), "idle", 2), "none", nil), "merged or closed")
			check(is(Model.ciStep(e, pr("OPEN", "red", "b"), "working", 2), "none", e) and is(Model.ciStep(e, pr("OPEN", "red", "b"), "waiting_input", 2), "none", e), "chat busy")
			check(is(Model.ciStep(e, pr("OPEN", "pending", "b"), "idle", 2), "none", e) and is(Model.ciStep(e, pr("OPEN", "none", "b"), "exited", 2), "none", e), "pending or none")
			check(is(Model.ciStep(e, pr("OPEN", "green", "b"), "idle", 2), "clear", nil) and is(Model.ciStep(nil, pr("OPEN", "green", "b"), "idle", 2), "none", nil), "green")
			check(is(Model.ciStep(e, pr("OPEN", "red", "a"), "idle", 2), "none", e) and is(Model.ciStep(e, pr("OPEN", "red", "a"), nil, 2), "none", e), "same sha")
			local s = Model.ciStep(nil, pr("OPEN", "red", "b"), nil, 2)
			local ent = s.entry :: Model.CiEntry
			check(s.action == "block" and s.reason == "chat closed with red CI" and ent.rounds == 0 and ent.sha == "b" and ent.blocked == s.reason, "no chat")
			s = Model.ciStep(e, pr("OPEN", "red", "b"), "exited", 2)
			ent = s.entry :: Model.CiEntry
			check(s.action == "block" and s.reason == "chat closed with red CI" and ent.rounds == 1, "chat exited")
			s = Model.ciStep(nil, pr("OPEN", "red", "b"), "idle", 2)
			ent = s.entry :: Model.CiEntry
			check(s.action == "send" and ent.rounds == 1 and ent.sha == "b" and ent.blocked == nil, "first round")
			s = Model.ciStep({ rounds = 1, sha = "a", blocked = "x" }, pr("OPEN", "red", "b"), "idle", 2)
			ent = s.entry :: Model.CiEntry
			check(s.action == "send" and ent.rounds == 2 and ent.sha == "b" and ent.blocked == nil, "second round clears blocked")
			s = Model.ciStep({ rounds = 2, sha = "b" }, pr("OPEN", "red", "c"), "idle", 2)
			ent = s.entry :: Model.CiEntry
			check(s.action == "block" and s.reason == "CI red after 2 rounds" and ent.rounds == 2 and ent.sha == "c" and ent.blocked == s.reason, "round limit")
		end,
	},
	{
		name = "ciPrompt and blockedLine",
		fn = function()
			local pr: Model.Pr = { number = 103, url = "u", state = "OPEN", sha = "s", ci = "red", failed = { "platform-guard", "ci" }, runId = "42346208184" }
			local want = "PR #103 for FIX-12 has failing checks: platform-guard, ci (round 1 of 2).\n\n"
				.. "Run `gh run view 42346208184 --log-failed` to see why, fix it in the same worktree, push, and wait for the checks. The hard stops still apply."
			check(Model.ciPrompt("FIX-12", pr, 1, 2) == want, "with runId:\n" .. Model.ciPrompt("FIX-12", pr, 1, 2))
			pr.runId = nil
			local p = Model.ciPrompt("FIX-12", pr, 2, 2)
			check(string.find(p, "(round 2 of 2).\n\nRun `gh pr checks 103` to see why, fix it", 1, true) ~= nil, "without runId:\n" .. p)
			check(Model.blockedLine("CI red after 2 rounds") == "Blocked · CI red after 2 rounds", "blockedLine")
		end,
	},
	{
		name = "worktrees",
		fn = function()
			local text = table.concat({
				"worktree C:/Users/admin/Documents/fixit-app", "HEAD c5056a97", "branch refs/heads/main", "",
				"worktree C:/Users/admin/Documents/fixit-app.lujack882/fix-106-let-customers", "HEAD 2e551d31", "branch refs/heads/lujack882/fix-106-let-customers", "",
				"worktree C:/x/y", "HEAD 8c853f26", "detached", "locked reason text", "prunable gitdir file points to non-existent location", "", "",
			}, "\r\n")
			local w = Model.worktrees(text)
			check(#w == 3, "count " .. #w)
			check(w[1].main and w[1].path == "C:/Users/admin/Documents/fixit-app" and w[1].branch == "main" and w[1].head == "c5056a97", "main block")
			check(not w[2].main and w[2].branch == "lujack882/fix-106-let-customers" and w[2].path == "C:/Users/admin/Documents/fixit-app.lujack882/fix-106-let-customers", "branch stripped")
			check(not w[2].detached and not w[2].locked and not w[2].prunable and not w[2].bare, "plain flags")
			check(w[3].path == "C:/x/y" and w[3].detached and w[3].branch == nil and w[3].locked and w[3].prunable and not w[3].main, "detached, locked, prunable")
			check(#Model.worktrees("") == 0, "empty")
		end,
	},
	{
		name = "cleanupVerdict",
		fn = function()
			local wt: Model.Worktree = { path = "p", head = "h", branch = nil, main = true, bare = true, detached = true, locked = true, prunable = true }
			local f: Model.WorktreeFacts = { dirty = nil, unpushed = nil, pr = nil, busy = true }
			-- Fix one problem at a time: the next reason in order must show.
			local steps: { { fix: () -> (), ok: boolean, reason: string } } = {
				{ fix = function() end, ok = false, reason = "main checkout" },
				{ fix = function() wt.main = false end, ok = false, reason = "bare repository" },
				{ fix = function() wt.bare = false end, ok = false, reason = "no branch" },
				{ fix = function() wt.detached = false end, ok = false, reason = "no branch" },
				{ fix = function() wt.branch = "b" end, ok = false, reason = "locked" },
				{ fix = function() wt.locked = false end, ok = false, reason = "folder is gone" },
				{ fix = function() wt.prunable = false end, ok = false, reason = "a chat is still working in it" },
				{ fix = function() f.busy = false end, ok = false, reason = "PR state unknown" },
				{ fix = function() f.pr = "OPEN" end, ok = false, reason = "PR is open" },
				{ fix = function() f.pr = "NONE" end, ok = false, reason = "no PR" },
				{ fix = function() f.pr = "MERGED" end, ok = false, reason = "could not read changes" },
				{ fix = function() f.dirty = true end, ok = false, reason = "uncommitted changes" },
				{ fix = function() f.dirty = false end, ok = false, reason = "could not check commits" },
				{ fix = function() f.unpushed = 1 end, ok = false, reason = "1 commit not on GitHub" },
				{ fix = function() f.unpushed = 3 end, ok = false, reason = "3 commits not on GitHub" },
				{ fix = function() f.unpushed = 0 end, ok = true, reason = "PR merged" },
				{ fix = function() f.pr = "CLOSED" end, ok = true, reason = "PR closed" },
			}
			for i, s in steps do
				s.fix()
				local ok, reason = Model.cleanupVerdict(wt, f)
				check(ok == s.ok and reason == s.reason, i .. ": want " .. s.reason .. ", got " .. reason)
			end
		end,
	},
}

-- Runs every case; returns how many passed and the first failure as "<case>: <msg>".
function M.run(): (number, string?)
	local passed = 0
	local failure: string? = nil
	for _, case in cases do
		local ok, err = pcall(case.fn)
		if ok then
			passed += 1
		elseif not failure then
			failure = case.name .. ": " .. tostring(err)
		end
	end
	return passed, failure
end

return M
