-- Installs Promote Specialist into MapMenu by wrapping menu fields. Vanilla (and
-- kuertee's UI extensions) always call these through `menu.`, so wrapping
-- works with or without UIX.
--
--   setupCrewInfoSubmenuRows  make the empty pilot/manager row right-clickable
--   prepareInfoContext        open our context for that row
--   createInfoContext         draw our dialog, or append "Promote specialist" to vanilla's
--   onInteractMenuCallback    open the dialog for a ship or station (interact_hooks.lua)

local ffi = require("ffi")
local C = ffi.C

PromoteSpecialist = PromoteSpecialist or {}
local H = {}
PromoteSpecialist.hooks = H

local EMPTY_ROW_KIND = "promotespecialist_emptypost"
local TXT_EMPTY_HINT = 30

local mapMenu
local warnedLayout = {}

function PromoteSpecialist.refresh()
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
	local object = PromoteSpecialist.id64(inputobject)
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
			PromoteSpecialist.log("empty %s row not found, layout changed by another mod? Promote specialist unavailable there", post)
		end
		return
	end
	local isButtonRow = row.rowdata == "ReplacePilot"
	row.rowdata = { EMPTY_ROW_KIND, post, object }
	if not isButtonRow then
		row.properties.bgColor = nil
		local cell = row[nameColumn]
		if cell and cell.type == "text" then
			cell.properties.mouseOverText = PromoteSpecialist.text(TXT_EMPTY_HINT)
		end
	end
end

local function install(menu)
	if menu.promoteSpecialistInstalled then
		return
	end
	menu.promoteSpecialistInstalled = true
	mapMenu = menu

	local origSetupCrew = menu.setupCrewInfoSubmenuRows
	menu.setupCrewInfoSubmenuRows = function(mode, inputtable, inputobject, instance, ...)
		local firstIndex = #inputtable.rows + 1
		local results = { origSetupCrew(mode, inputtable, inputobject, instance, ...) }
		local ok, err = pcall(markEmptyPosts, mode, inputtable, inputobject, firstIndex)
		if not ok then
			PromoteSpecialist.log("error marking empty posts: %s", tostring(err))
		end
		return unpack(results)
	end

	local origPrepare = menu.prepareInfoContext
	menu.prepareInfoContext = function(rowdata, instance, ...)
		if type(rowdata) == "table" and rowdata[1] == EMPTY_ROW_KIND then
			local x, y = GetLocalMousePosition()
			local xoffset = x and (x + Helper.viewWidth / 2) or (Helper.viewWidth / 2)
			local yoffset = y and (Helper.viewHeight / 2 - y) or (Helper.viewHeight / 2)
			menu.contextMenuData = { component = rowdata[3], xoffset = xoffset, yoffset = yoffset, instance = instance, promotespecialist = { stage = "entry", emptypost = rowdata[2] } }
			menu.contextMenuMode = "info_context"
			menu.createContextFrame(menu.selectWidth)
			return
		end
		return origPrepare(rowdata, instance, ...)
	end

	local origCreateInfo = menu.createInfoContext
	menu.createInfoContext = function(frame, ...)
		if menu.contextMenuData and menu.contextMenuData.promotespecialist then
			local ok, err = pcall(PromoteSpecialist.dialog.render, menu, frame)
			if not ok then
				PromoteSpecialist.log("error drawing dialog: %s", tostring(err))
			end
			return
		end
		local results = { origCreateInfo(frame, ...) }
		local ok, err = pcall(PromoteSpecialist.dialog.appendEntry, menu, frame)
		if not ok then
			PromoteSpecialist.log("error adding Promote specialist entry: %s", tostring(err))
		end
		return unpack(results)
	end

	-- "Promote specialist" chosen in the interact menu of a ship or station
	local origInteractCallback = menu.onInteractMenuCallback
	menu.onInteractMenuCallback = function(type, param, ...)
		if type == PromoteSpecialist.interact.CALLBACK then
			local ok, err = pcall(function()
				local t = PromoteSpecialist.target.forObject(param[1])
				if t then
					PromoteSpecialist.dialog.openFor(menu, t)
				end
			end)
			if not ok then
				PromoteSpecialist.log("error opening dialog from interact menu: %s", tostring(err))
			end
			return
		end
		return origInteractCallback(type, param, ...)
	end

	PromoteSpecialist.log("hooks installed into MapMenu (uix=%s)", tostring(menu.registerCallback ~= nil))
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
		PromoteSpecialist.scheduler.after(1, "install", tryInstall)
	else
		PromoteSpecialist.log("MapMenu not found, Promote Specialist is inactive")
	end
end

tryInstall()

return H
