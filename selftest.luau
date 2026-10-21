--!strict
-- In-Tern checks of model.luau (no Luau runner is installed).

local Model = require("./model")

local M = {}

local function check(cond: boolean, msg: string)
	if not cond then
		error(msg, 0)
	end
end

type IssueOpts = { title: string?, priority: number?, updatedAt: string?, assignee: string? }

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
