-- Context menu content inside MapMenu's "info_context" frame: the "Promote
-- specialist" entry appended to vanilla's person context or shown for empty
-- posts, and the selection dialog (current person, crew roles to choose from,
-- star filter, candidate card, promote button).
--
-- State lives in menu.contextMenuData.promotespecialist:
--   { stage = "entry" | "select", emptypost = postid?, target = t,
--     sorted = candidates best first, counts = table, filter = "any" | 1-5,
--     pool = sorted narrowed by filter, cursor = index into pool,
--     worst = index into pool, stay = bool, error = string? }

local ffi = require("ffi")
local C = ffi.C

PromoteSpecialist = PromoteSpecialist or {}
local D = {}
PromoteSpecialist.dialog = D

local TXT_PROMOTE = 10
local TXT_PROMOTE_EMPTY = 11
local TXT_TITLE = 20
local TXT_ANY = 21
local TXT_AVAILABLE = 24
local TXT_CURRENT = 26
local TXT_CHOOSE_FROM = 28
local TXT_STAY = 31
local TXT_STAY_PILOT = 34
local TXT_SWAP = 32
local TXT_PROMOTE_NAME = 33
local TXT_SOURCE = { service = 50, marine = 51, pilot = 52, manager = 53 }
local TXT_FAILED = 40
local TXT_GONE = 42

-- Width of the selection dialog (the entry uses MapMenu's selectWidth).
local SELECT_WIDTH = 400
-- Gap above the promote button and its height, in unscaled pixels.
local PROMOTE_GAP = 12
local PROMOTE_HEIGHT = 24

-- Crew roles to choose from, kept for the rest of the session.
local sources = { service = true, pilot = false, manager = false, marine = false }

-- Toggle rows in dialog order; a source the target cannot use is shown
-- inactive (see candidates.sourceUnavailable).
local SOURCE_ORDER = { "service", "pilot", "manager", "marine" }

local function text(id)
	return PromoteSpecialist.text(id)
end

-- Returns a function that adds frame tables top to bottom, optionally with an
-- extra gap above.
local function stacker(menu, frame)
	local last
	local tabOrder = 3
	return function(numcols, gap)
		local y = last and (last.properties.y + last:getVisibleHeight() + Helper.borderSize) or Helper.borderSize
		y = y + (gap or 0)
		last = frame:addTable(numcols, { tabOrder = tabOrder, x = Helper.borderSize, y = y, width = menu.contextMenuData.width, highlightMode = "off" })
		tabOrder = tabOrder + 1
		return last
	end
end

local function addTitle(ftable, title, colspan)
	local row = ftable:addRow(false, { fixed = true, bgColor = Color["row_background_blue"] })
	row[1]:setColSpan(colspan or 1):createText(title, Helper.headerRowCenteredProperties)
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

local function rerender(menu, width)
	local cmd = menu.contextMenuData
	if width and cmd.xoffset and (cmd.xoffset + width + Helper.frameBorder > Helper.viewWidth) then
		-- keep the full width by moving left, instead of letting vanilla shrink it
		cmd.xoffset = math.max(0, Helper.viewWidth - width - Helper.frameBorder)
	end
	menu.contextMenuMode = "info_context"
	menu.createContextFrame(width)
end

-- Narrows data.sorted to data.filter and keeps the cursor on keepKey when that
-- person is still in the pool, else on its best candidate.
local function applyFilter(data, keepKey)
	local model = PromoteSpecialist.model
	data.pool = model.filter(data.sorted, data.filter)
	data.worst = model.pickIndex(data.pool, "worst")
	data.cursor = model.indexOf(data.pool, keepKey) or model.pickIndex(data.pool, "best")
end

-- Collects candidates for data.target, then applies the filter.
local function refreshCandidates(data, keepKey)
	local candidates = PromoteSpecialist.candidates.collect(data.target, sources)
	data.sorted = PromoteSpecialist.model.sorted(candidates)
	data.counts = PromoteSpecialist.model.counts(candidates)
	applyFilter(data, keepKey)
end

local function cursorKey(data)
	local cand = data.pool and data.cursor and data.pool[data.cursor]
	return cand and cand.key
end

-- Switches the open context to the selection dialog for target t.
function D.openSelect(menu, t)
	local data = menu.contextMenuData.promotespecialist or {}
	data.stage = "select"
	data.target = t
	data.stay = false
	data.filter = "any"
	data.error = nil
	refreshCandidates(data)
	menu.contextMenuData.promotespecialist = data
	PromoteSpecialist.log("dialog: %d candidates for %s", #data.sorted, PromoteSpecialist.target.describe(t))
	rerender(menu, Helper.scaleX(SELECT_WIDTH))
end

local function moveCursor(menu, index)
	local data = menu.contextMenuData.promotespecialist
	if index and data.pool[index] then
		data.cursor = index
		data.error = nil
	end
	rerender(menu)
end

local function toggleSource(menu, source)
	local data = menu.contextMenuData.promotespecialist
	sources[source] = not sources[source]
	data.error = nil
	refreshCandidates(data, cursorKey(data))
	rerender(menu)
end

-- Clicking the active filter again goes back to "any".
local function setFilter(menu, filter)
	local data = menu.contextMenuData.promotespecialist
	data.filter = (data.filter == filter) and "any" or filter
	data.error = nil
	applyFilter(data, cursorKey(data))
	rerender(menu)
end

local function setStay(menu, stay)
	menu.contextMenuData.promotespecialist.stay = stay
	rerender(menu)
end

local function promote(menu)
	local data = menu.contextMenuData.promotespecialist
	local t = data.target
	local key = cursorKey(data)
	-- the world may have moved on since the dialog was drawn
	refreshCandidates(data, key)
	local cand = data.pool[PromoteSpecialist.model.indexOf(data.pool, key) or 0]
	if not cand then
		data.error = text(TXT_GONE)
		rerender(menu)
		return
	end
	PromoteSpecialist.log("promote %s (%s): skill=%d stars=%d on %s (%s), stay=%s", cand.name, cand.role, cand.skill, PromoteSpecialist.model.stars(cand.skill), cand.shipName, tostring(cand.ship), tostring(data.stay))
	local ok, reason = PromoteSpecialist.executor.run(t, cand, { stay = data.stay })
	if ok then
		menu.closeContextMenu()
	else
		data.error = string.format(text(TXT_FAILED), tostring(reason))
		rerender(menu)
	end
end

local function addRadio(ftable, label, checked, active, mouseover, onClick)
	local row = ftable:addRow(true, { fixed = true })
	row[1]:createCheckBox(checked, { width = Helper.standardTextHeight, height = Helper.standardTextHeight, active = active })
	row[1].handlers.onClick = onClick
	row[2]:setColSpan(3):createText(label, { color = (not active) and Color["text_inactive"] or nil, mouseOverText = mouseover, wordwrap = true })
end

-- Title, current person, stay/swap choice and crew role toggles (4 columns:
-- checkbox, label, checkbox, label).
local function renderHeader(menu, ftable, data)
	local t = data.target
	local box = Helper.standardTextHeight
	ftable:setColWidth(1, box, false)
	ftable:setColWidth(3, box, false)
	local hasName = t.name and t.name ~= ""
	addTitle(ftable, hasName and string.format(text(TXT_TITLE), t.name) or text(TXT_PROMOTE), 4)

	local current = PromoteSpecialist.target.currentSkill(t)
	if current then
		local row = ftable:addRow(false, { fixed = true })
		row[1]:setColSpan(3):createText(text(TXT_CURRENT) .. " " .. (t.name or ""))
		row[4]:createText(Helper.displaySkill(math.floor(current * 15 / 100)), { halign = "right", color = Color["text_skills"] })
	end

	-- no choice to make for an empty post, or for service crew (who would
	-- "stay" as what they already are)
	local cand = data.pool[data.cursor]
	-- no choice for an empty post, for service crew (who would "stay" as what
	-- they already are), or for a manager (who always swaps, see
	-- manager_move.lua)
	local noChoice = t.kind == "post_empty" or (t.kind == "crew" and t.role == "service") or (cand and cand.sourcePost == "manager")
	if noChoice then
		data.stay = false
	else
		local canStay, why = PromoteSpecialist.target.checkStay(t, cand)
		if data.stay and not canStay then
			data.stay = false
		end
		local stayLabel = (cand and cand.sourcePost == "aipilot") and text(TXT_STAY_PILOT) or text(TXT_STAY)
		addRadio(ftable, text(TXT_SWAP), not data.stay, true, nil, function() return setStay(menu, false) end)
		addRadio(ftable, stayLabel, data.stay, canStay, (not canStay) and text(why) or nil, function() return setStay(menu, true) end)
	end

	local row = ftable:addRow(false, { fixed = true })
	row[1]:setColSpan(4):createText(text(TXT_CHOOSE_FROM), Helper.subHeaderTextProperties)
	for i = 1, #SOURCE_ORDER, 2 do
		local row = ftable:addRow(true, { fixed = true })
		for j = 0, 1 do
			local source = SOURCE_ORDER[i + j]
			if source then
				local why = PromoteSpecialist.candidates.sourceUnavailable(t, source)
				local available = not why
				local col = 1 + 2 * j
				row[col]:createCheckBox(available and (sources[source] or false), { width = box, height = box, active = available })
				row[col].handlers.onClick = function() return toggleSource(menu, source) end
				row[col + 1]:createText(text(TXT_SOURCE[source]), { color = (not available) and Color["text_inactive"] or nil, mouseOverText = why and text(why) or nil })
			end
		end
	end
end

-- Star filter rows (exactly N stars) and "any"; the active one is highlighted.
local function renderFilter(menu, ftable, data)
	local counts = data.counts
	local function filterRow(id, label, filter, count)
		local selected = data.filter == filter
		local row = ftable:addRow(id, { fixed = true })
		row[1]:createButton({ bgColor = selected and Color["row_background_selected"] or Color["button_background_hidden"], height = Helper.standardTextHeight, active = selected or count > 0 }):setText(label)
		row[1]:setText2(string.format(text(TXT_AVAILABLE), count), { halign = "right" })
		row[1].handlers.onClick = function() return setFilter(menu, filter) end
	end
	for n = PromoteSpecialist.model.MAX_STARS, 1, -1 do
		filterRow("promotespecialist_stars" .. n, Helper.displaySkill(n * 3, false, true), n, counts[n])
	end
	filterRow("promotespecialist_any", text(TXT_ANY), "any", counts.any)
end

local function renderFooter(menu, ftable, data)
	local cand = data.pool[data.cursor]
	local label = cand and string.format(text(TXT_PROMOTE_NAME), cand.name) or text(TXT_PROMOTE)
	local row = ftable:addRow("promotespecialist_promote", { fixed = true })
	row[1]:createButton({ active = cand ~= nil, height = Helper.scaleY(PROMOTE_HEIGHT) }):setText(label, { halign = "center", fontsize = Helper.headerRow1FontSize })
	row[1].handlers.onClick = function() return promote(menu) end
	if data.error then
		local row = ftable:addRow(false, { fixed = true })
		row[1]:createText(data.error, { color = Color["text_error"], wordwrap = true })
	end
end

local function renderSelect(menu, frame, data)
	local nextTable = stacker(menu, frame)
	renderHeader(menu, nextTable(4), data)
	renderFilter(menu, nextTable(1), data)
	PromoteSpecialist.card.render(nextTable(4), data, function(index) return moveCursor(menu, index) end)
	local footer = nextTable(1, Helper.scaleY(PROMOTE_GAP))
	renderFooter(menu, footer, data)
	fitFrame(menu, frame, footer)
end

local function renderEntry(menu, frame, data)
	local t = PromoteSpecialist.target.fromContext(menu.contextMenuData)
	local nextTable = stacker(menu, frame)
	local ftable = nextTable(1)
	local post = data.emptypost
	local title = (post == "manager") and ReadText(20208, 30301) or (C.IsComponentClass(menu.contextMenuData.component, "ship_s") and ReadText(1001, 4847) or ReadText(1001, 4848))
	addTitle(ftable, title)
	local ok, reason = false, PromoteSpecialist.target.REASON_POST
	if t then
		ok, reason = PromoteSpecialist.target.check(t)
	end
	addButton(ftable, "promotespecialist_recruit", text(TXT_PROMOTE_EMPTY), ok, (not ok) and text(reason) or nil, function() return D.openSelect(menu, t) end)
	fitFrame(menu, frame, ftable)
end

-- Draws our content when the info context belongs to Promote Specialist. Returns true
-- when it did, so the caller skips vanilla's content.
function D.render(menu, frame)
	local data = menu.contextMenuData and menu.contextMenuData.promotespecialist
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

-- Opens the selection dialog for t in MapMenu's info context at the mouse
-- position (used for ships and stations from the interact menu).
function D.openFor(menu, t)
	local x, y = GetLocalMousePosition()
	local xoffset = x and (x + Helper.viewWidth / 2) or (Helper.viewWidth / 2)
	local yoffset = y and (Helper.viewHeight / 2 - y) or (Helper.viewHeight / 2)
	menu.contextMenuData = { component = t.container, xoffset = xoffset, yoffset = yoffset, promotespecialist = {} }
	D.openSelect(menu, t)
end

-- Appends "Promote specialist" to vanilla's person context (already built in frame).
function D.appendEntry(menu, frame)
	local t = PromoteSpecialist.target.fromContext(menu.contextMenuData)
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
		PromoteSpecialist.log("appendEntry: vanilla context table not found")
		return
	end
	local ok, reason = PromoteSpecialist.target.check(t)
	addButton(ftable, "promotespecialist_entry", text(TXT_PROMOTE), ok, (not ok) and text(reason) or nil, function() return D.openSelect(menu, t) end)
	fitFrame(menu, frame, ftable)
end

return D
