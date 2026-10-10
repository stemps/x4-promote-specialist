-- Finds service crew on player ships who could fill a swap target, with their
-- skill for the target's post or role.

local ffi = require("ffi")
local C = ffi.C

SwapCrew = SwapCrew or {}
local K = {}
SwapCrew.candidates = K

-- Player ships that carry transferable crew. Same filter as vanilla's personnel
-- list (menu_playerinfo), plus no ship_xs: crew transfer pods in flight are
-- player-owned ship_xs with crew capacity, and crew sent there is lost.
function K.playerShips()
	local result = {}
	local n = C.GetNumAllFactionShips("player")
	if n == 0 then
		return result
	end
	local buf = ffi.new("UniverseID[?]", n)
	n = C.GetAllFactionShips(buf, n, "player")
	for i = 0, n - 1 do
		local ship = SwapCrew.id64(buf[i])
		if C.IsComponentOperational(ship) and not C.IsComponentClass(ship, "ship_xs") and not C.IsUnit(ship) then
			local macro, isdeployable = GetComponentData(ship, "macro", "isdeployable")
			local islasertower, ware = GetMacroData(macro, "islasertower", "ware")
			if ware and not islasertower and not isdeployable then
				table.insert(result, ship)
			end
		end
	end
	return result
end

-- All people on container as { seed, role, name }.
function K.roster(container)
	local result = {}
	local n = C.GetNumPeopleAfterOrders(container, 0)
	if n == 0 then
		return result
	end
	local buf = ffi.new("NPCInfo[?]", n)
	n = C.GetPeopleAfterOrders(buf, n, container, 0)
	for i = 0, n - 1 do
		table.insert(result, { seed = buf[i].seed, role = ffi.string(buf[i].roleid), name = ffi.string(buf[i].name) })
	end
	return result
end

-- Skill (0-100) of seed aboard ship for the target's post or role.
function K.skillFor(t, ship, seed)
	if t.post then
		return C.GetPersonCombinedSkill(ship, seed, nil, t.post)
	end
	return C.GetPersonCombinedSkill(ship, seed, t.role, nil)
end

-- Candidate list for target t (see SwapCrew.model for the fields used there).
function K.collect(t)
	local result = {}
	local targetSector = C.GetContextByClass(t.container, "sector", false)
	local excluded = t.seed and SwapCrew.seedKey(t.seed)
	for _, ship in ipairs(K.playerShips()) do
		local sameShip = ship == t.container
		-- swapping a service crew member with another one on the same ship changes nothing
		local usable = not (sameShip and t.kind == "crew" and t.role == "service")
		if usable then
			local sameSector = C.GetContextByClass(ship, "sector", false) == targetSector
			local distance = 0
			if not sameShip then
				distance = C.GetDistanceBetween(ship, t.container)
				if not sameSector or distance < 0 then
					distance = math.huge
				end
			end
			local shipName
			for _, person in ipairs(K.roster(ship)) do
				if person.role == "service" then
					local key = SwapCrew.seedKey(person.seed)
					if key ~= excluded and C.HasPersonArrived(ship, person.seed) and not C.IsPersonTransferScheduled(ship, person.seed) then
						shipName = shipName or ffi.string(C.GetComponentName(ship))
						table.insert(result, {
							seed = person.seed,
							key = key,
							name = person.name,
							ship = ship,
							shipName = shipName,
							skill = K.skillFor(t, ship, person.seed),
							sameShip = sameShip,
							sameSector = sameSector,
							distance = distance,
						})
					end
				end
			end
		end
	end
	return result
end

-- Re-checks a previously chosen candidate right before acting on it.
function K.stillValid(cand)
	return IsValidComponent(cand.ship)
		and C.IsComponentOperational(cand.ship)
		and C.IsPerson(cand.seed, cand.ship)
		and ffi.string(C.GetPersonRole(cand.seed, cand.ship)) == "service"
		and C.HasPersonArrived(cand.ship, cand.seed)
		and not C.IsPersonTransferScheduled(cand.ship, cand.seed)
end

return K
