-- Context menu content inside MapMenu's "info_context" frame: the "Swap crew"
-- entry appended to vanilla's person context, the "Recruit from crew" entry for
-- empty posts, and the replacement selection list.
--
-- State lives in menu.contextMenuData.swapcrew:
--   { stage = "entry" | "select", emptypost = postid?, target = t,
--     candidates = list, counts = table, error = string? }

local ffi = require("ffi")
local C = ffi.C

SwapCrew = SwapCrew or {}
local D = {}
SwapCrew.dialog = D

local TXT_SWAP = 10
local TXT_RECRUIT = 11
local TXT_SELECT = 20
local TXT_BEST = 21
local TXT_OR_BETTER = 23
local TXT_AVAILABLE = 24
local TXT_NONE = 25
local TXT_CURRENT = 26
local TXT_PICK = 27
local TXT_FAILED = 40
local TXT_NO_CREW = 42

local function text(id)
	return SwapCrew.text(id)
end

local function newTable(menu, frame)
	return frame:addTable(1, { tabOrder = 3, x = Helper.borderSize, y = Helper.borderSize, width = menu.contextMenuData.width, highlightMode = "off" })
end

local function addTitle(ftable, title)
	local row = ftable:addRow(false, { fixed = true, bgColor = Color["row_background_blue"] })
	row[1]:createText(title, Helper.headerRowCenteredProperties)
end

local function addButton(ftable, id, label, active, mouseover, onClick)
	local row = ftable:addRow(id, { fixed = true })
	row[1]:createButton({ bgColor = Color["button_background_hidden"], height = Helper.standardTextHeight, active = active, mouseOverText = mouseover }):setText(label)
	row[1].handlers.onClick = onClick
	return row
end

-- Same frame position fix-up vanilla menu.createInfoContext ends with.
local function fitFrame(menu, frame, ftable)
	local neededheight = ftable.properties.y + ftable:getVisibleHeight()
	if frame.properties.y + neededheight + Helper.frameBorder > Helper.viewHeight then
		menu.contextMenuData.yoffset = Helper.viewHeight - neededheight - Helper.frameBorder
		frame.properties.y = menu.contextMenuData.yoffset
	end
end

local function rerender(menu)
	menu.contextMenuMode = "info_context"
	menu.createContextFrame()
end

-- Switches the open context to the selection list for target t.
function D.openSelect(menu, t)
	local candidates = SwapCrew.candidates.collect(t)
	local data = menu.contextMenuData.swapcrew or {}
	data.stage = "select"
	data.target = t
	data.candidates = candidates
	data.counts = SwapCrew.model.counts(candidates)
	data.error = nil
	menu.contextMenuData.swapcrew = data
	SwapCrew.log("dialog: %d candidates for %s", #candidates, SwapCrew.target.describe(t))
	rerender(menu)
end

local function choose(menu, choice)
	local data = menu.contextMenuData.swapcrew
	local t = data.target
	-- the world may have moved on since the list was drawn
	local candidates = SwapCrew.candidates.collect(t)
	local cand = SwapCrew.model.pick(candidates, choice)
	if not cand then
		data.candidates = candidates
		data.counts = SwapCrew.model.counts(candidates)
		data.error = text(TXT_NO_CREW)
		rerender(menu)
		return
	end
	SwapCrew.log("pick %s: %s skill=%d stars=%d on %s (%s)", tostring(choice), cand.name, cand.skill, SwapCrew.model.stars(cand.skill), cand.shipName, tostring(cand.ship))
	local ok, reason = SwapCrew.executor.run(t, cand)
	if ok then
		menu.closeContextMenu()
	else
		data.error = string.format(text(TXT_FAILED), tostring(reason))
		rerender(menu)
	end
end

local function candidateHint(cand)
	if not cand then
		return text(TXT_NONE)
	end
	return string.format(text(TXT_PICK), cand.name, cand.shipName, Helper.displaySkill(math.floor(cand.skill * 15 / 100)))
end

local function renderSelect(menu, frame, data)
	local t = data.target
	local ftable = newTable(menu, frame)
	addTitle(ftable, (t.kind == "post_empty") and text(TXT_RECRUIT) or (text(TXT_SELECT) .. ": " .. (t.name or "")))

	local current = SwapCrew.target.currentSkill(t)
	if current then
		local row = ftable:addRow(false, { fixed = true })
		row[1]:createText(text(TXT_CURRENT) .. " " .. Helper.displaySkill(math.floor(current * 15 / 100)), { color = Color["text_skills"] })
	end

	local counts = data.counts
	local row = addButton(ftable, "swapcrew_best", text(TXT_BEST), counts.best > 0, candidateHint(SwapCrew.model.pick(data.candidates, "best")), function() return choose(menu, "best") end)
	row[1]:setText2(string.format(text(TXT_AVAILABLE), counts.best), { halign = "right" })
	for n = SwapCrew.model.MAX_STARS, 1, -1 do
		local label = Helper.displaySkill(n * 3, false, true) .. " " .. text(TXT_OR_BETTER)
		local row = addButton(ftable, "swapcrew_stars" .. n, label, counts[n] > 0, candidateHint(SwapCrew.model.pick(data.candidates, n)), function() return choose(menu, n) end)
		row[1]:setText2(string.format(text(TXT_AVAILABLE), counts[n]), { halign = "right" })
	end

	if data.error then
		local row = ftable:addRow(false, { fixed = true })
		row[1]:createText(data.error, { color = Color["text_error"], wordwrap = true })
	end
	fitFrame(menu, frame, ftable)
end

local function renderEntry(menu, frame, data)
	local t = SwapCrew.target.fromContext(menu.contextMenuData)
	local ftable = newTable(menu, frame)
	local post = data.emptypost
	local title = (post == "manager") and ReadText(20208, 30301) or (C.IsComponentClass(menu.contextMenuData.component, "ship_s") and ReadText(1001, 4847) or ReadText(1001, 4848))
	addTitle(ftable, title)
	local ok, reason = false, SwapCrew.target.REASON_POST
	if t then
		ok, reason = SwapCrew.target.check(t)
	end
	addButton(ftable, "swapcrew_recruit", text(TXT_RECRUIT), ok, (not ok) and text(reason) or nil, function() return D.openSelect(menu, t) end)
	fitFrame(menu, frame, ftable)
end

-- Draws our content when the info context belongs to Swap Crew. Returns true
-- when it did, so the caller skips vanilla's content.
function D.render(menu, frame)
	local data = menu.contextMenuData and menu.contextMenuData.swapcrew
	if not data then
		return false
	end
	if data.stage == "select" then
		renderSelect(menu, frame, data)
	else
		renderEntry(menu, frame, data)
	end
	return true
end

-- Appends "Swap crew" to vanilla's person context (already built in frame).
function D.appendEntry(menu, frame)
	local t = SwapCrew.target.fromContext(menu.contextMenuData)
	if not t then
		return
	end
	local ftable
	for i = #frame.content, 1, -1 do
		local widget = frame.content[i]
		if widget.type == "table" and widget.numcolumns == 1 then
			ftable = widget
			break
		end
	end
	if not ftable then
		SwapCrew.log("appendEntry: vanilla context table not found")
		return
	end
	local ok, reason = SwapCrew.target.check(t)
	addButton(ftable, "swapcrew_entry", text(TXT_SWAP), ok, (not ok) and text(reason) or nil, function() return D.openSelect(menu, t) end)
	fitFrame(menu, frame, ftable)
end

return D
