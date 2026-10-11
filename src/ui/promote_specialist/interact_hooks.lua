-- Adds "Promote specialist" to the interact menu (right-click) of player-owned
-- ships and stations opened from the map. It wraps InteractMenu.prepareActions
-- the same way sn_mod_support_apis does, so both chain.
--
-- The action leaves the interact menu like vanilla's "Comm" entry
-- (menu_interactmenu.lua buttonComm) and hands the object back to MapMenu with
-- the callback type below, which menu_hooks.lua turns into the dialog.

local ffi = require("ffi")
local C = ffi.C

PromoteSpecialist = PromoteSpecialist or {}
local I = {}
PromoteSpecialist.interact = I

I.CALLBACK = "promotespecialist_promote"

local TXT_PROMOTE = 10
-- config.layer of menu_interactmenu.lua (a file local, not reachable from here)
local INTERACT_LAYER = 2

local function leaveTo(menu, component)
	Helper.resetUpdateHandler()
	Helper.clearFrame(menu, INTERACT_LAYER)
	Helper.returnFromInteractMenu(menu.currentOverTable, I.CALLBACK, { component })
	menu.cleanup()
end

local function addAction(menu)
	-- only when opened from the map (not the cockpit), with its main section
	if menu.shown or not (menu.actions and menu.actions.main and menu.componentSlot) then
		return
	end
	local component = PromoteSpecialist.id64(menu.componentSlot.component)
	if component == 0 or not C.IsComponentClass(component, "controllable") then
		return
	end
	local t = PromoteSpecialist.target.forObject(component)
	if not t then
		return
	end
	local ok, reason = PromoteSpecialist.target.check(t)
	menu.insertInteractionContent("main", {
		text = PromoteSpecialist.text(TXT_PROMOTE),
		active = ok,
		mouseOverText = (not ok) and PromoteSpecialist.text(reason) or nil,
		script = function() return leaveTo(menu, component) end,
	})
end

local function install(menu)
	if menu.promoteSpecialistInstalled then
		return
	end
	menu.promoteSpecialistInstalled = true
	local origPrepare = menu.prepareActions
	menu.prepareActions = function(...)
		local results = { origPrepare(...) }
		if results[1] then
			local ok, err = pcall(addAction, menu)
			if not ok then
				PromoteSpecialist.log("error adding interact action: %s", tostring(err))
			end
		end
		return unpack(results)
	end
	PromoteSpecialist.log("hooks installed into InteractMenu")
end

local attempts = 0
local function tryInstall()
	local menu = Helper.getMenu("InteractMenu")
	if menu then
		install(menu)
		return
	end
	attempts = attempts + 1
	if attempts <= 20 then
		PromoteSpecialist.scheduler.after(1, "install interact", tryInstall)
	else
		PromoteSpecialist.log("InteractMenu not found, ship and station entries are inactive")
	end
end

tryInstall()

return I
