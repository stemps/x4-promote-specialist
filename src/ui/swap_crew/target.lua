-- Resolves what the player right-clicked into a swap target and decides whether
-- a swap is allowed for it.
--
-- Target kinds:
--   post_occupied  pilot, manager or ship trader entity holding a control post
--   post_empty     empty pilot or manager post
--   crew           service or marine crew member (NPC seed)

local ffi = require("ffi")
local C = ffi.C

SwapCrew = SwapCrew or {}
local T = {}
SwapCrew.target = T

T.POSTS = { aipilot = true, manager = true, shiptrader = true }
T.CREW_ROLES = { service = true, marine = true }

-- Reason text ids (page SwapCrew.PAGE) for an unavailable swap.
T.REASON_TRANSFER = 43
T.REASON_CRITICAL = 44
T.REASON_BUILDS = 45
T.REASON_POST = 46

local function isSupportedContainer(container)
	if C.IsComponentClass(container, "station") then
		return true
	end
	return C.IsComponentClass(container, "ship")
		and not C.IsComponentClass(container, "ship_xs")
		and not C.IsUnit(container)
end

-- Entity currently holding post on container, or nil.
function T.postHolder(container, post)
	local prop = (post == "manager" and "tradenpc") or (post == "shiptrader" and "shiptrader") or "assignedaipilot"
	local holder = GetComponentData(container, prop)
	if holder and IsValidComponent(holder) then
		return SwapCrew.id64(holder)
	end
	return nil
end

-- cmd is MapMenu's contextMenuData. Returns a target table or nil when the
-- clicked row is not something Swap Crew handles.
function T.fromContext(cmd)
	if type(cmd) ~= "table" or not cmd.component then
		return nil
	end
	local container = SwapCrew.id64(cmd.component)
	if not (GetComponentData(container, "isplayerowned") and isSupportedContainer(container)) then
		return nil
	end
	local isStation = C.IsComponentClass(container, "station")
	local marker = cmd.swapcrew

	if marker and marker.emptypost then
		return { kind = "post_empty", container = container, post = marker.emptypost, isStation = isStation }
	end
	if cmd.person then
		local role = ffi.string(C.GetPersonRole(cmd.person, container))
		if not T.CREW_ROLES[role] then
			return nil
		end
		return {
			kind = "crew",
			container = container,
			seed = cmd.person,
			role = role,
			name = ffi.string(C.GetPersonName(cmd.person, container)),
			isStation = isStation,
		}
	end
	if cmd.entity then
		local entity = SwapCrew.id64(cmd.entity)
		if entity == SwapCrew.id64(C.GetPlayerID()) then
			return nil
		end
		local post, name = GetComponentData(entity, "poststring", "name")
		if not T.POSTS[post] then
			return nil
		end
		-- only the entity that actually holds the post (vanilla also lists a
		-- player-flown ship's pilot seat, which is the player)
		if T.postHolder(container, post) ~= entity then
			return nil
		end
		return { kind = "post_occupied", container = container, post = post, holder = entity, name = name, isStation = isStation }
	end
	return nil
end

-- Returns true, or false plus a reason text id.
function T.check(t)
	if not (IsValidComponent(t.container) and C.IsComponentOperational(t.container)) then
		return false, T.REASON_POST
	end
	if t.kind == "crew" then
		if C.IsPersonTransferScheduled(t.container, t.seed) or not C.HasPersonArrived(t.container, t.seed) then
			return false, T.REASON_TRANSFER
		end
		return true
	end
	if not C.CanControllableHaveControlEntity(t.container, t.post) then
		return false, T.REASON_POST
	end
	if t.kind == "post_occupied" and T.postHolder(t.container, t.post) ~= t.holder then
		-- holder changed since the menu was opened (e.g. a swap is under way)
		return false, T.REASON_TRANSFER
	end
	if (not t.isStation) and C.IsCurrentOrderCritical(t.container) then
		return false, T.REASON_CRITICAL
	end
	if t.post == "shiptrader" then
		local builds = C.GetNumBuildTasks(t.container, 0, true, true) + C.GetNumBuildTasks(t.container, 0, false, true)
		if builds > 0 then
			return false, T.REASON_BUILDS
		end
	end
	return true
end

-- Combined skill (0-100) of the person currently in the target position, or nil.
function T.currentSkill(t)
	if t.kind == "post_occupied" then
		return C.GetEntityCombinedSkill(t.holder, nil, t.post)
	elseif t.kind == "crew" then
		return C.GetPersonCombinedSkill(t.container, t.seed, t.role, nil)
	end
	return nil
end

-- Human readable label for logs.
function T.describe(t)
	return string.format("%s %s on %s (%s)", t.kind, t.post or t.role or "?", ffi.string(C.GetComponentName(t.container)), tostring(t.container))
end

return T
