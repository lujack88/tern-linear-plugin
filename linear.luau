--!strict
-- Linear GraphQL client. Query strings are constants; input travels only as variables.

local M = {}

local ENDPOINT = "https://api.linear.app/graphql"

local ISSUE_FIELDS = "id identifier title url updatedAt priority estimate team { id key } state { id name type } assignee { id name displayName } labels(first: 10) { nodes { id name color } }"

M.VIEWER = "query { viewer { id name organization { id name urlKey } } }"

M.TEAMS = "query { teams(first: 100) { nodes { id key name } } }"

M.STATES = "query($teamId: String!) { team(id: $teamId) { states { nodes { id name type position } } } }"

-- Everything the create modal offers: the team's estimate scale, people, labels, projects,
-- upcoming cycles, plus every issue template of the workspace.
M.META = "query($teamId: String!) { team(id: $teamId) { "
	.. "issueEstimationType issueEstimationAllowZero issueEstimationExtended cyclesEnabled "
	.. "members(first: 250) { nodes { id name displayName active } } "
	.. "labels(first: 250) { nodes { id name color isGroup parent { id name } } } "
	.. "projects(first: 100) { nodes { id name completedAt canceledAt } } "
	.. "cycles(first: 50, filter: { isPast: { eq: false } }) { nodes { id number name startsAt } } "
	.. "} issueLabels(first: 250, filter: { team: { null: true } }) { nodes { id name color isGroup parent { id name } } } "
	.. "templates { id name type team { id } templateData } }"

M.ISSUES = "query($teamId: ID!, $since: DateTimeOrDuration!, $after: String) { "
	.. "issues(first: 100, after: $after, orderBy: updatedAt, filter: { "
	.. "team: { id: { eq: $teamId } }, "
	.. 'or: [ { state: { type: { in: ["backlog", "unstarted", "started"] } } }, '
	.. '{ state: { type: { eq: "completed" } }, completedAt: { gt: $since } } ] '
	.. "}) { nodes { "
	.. ISSUE_FIELDS
	.. " } pageInfo { hasNextPage endCursor } } }"

M.UPDATE = "mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success issue { "
	.. ISSUE_FIELDS
	.. " } } }"

M.CREATE = "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { "
	.. ISSUE_FIELDS
	.. " } } }"

local MAX_PAGES = 10

export type Callback = (data: any, err: string?, cx: WindowCx?) -> ()

-- POSTs one GraphQL request; `key` is the raw personal API key (never logged).
function M.call(key: string, query: string, variables: { [string]: any }?, cb: Callback)
	local body = tern.json.encode({ query = query, variables = variables })
	tern.fetch(ENDPOINT, {
		method = "POST",
		headers = { ["Content-Type"] = "application/json", ["Authorization"] = key },
		body = body,
		timeout_ms = 20000,
	}, function(res: FetchResult, cx: WindowCx?)
		if res.error then
			cb(nil, "network: " .. res.error, cx)
			return
		end
		local status = res.status
		if status == 429 then
			cb(nil, "rate limited (429)", cx)
			return
		end
		if status >= 500 then
			cb(nil, "HTTP " .. status, cx)
			return
		end
		if status < 200 or status >= 300 then
			cb(nil, "HTTP " .. status .. ": " .. string.sub(res.body, 1, 200), cx)
			return
		end
		local ok, decoded = pcall(tern.json.decode, res.body)
		if not ok or type(decoded) ~= "table" then
			cb(nil, "bad response", cx)
			return
		end
		local errors = decoded.errors
		if type(errors) == "table" and errors[1] ~= nil then
			local first = errors[1]
			local msg = if type(first) == "table" and type(first.message) == "string" then first.message else "error"
			cb(nil, "Linear: " .. msg, cx)
			return
		end
		if type(decoded.data) ~= "table" then
			cb(nil, "bad response", cx)
			return
		end
		cb(decoded.data, nil, cx)
	end)
end

-- Transient failures worth backing off and retrying.
function M.retryable(err: string?): boolean
	if not err then
		return false
	end
	return string.sub(err, 1, 9) == "network: "
		or string.sub(err, 1, 12) == "rate limited"
		or string.match(err, "^HTTP 5%d%d$") ~= nil
end

-- Completed issues newer than this stay on the board.
local function since(): string
	local ok, value = pcall(function(): string
		return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 14 * 86400)
	end)
	if ok and type(value) == "string" then
		return value
	end
	return "-P14D"
end

-- All open/recent issues of one team across pages; refuses more than MAX_PAGES pages.
function M.fetchIssues(key: string, teamId: string, cb: (issues: { any }?, err: string?, cx: WindowCx?) -> ())
	local all: { any } = {}
	local pages = 0
	local sinceArg = since()
	local function page(after: string?)
		M.call(key, M.ISSUES, { teamId = teamId, since = sinceArg, after = after }, function(data: any, err: string?, cx: WindowCx?)
			if err then
				cb(nil, err, cx)
				return
			end
			local conn = data.issues
			if type(conn) ~= "table" or type(conn.nodes) ~= "table" then
				cb(nil, "bad response", cx)
				return
			end
			for _, node in conn.nodes do
				table.insert(all, node)
			end
			pages += 1
			local info = conn.pageInfo
			if type(info) == "table" and info.hasNextPage then
				if pages >= MAX_PAGES then
					cb(nil, "more than 1000 issues in this team; sync refused", cx)
					return
				end
				page(info.endCursor)
			else
				cb(all, nil, cx)
			end
		end)
	end
	page(nil)
end

-- Shared tail of the two mutations: unwraps `<field> { success issue }`.
local function mutate(
	key: string,
	query: string,
	field: string,
	variables: { [string]: any },
	cb: (issue: any?, err: string?, cx: WindowCx?) -> ()
)
	M.call(key, query, variables, function(data: any, err: string?, cx: WindowCx?)
		if err then
			cb(nil, err, cx)
			return
		end
		local payload = data[field]
		if type(payload) ~= "table" or payload.success ~= true or type(payload.issue) ~= "table" then
			cb(nil, "Linear: mutation refused", cx)
			return
		end
		cb(payload.issue, nil, cx)
	end)
end

function M.update(key: string, id: string, input: any, cb: (issue: any?, err: string?, cx: WindowCx?) -> ())
	mutate(key, M.UPDATE, "issueUpdate", { id = id, input = input }, cb)
end

function M.create(key: string, input: any, cb: (issue: any?, err: string?, cx: WindowCx?) -> ())
	mutate(key, M.CREATE, "issueCreate", { input = input }, cb)
end

-- Workflow states of one team, in no particular order.
function M.states(key: string, teamId: string, cb: (nodes: { any }?, err: string?, cx: WindowCx?) -> ())
	M.call(key, M.STATES, { teamId = teamId }, function(data: any, err: string?, cx: WindowCx?)
		if err then
			cb(nil, err, cx)
			return
		end
		local team = data.team
		if type(team) ~= "table" or type(team.states) ~= "table" or type(team.states.nodes) ~= "table" then
			cb(nil, "Linear: team not found", cx)
			return
		end
		cb(team.states.nodes, nil, cx)
	end)
end

-- One sync: the team's workflow States, then its issues.
function M.fetchBoard(key: string, teamId: string, cb: (issues: { any }?, states: { any }?, err: string?) -> ())
	M.states(key, teamId, function(states: { any }?, err: string?)
		if not states then
			cb(nil, nil, err)
			return
		end
		M.fetchIssues(key, teamId, function(issues: { any }?, ierr: string?)
			cb(issues, if issues then states else nil, ierr)
		end)
	end)
end

local function nodes(conn: any): { any }
	return if type(conn) == "table" and type(conn.nodes) == "table" then conn.nodes else {}
end

-- The create modal's choices for one team; labels merge the team's and the workspace's.
function M.meta(key: string, teamId: string, cb: (meta: any?, err: string?) -> ())
	M.call(key, M.META, { teamId = teamId }, function(data: any, err: string?)
		if err then
			cb(nil, err)
			return
		end
		local team = data.team
		if type(team) ~= "table" then
			cb(nil, "Linear: team not found")
			return
		end
		local labels, seen = {}, {}
		for _, list in { nodes(team.labels), nodes(data.issueLabels) } do
			for _, l in list do
				if not seen[l.id] then
					seen[l.id] = true
					table.insert(labels, l)
				end
			end
		end
		cb({
			estimation = {
				type = team.issueEstimationType,
				allowZero = team.issueEstimationAllowZero == true,
				extended = team.issueEstimationExtended == true,
			},
			cyclesEnabled = team.cyclesEnabled == true,
			members = nodes(team.members),
			labels = labels,
			projects = nodes(team.projects),
			cycles = nodes(team.cycles),
			templates = if type(data.templates) == "table" then data.templates else {},
		}, nil)
	end)
end

return M
