-- The "Candidate" card of the selection dialog: who the cursor points at, their
-- skills for the target post or role, and the buttons that move the cursor.
--
-- data is menu.contextMenuData.promotespecialist (see dialog.lua): data.pool is the
-- filtered candidate list best first, data.cursor an index into it.

PromoteSpecialist = PromoteSpecialist or {}
local Card = {}
PromoteSpecialist.card = Card

local TXT_NONE = 25
local TXT_CANDIDATE = 29
local TXT_ROLE = { service = 35, marine = 36, pilot = 57, manager = 60 }
local TXT_ON_SHIP = 37
local TXT_ABOARD = 38
local TXT_SAME_SECTOR = 39
local TXT_LEAVES_EMPTY = 58
local TXT_LEAVES_NO_MANAGER = 61

local function text(id)
	return PromoteSpecialist.text(id)
end

local function location(cand)
	local where = string.format(text(TXT_ON_SHIP), cand.shipName)
	if cand.sameShip then
		return where .. ", " .. text(TXT_ABOARD)
	elseif cand.sameSector then
		return where .. ", " .. text(TXT_SAME_SECTOR)
	end
	return where
end

-- Fills ftable (4 columns) with the card; onMove(index) moves the cursor.
function Card.render(ftable, data, onMove)
	local total = #data.pool
	local cand = data.pool[data.cursor]

	local row = ftable:addRow(false, { fixed = true, bgColor = Color["row_background_blue"] })
	row[1]:setColSpan(3):createText(text(TXT_CANDIDATE), Helper.headerRowCenteredProperties)
	row[4]:createText(cand and string.format("%d/%d", data.cursor, total) or "", { halign = "right", font = Helper.headerRowCenteredProperties.font, fontsize = Helper.headerRowCenteredProperties.fontsize })

	if not cand then
		local row = ftable:addRow(false, { fixed = true })
		row[1]:setColSpan(4):createText(text(TXT_NONE), { color = Color["text_inactive"], wordwrap = true })
		return
	end

	local row = ftable:addRow(false, { fixed = true })
	row[1]:setColSpan(3):createText(cand.name, { font = Helper.standardFontBold })
	row[4]:createText(Helper.displaySkill(math.floor(cand.skill * 15 / 100)), { halign = "right", color = Color["text_skills"] })
	local row = ftable:addRow(false, { fixed = true })
	row[1]:setColSpan(4):createText(text(TXT_ROLE[cand.role] or TXT_ROLE.service) .. " - " .. location(cand), { color = Color["text_inactive"], wordwrap = true })

	if cand.sourcePost == "aipilot" and data.target.kind == "post_empty" and not PromoteSpecialist.candidates.bestCrew(cand.ship, "aipilot") then
		-- nobody aboard the candidate's ship can take over as pilot
		local row = ftable:addRow(false, { fixed = true })
		row[1]:setColSpan(4):createText(string.format(text(TXT_LEAVES_EMPTY), cand.shipName), { color = Color["text_warning"], wordwrap = true })
	end

	if cand.sourcePost == "manager" and data.target.kind == "post_empty" then
		-- nobody comes back to the candidate's station when the target was empty
		local row = ftable:addRow(false, { fixed = true })
		row[1]:setColSpan(4):createText(string.format(text(TXT_LEAVES_NO_MANAGER), cand.shipName), { color = Color["text_warning"], wordwrap = true })
	end

	for _, skill in ipairs(PromoteSpecialist.candidates.skills(data.target, cand)) do
		local mouseover = ReadText(1013, skill.descriptionid)
		local row = ftable:addRow(false, { fixed = true, bgColor = Color["row_background_unselectable"] })
		row[1]:setColSpan(3):createText(ReadText(1013, skill.textid), { font = skill.relevant and Helper.standardFontBold or nil, color = skill.relevant and Color["text_normal"] or Color["text_inactive"], mouseOverText = mouseover })
		row[4]:createText(Helper.displaySkill(skill.value, skill.relevant), { halign = "right", color = skill.relevant and Color["text_skills"] or Color["text_skills_irrelevant"], mouseOverText = mouseover })
	end

	local buttons = {
		-- best, previous, next, worst
		{ "<<", 1, data.cursor > 1 },
		{ "<", data.cursor - 1, data.cursor > 1 },
		{ ">", data.cursor + 1, data.cursor < total },
		{ ">>", data.worst, data.cursor ~= data.worst },
	}
	local row = ftable:addRow("promotespecialist_cycle", { fixed = true })
	for i, button in ipairs(buttons) do
		local target = button[2]
		row[i]:createButton({ active = button[3], height = Helper.standardTextHeight }):setText(button[1], { halign = "center" })
		row[i].handlers.onClick = function() return onMove(target) end
	end
end

return Card
