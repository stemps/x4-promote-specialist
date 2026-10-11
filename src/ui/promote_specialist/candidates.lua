-- Finds crew on player ships who could fill a swap target, with their skill for
-- the target's post or role.

local ffi = require("ffi")
local C = ffi.C

PromoteSpecialist = PromoteSpecialist or {}
local K = {}
PromoteSpecialist.candidates = K

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
		local ship = PromoteSpecialist.id64(buf[i])
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

-- Where candidates can come from. Crew roles are NPC seeds in a ship's roster;
-- "pilot" means the AI pilots of other ships (entities, ship pilot targets
-- only); "manager" the managers of other stations (entities, station manager
-- targets only, see manager_move.lua).
K.SOURCES = { service = true, marine = true, pilot = true, manager = true }

-- Reason text id when source cannot serve target t, or nil when it can.
K.REASON_PILOT_ONLY = 55
K.REASON_MANAGER_ONLY = 59
function K.sourceUnavailable(t, source)
	if source == "pilot" and (t.post ~= "aipilot" or t.isStation) then
		return K.REASON_PILOT_ONLY
	end
	if source == "manager" and t.post ~= "manager" then
		return K.REASON_MANAGER_ONLY
	end
	return nil
end

-- Best service or marine crew member aboard container for post, as
-- { seed, name }, or nil.
function K.bestCrew(container, post)
	local best, bestSkill
	for _, person in ipairs(K.roster(container)) do
		if (person.role == "service" or person.role == "marine") and C.HasPersonArrived(container, person.seed) and not C.IsPersonTransferScheduled(container, person.seed) then
			local skill = C.GetPersonCombinedSkill(container, person.seed, nil, post)
			if not bestSkill or skill > bestSkill then
				best, bestSkill = person, skill
			end
		end
	end
	return best and { seed = best.seed, name = best.name } or nil
end

-- Player stations that are operational.
function K.playerStations()
	local result = {}
	local n = C.GetNumAllFactionStations("player")
	if n == 0 then
		return result
	end
	local buf = ffi.new("UniverseID[?]", n)
	n = C.GetAllFactionStations(buf, n, "player")
	for i = 0, n - 1 do
		local station = PromoteSpecialist.id64(buf[i])
		if C.IsComponentOperational(station) then
			table.insert(result, station)
		end
	end
	return result
end

-- Free crew slots on container (crew capacity minus people aboard).
function K.freeSlots(container)
	return C.GetPeopleCapacity(container, "", false) - #K.roster(container)
end

-- Holder of post on container (a ship or station) as a candidate, or nil.
-- ship/shipName name the candidate's container either way.
local function postCandidate(container, post, role, sameSector, distance)
	local holder = PromoteSpecialist.target.postHolder(container, post)
	if not holder then
		return nil
	end
	return {
		kind = "entity",
		entity = holder,
		sourcePost = post,
		key = "entity:" .. tostring(holder),
		name = GetComponentData(holder, "name"),
		role = role,
		ship = container,
		shipName = ffi.string(C.GetComponentName(container)),
		skill = C.GetEntityCombinedSkill(holder, nil, post),
		sameShip = false,
		sameSector = sameSector,
		distance = distance,
	}
end

-- sameSector and distance of container as seen from target container.
local function proximity(container, target, targetSector)
	local sameSector = C.GetContextByClass(container, "sector", false) == targetSector
	local distance = C.GetDistanceBetween(container, target)
	if not sameSector or distance < 0 then
		distance = math.huge
	end
	return sameSector, distance
end

-- Candidate list for target t (see PromoteSpecialist.model for the fields used there).
-- sources: set of K.SOURCES keys to draw from, e.g. { service = true }.
function K.collect(t, sources)
	local result = {}
	local targetSector = C.GetContextByClass(t.container, "sector", false)
	local excluded = t.seed and PromoteSpecialist.seedKey(t.seed)
	local withPilots = sources.pilot and not K.sourceUnavailable(t, "pilot")
	if sources.manager and not K.sourceUnavailable(t, "manager") then
		for _, station in ipairs(K.playerStations()) do
			if station ~= t.container then
				local cand = postCandidate(station, "manager", "manager", proximity(station, t.container, targetSector))
				if cand then
					table.insert(result, cand)
				end
			end
		end
	end
	for _, ship in ipairs(K.playerShips()) do
		local sameShip = ship == t.container
		local sameSector = C.GetContextByClass(ship, "sector", false) == targetSector
		local distance = 0
		if not sameShip then
			distance = C.GetDistanceBetween(ship, t.container)
			if not sameSector or distance < 0 then
				distance = math.huge
			end
		end
		if withPilots and not sameShip then
			local cand = postCandidate(ship, "aipilot", "pilot", sameSector, distance)
			if cand then
				table.insert(result, cand)
			end
		end
		local shipName
		for _, person in ipairs(K.roster(ship)) do
			-- swapping with someone of the same role on the same ship changes nothing
			local sameRole = sameShip and t.kind == "crew" and t.role == person.role
			if sources[person.role] and not sameRole then
				local key = PromoteSpecialist.seedKey(person.seed)
				if key ~= excluded and C.HasPersonArrived(ship, person.seed) and not C.IsPersonTransferScheduled(ship, person.seed) then
					shipName = shipName or ffi.string(C.GetComponentName(ship))
					table.insert(result, {
						kind = "seed",
						seed = person.seed,
						key = key,
						name = person.name,
						role = person.role,
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
	return result
end

-- Individual skills of cand for target t, most relevant first:
-- list of { textid, descriptionid, value (0-15), relevant }.
function K.skills(t, cand)
	local result = {}
	if cand.kind == "entity" then
		-- an entity reports skills for the post it holds, which for a pilot
		-- candidate is the target's post too
		for _, skill in ipairs(GetComponentData(cand.entity, "skills") or {}) do
			table.insert(result, { textid = skill.textid, descriptionid = skill.descriptionid, value = skill.value, relevant = skill.relevance > 0 })
		end
		return K.sortSkills(result)
	end
	local n = C.GetNumSkills()
	local buf = ffi.new("Skill2[?]", n + 1)
	-- same call and indexing as vanilla's crew list (menu_map.lua setupCrewInfoSubmenuRows)
	n = C.GetPersonSkillsForAssignment(buf, cand.seed, cand.ship, t.role, t.post)
	for i = 1, n do
		table.insert(result, { textid = buf[i].textid, descriptionid = buf[i].descriptionid, value = buf[i].value, relevant = buf[i].relevance > 0 })
	end
	return K.sortSkills(result)
end

-- Most relevant first, then in game order.
function K.sortSkills(result)
	table.sort(result, function(a, b)
		if a.relevant ~= b.relevant then
			return a.relevant
		end
		return a.textid < b.textid
	end)
	return result
end

-- Re-checks a previously chosen candidate right before acting on it.
function K.stillValid(cand)
	if cand.kind == "entity" then
		return IsValidComponent(cand.ship)
			and C.IsComponentOperational(cand.ship)
			and PromoteSpecialist.target.postHolder(cand.ship, cand.sourcePost) == cand.entity
	end
	return IsValidComponent(cand.ship)
		and C.IsComponentOperational(cand.ship)
		and C.IsPerson(cand.seed, cand.ship)
		and ffi.string(C.GetPersonRole(cand.seed, cand.ship)) == cand.role
		and C.HasPersonArrived(cand.ship, cand.seed)
		and not C.IsPersonTransferScheduled(cand.ship, cand.seed)
end

return K
