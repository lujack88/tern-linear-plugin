--!strict
-- Inline text field model (copied from todo-proto): text, caret, selection and per-field undo.

local M = {}

local function chars_of(s: string): { string }
	local out: { string } = {}
	for _, cp in utf8.codes(s) do
		table.insert(out, utf8.char(cp))
	end
	return out
end

local function length_of(s: string): number
	return utf8.len(s) or #s
end

-- Tern counts offsets in UTF-16 code units: the units before the first `cur` characters.
local function utf16_offset(s: string, cur: number): number
	local n, i = 0, 0
	for _, cp in utf8.codes(s) do
		if i >= cur then
			break
		end
		n += if cp > 0xFFFF then 2 else 1
		i += 1
	end
	return n
end

-- The number of characters that fit in the first `off` UTF-16 units (an offset inside a
-- surrogate pair rounds down, as Tern does).
local function char_index(s: string, off: number): number
	local units, n = 0, 0
	for _, cp in utf8.codes(s) do
		local w = if cp > 0xFFFF then 2 else 1
		if units + w > off then
			break
		end
		units += w
		n += 1
	end
	return n
end

local function line_start(chars: { string }, cur: number): number
	local i = cur
	while i > 0 and chars[i] ~= "\n" do
		i -= 1
	end
	return i
end

local function line_end(chars: { string }, from: number): number
	local i = from
	while i < #chars and chars[i + 1] ~= "\n" do
		i += 1
	end
	return i
end

-- Letters, digits and everything non-ASCII (Cyrillic, emoji) belong to words.
local function is_word(c: string): boolean
	return #c > 1 or string.find(c, "^[%w_]$") ~= nil
end

local function word_left(chars: { string }, cur: number): number
	local i = cur
	while i > 0 and not is_word(chars[i]) do
		i -= 1
	end
	while i > 0 and is_word(chars[i]) do
		i -= 1
	end
	return i
end

local function word_right(chars: { string }, cur: number): number
	local n, i = #chars, cur
	while i < n and not is_word(chars[i + 1]) do
		i += 1
	end
	while i < n and is_word(chars[i + 1]) do
		i += 1
	end
	return i
end

-- A field's text, caret and selection anchor (both counted in characters), with its own
-- undo history: Tern's undo event carries no state, so each field keeps its steps. `max` is a
-- limit in UTF-16 units.
type Snap = { text: string, cur: number }
export type Field = {
	text: string,
	cur: number,
	anchor: number?,
	id: string?,
	rev: number,
	undo: { Snap },
	redo: { Snap },
	-- The last change was typing, so the next typed character joins its undo step.
	typing: boolean,
	multiline: boolean,
	max: number?,
}

local HISTORY = 200

local function reset_field(f: Field, text: string)
	f.text, f.cur, f.anchor = text, length_of(text), nil
	f.undo, f.redo, f.typing = {}, {}, false
	f.rev += 1
end

local function new_field(text: string, multiline: boolean, max: number?): Field
	local f: Field = { text = "", cur = 0, anchor = nil, rev = 0, undo = {}, redo = {}, typing = false, multiline = multiline, max = max }
	reset_field(f, text)
	return f
end

-- Single-line fields take pasted line breaks as spaces.
local function tidy(f: Field, s: string): string
	if f.multiline then
		return (string.gsub(s, "\r\n?", "\n"))
	end
	return (string.gsub(s, "[\r\n]+", " "))
end

-- Ordered selection bounds; equal when nothing is selected.
local function bounds(f: Field): (number, number)
	local a = f.anchor
	if a == nil or a == f.cur then
		return f.cur, f.cur
	end
	return math.min(a, f.cur), math.max(a, f.cur)
end

-- Replaces characters [from, to) by `ins`, the caret after them. One undo step; typing
-- joins the open one. Returns whether the text changed.
local function replace(f: Field, from: number, to: number, ins: { string }, typing: boolean): boolean
	local chars = chars_of(f.text)
	local head = table.concat(chars, "", 1, from)
	local tail = table.concat(chars, "", to + 1)
	local max = f.max
	if max then
		while #ins > 0 and utf16_offset(head .. table.concat(ins) .. tail, math.huge) > max do
			table.remove(ins)
		end
	end
	local text = head .. table.concat(ins) .. tail
	if text == f.text then
		return false
	end
	if not (typing and f.typing) then
		table.insert(f.undo, { text = f.text, cur = f.cur })
		if #f.undo > HISTORY then
			table.remove(f.undo, 1)
		end
	end
	f.redo = {}
	f.typing = typing
	f.text, f.cur, f.anchor = text, from + #ins, nil
	return true
end

-- Steps back (redo = false) or forward through the field's history.
local function undo_step(f: Field, redo: boolean): boolean
	local from = if redo then f.redo else f.undo
	local snap = table.remove(from)
	if not snap then
		return false
	end
	table.insert(if redo then f.undo else f.redo, { text = f.text, cur = f.cur })
	f.text, f.cur, f.anchor, f.typing = snap.text, snap.cur, nil, false
	return true
end

-- Applies Tern's `edit` event: replace UTF-16 [from, to) by `text`, caret at `cursor`.
-- Returns "text", "caret", or nil when the event is stale (its `len` is not our text's).
local function apply_edit(f: Field, ev: UiEvent): string?
	if tonumber(ev.len) ~= utf16_offset(f.text, math.huge) then
		return nil
	end
	local from = char_index(f.text, tonumber(ev.from) or 0)
	local to = char_index(f.text, tonumber(ev.to) or 0)
	local ins = chars_of(tidy(f, if type(ev.text) == "string" then ev.text else ""))
	local changed = replace(f, from, to, ins, false)
	f.cur = char_index(f.text, tonumber(ev.cursor) or 0)
	f.anchor, f.typing = nil, false
	return if changed then "text" else "caret"
end

-- Applies a key to a field. Returns "text" (changed), "caret" (moved or selected), "submit"
-- (Enter in a single-line field), "blur" (Esc or Tab), or nil (the key is not for the field).
-- Tern turns keys that act on its own selection into `edit` events, so this sees the rest:
-- typing and deletes without a selection, word and line moves, ctrl+a, redo, and every
-- key on a selection the block drew itself.
local function edit_key(f: Field, key: Key, cx: BlockCx): string?
	local chars = chars_of(f.text)
	local n = #chars
	f.cur = math.clamp(f.cur, 0, n)
	local lo, hi = bounds(f)
	local name = key.name
	local mod = key.ctrl or key.meta
	local function remove(from: number, to: number): string
		return if replace(f, from, to, {}, false) then "text" else "caret"
	end
	local function go(to: number): string
		to = math.clamp(to, 0, n)
		if key.shift then
			f.anchor = f.anchor or f.cur
		else
			f.anchor = nil
		end
		f.cur, f.typing = to, false
		return "caret"
	end
	if name == "escape" or name == "tab" then
		return "blur"
	elseif name == "enter" then
		if not f.multiline then
			return "submit"
		end
		return if replace(f, lo, hi, { "\n" }, false) then "text" else "caret"
	elseif mod and not key.alt and name == "a" and not key.shift then
		-- A fresh node key drops Tern's retained native range before block select-all.
		f.anchor, f.cur, f.typing = 0, n, false
		f.rev += 1
		if f.id then
			f.id = string.gsub(f.id, "_%d+$", "_" .. f.rev)
			cx:frame({ { "focus", f.id } })
		end
		return "caret"
	elseif mod and not key.alt and name == "z" then
		return if undo_step(f, key.shift) then "text" else nil
	elseif key.ctrl and name == "y" then
		return if undo_step(f, true) then "text" else nil
	elseif mod and (name == "c" or name == "x") and lo ~= hi then
		cx:copy(table.concat(chars, "", lo + 1, hi))
		return if name == "x" then remove(lo, hi) else "caret"
	elseif name == "backspace" or (key.ctrl and (name == "u" or name == "w")) then
		if lo ~= hi then
			return remove(lo, hi)
		end
		-- cmd+backspace reaches the program as ctrl+u; ctrl+w and option+backspace delete a word.
		local to = f.cur - 1
		if key.meta or name == "u" then
			to = line_start(chars, f.cur)
			if to == f.cur then
				to = f.cur - 1
			end
		elseif key.alt or name == "w" then
			to = word_left(chars, f.cur)
		end
		return remove(math.max(0, to), f.cur)
	elseif name == "delete" or (key.ctrl and name == "k") then
		if lo ~= hi then
			return remove(lo, hi)
		end
		local to = f.cur + 1
		if key.meta or name == "k" then
			to = line_end(chars, f.cur)
			if to == f.cur then
				to = f.cur + 1
			end
		elseif key.alt then
			to = word_right(chars, f.cur)
		end
		return remove(f.cur, math.min(n, to))
	elseif name == "left" or (key.alt and name == "b") then
		if not key.shift and lo ~= hi and not key.alt and not mod then
			return go(lo)
		end
		if key.alt then
			return go(word_left(chars, f.cur))
		elseif mod then
			return go(if f.multiline then line_start(chars, f.cur) else 0)
		end
		return go(f.cur - 1)
	elseif name == "right" or (key.alt and name == "f") then
		if not key.shift and lo ~= hi and not key.alt and not mod then
			return go(hi)
		end
		if key.alt then
			return go(word_right(chars, f.cur))
		elseif mod then
			return go(if f.multiline then line_end(chars, f.cur) else n)
		end
		return go(f.cur + 1)
	elseif name == "home" then
		return go(if f.multiline and not mod then line_start(chars, f.cur) else 0)
	elseif name == "end" then
		return go(if f.multiline and not mod then line_end(chars, f.cur) else n)
	elseif key.ctrl and not key.alt and not key.meta and name == "e" then
		return go(if f.multiline then line_end(chars, f.cur) else n)
	elseif name == "up" then
		return go(0)
	elseif name == "down" then
		return go(n)
	end
	local typed = key.text
	if name == "space" and not typed then
		typed = " "
	end
	if name == "paste" or (typed and typed ~= "" and not (key.ctrl or key.alt or key.meta)) then
		local ins = chars_of(tidy(f, typed or ""))
		return if replace(f, lo, hi, ins, name ~= "paste") then "text" else "caret"
	end
	return nil
end

-- A text field node whose text, caret and selection come from `f` while it is being
-- edited, else from `idle` with the caret at its end. `id` is the node's full path; the
-- rev suffix makes a fresh node (dropping Tern's retained range) after a reset.
local function field_node(kind: string, props: { [string]: any }, f: Field?, idle: string, id: string): Node
	if f then
		f.id = id .. "_" .. f.rev
		props.key ..= "_" .. f.rev
		props.text = f.text
		props.cursor = utf16_offset(f.text, f.cur)
		if f.anchor and f.anchor ~= f.cur then
			props.anchor = utf16_offset(f.text, f.anchor)
		end
	else
		props.text = idle
		props.cursor = utf16_offset(idle, math.huge)
	end
	return tern.ui.node(kind, props)
end

M.new = new_field
M.reset = reset_field
M.apply_edit = apply_edit
M.undo_step = undo_step
M.edit_key = edit_key
M.node = field_node
M.length_of = length_of

return M
