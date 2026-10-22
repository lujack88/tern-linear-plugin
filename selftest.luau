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
			local prompts = {
				Model.startPrompt(e.issue, e.title, e.stateName, e.description),
				Model.startPromptMany({ e, e }),
				Model.contextPrompt({ e }),
				Model.contextPrompt({ e, e }),
			}
			local steps = { "skill://grill-with-docs", "skill://show-me", "Implement nothing until I approve", "In Progress", "subagents", "open a PR", "In Review", "reviewer subagents", "skill://visual-pr", "merge", "Leave the issue(s) in review", "human QA", "wait for my go-ahead" }
			for i, p in prompts do
				local at = string.find(p, "Steps here", 1, true) or math.huge
				for _, want in steps do
					local s = string.find(p, want, 1, true)
					check(s ~= nil and s > at, i .. ": " .. want .. " after the issue")
				end
				local _, n = string.gsub(p, "Workflow:", "")
				check(n == 1, i .. ": brief once")
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
		name = "startPromptMany",
		fn = function()
			local a = issue(4, "todo", { priority = 2, assignee = "Ada" })
			local p = Model.startPromptMany({
				{ issue = a, title = "Fix it", stateName = "Todo", description = "Steps here" },
				{ issue = issue(11, "todo"), title = "Other", stateName = nil, description = nil },
			})
			check(string.find(p, "^Start working on these 2 Linear issues together: ENG%-4, ENG%-11%.") ~= nil, "lead")
			local i4, i11 = string.find(p, "## ENG-4: Fix it", 1, true), string.find(p, "## ENG-11: Other", 1, true)
			check(i4 ~= nil and i11 ~= nil and i4 < i11, "sections in order")
			for _, want in { "- Priority: High", "- Assignee: Ada", "### Description\n\nSteps here", "could not be loaded", "ONE plan" } do
				check(string.find(p, want, 1, true) ~= nil, want)
			end
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
