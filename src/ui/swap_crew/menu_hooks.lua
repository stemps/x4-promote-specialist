-- Installs Swap Crew into MapMenu by wrapping menu fields. Vanilla (and
-- kuertee's UI extensions) always call these through `menu.`, so wrapping
-- works with or without UIX.
--
--   setupCrewInfoSubmenuRows  make the empty pilot/manager row right-clickable
--   prepareInfoContext        open our context for that row
--   createInfoContext         draw our dialog, or append "Swap crew" to vanilla's

local ffi = require("ffi")
local C = ffi.C

SwapCrew = SwapCrew or {}
local H = {}
SwapCrew.hooks = H

local EMPTY_ROW_KIND = "swapcrew_emptypost"
local TXT_EMPTY_HINT = 30

local mapMenu
local warnedLayout = {}

function SwapCrew.refresh()
	if mapMenu then
		mapMenu.updatePeopleInfo = getElapsedTime() + 0.5
	end
end

local function isDashText(cell)
	return cell and cell.type == "text" and cell.properties.text == "-"
end

-- The empty post row is the first unselectable row added by the call whose
-- name and skill cells both read "-" (menu_map.lua: pilot uses columns 1 and 6,
-- manager uses columns 2 and 6).
local function findEmptyRow(inputtable, firstIndex, nameColumn)
	for i = firstIndex, #inputtable.rows do
		local row = inputtable.rows[i]
		if row.rowdata == false and isDashText(row[nameColumn]) and isDashText(row[6]) then
			return row
		end
	end
	return nil
end

local function markEmptyPosts(mode, inputtable, inputobject, firstIndex)
	local object = SwapCrew.id64(inputobject)
	if not GetComponentData(object, "isplayerowned") then
		return
	end
	local post, nameColumn
	if mode == "ship" and not GetComponentData(object, "assignedpilot") and not C.IsComponentClass(object, "ship_xs") then
		post, nameColumn = "aipilot", 1
	elseif mode == "station" and not GetComponentData(object, "tradenpc") then
		post, nameColumn = "manager", 2
	end
	if not post then
		return
	end
	local row = findEmptyRow(inputtable, firstIndex, nameColumn)
	if not row and post == "aipilot" then
		-- fallback anchor: vanilla's "Promote best crewmember to" button row
		for i = firstIndex, #inputtable.rows do
			if inputtable.rows[i].rowdata == "ReplacePilot" then
				row = inputtable.rows[i]
				break
			end
		end
	end
	if not row then
		if not warnedLayout[post] then
			warnedLayout[post] = true
			SwapCrew.log("empty %s row not found, layout changed by another mod? Recruit from crew unavailable there", post)
		end
		return
	end
	local isButtonRow = row.rowdata == "ReplacePilot"
	row.rowdata = { EMPTY_ROW_KIND, post, object }
	if not isButtonRow then
		row.properties.bgColor = nil
		local cell = row[nameColumn]
		if cell and cell.type == "text" then
			cell.properties.mouseOverText = SwapCrew.text(TXT_EMPTY_HINT)
		end
	end
end

local function install(menu)
	if menu.swapCrewInstalled then
		return
	end
	menu.swapCrewInstalled = true
	mapMenu = menu

	local origSetupCrew = menu.setupCrewInfoSubmenuRows
	menu.setupCrewInfoSubmenuRows = function(mode, inputtable, inputobject, instance, ...)
		local firstIndex = #inputtable.rows + 1
		local results = { origSetupCrew(mode, inputtable, inputobject, instance, ...) }
		local ok, err = pcall(markEmptyPosts, mode, inputtable, inputobject, firstIndex)
		if not ok then
			SwapCrew.log("error marking empty posts: %s", tostring(err))
		end
		return unpack(results)
	end

	local origPrepare = menu.prepareInfoContext
	menu.prepareInfoContext = function(rowdata, instance, ...)
		if type(rowdata) == "table" and rowdata[1] == EMPTY_ROW_KIND then
			local x, y = GetLocalMousePosition()
			local xoffset = x and (x + Helper.viewWidth / 2) or (Helper.viewWidth / 2)
			local yoffset = y and (Helper.viewHeight / 2 - y) or (Helper.viewHeight / 2)
			menu.contextMenuData = { component = rowdata[3], xoffset = xoffset, yoffset = yoffset, instance = instance, swapcrew = { stage = "entry", emptypost = rowdata[2] } }
			menu.contextMenuMode = "info_context"
			menu.createContextFrame(menu.selectWidth)
			return
		end
		return origPrepare(rowdata, instance, ...)
	end

	local origCreateInfo = menu.createInfoContext
	menu.createInfoContext = function(frame, ...)
		if menu.contextMenuData and menu.contextMenuData.swapcrew then
			local ok, err = pcall(SwapCrew.dialog.render, menu, frame)
			if not ok then
				SwapCrew.log("error drawing dialog: %s", tostring(err))
			end
			return
		end
		local results = { origCreateInfo(frame, ...) }
		local ok, err = pcall(SwapCrew.dialog.appendEntry, menu, frame)
		if not ok then
			SwapCrew.log("error adding Swap crew entry: %s", tostring(err))
		end
		return unpack(results)
	end

	SwapCrew.log("hooks installed into MapMenu (uix=%s)", tostring(menu.registerCallback ~= nil))
end

local attempts = 0
local function tryInstall()
	local menu = Helper.getMenu("MapMenu")
	if menu then
		install(menu)
		return
	end
	attempts = attempts + 1
	if attempts <= 20 then
		SwapCrew.scheduler.after(1, "install", tryInstall)
	else
		SwapCrew.log("MapMenu not found, Swap Crew is inactive")
	end
end

tryInstall()

return H
