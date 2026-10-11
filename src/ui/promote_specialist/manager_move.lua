-- Moves another station's manager (an entity) into a target station's
-- manager post. The engine refuses an entity for an occupied manager post
-- (postoccupied), so an occupied post goes through a ship stopover:
--
--   A  the candidate becomes service crew on the closest player ship that
--      takes them; their old station's post is empty from here on
--   -  wait until that move has settled (a dismissal signal sent while the
--      entity is still mid-transition loses the person, KNOWLEDGEBASE.md
--      2026-10-11 manager-stopover-experiment)
--   B  the candidate, now a crew seed on that ship, replaces the old manager
--      with the executor's dismissal flow, which returns the old manager to
--      the ship as service crew
--   C  the old manager goes from the ship into the candidate's old post
--
-- An empty target post takes the candidate entity directly. If the chain
-- breaks after A, the candidate is put back into their old post.

local ffi = require("ffi")
local C = ffi.C

PromoteSpecialist = PromoteSpecialist or {}
local MM = {}
PromoteSpecialist.managerMove = MM

local STOPOVER_TRIES = 20
local SETTLE_INTERVAL = 0.5
local SETTLE_MAX = 10
local TIMEOUT = 600

MM.REASON_NO_STOPOVER = 64

local log = function(fmt, ...) return PromoteSpecialist.log("manager move: " .. fmt, ...) end

local function entityActor(entity)
	local actor = ffi.new("GenericActor")
	actor.entity = entity
	actor.personcontrollable = 0
	actor.personseed = 0
	return actor
end

local function seedActor(container, seed)
	local actor = ffi.new("GenericActor")
	actor.entity = 0
	actor.personcontrollable = container
	actor.personseed = seed
	return actor
end

-- AssignHiredActor checkonly, then for real. Returns "" or the engine's reason.
local function assign(actor, object, post, role)
	local reason = ffi.string(C.AssignHiredActor(actor, object, post, role, true))
	if reason ~= "" then
		return reason
	end
	return ffi.string(C.AssignHiredActor(actor, object, post, role, false))
end

local function keySet(container)
	local set = {}
	for _, person in ipairs(PromoteSpecialist.candidates.roster(container)) do
		set[PromoteSpecialist.seedKey(person.seed)] = true
	end
	return set
end

-- Arrived person named name on container who was not in before, or nil.
local function arrivedPerson(container, before, name)
	for _, person in ipairs(PromoteSpecialist.candidates.roster(container)) do
		if not before[PromoteSpecialist.seedKey(person.seed)] and person.name == name and C.HasPersonArrived(container, person.seed) then
			return person.seed
		end
	end
	return nil
end

-- Closest player ship (same sector first) that takes entity as service crew.
local function stopoverShip(near, entity)
	local nearSector = C.GetContextByClass(near, "sector", false)
	local ships = {}
	for _, ship in ipairs(PromoteSpecialist.candidates.playerShips()) do
		local distance = C.GetDistanceBetween(ship, near)
		table.insert(ships, {
			ship = ship,
			sameSector = C.GetContextByClass(ship, "sector", false) == nearSector,
			distance = (distance < 0) and math.huge or distance,
		})
	end
	table.sort(ships, function(a, b)
		if a.sameSector ~= b.sameSector then
			return a.sameSector
		end
		return a.distance < b.distance
	end)
	for i = 1, math.min(#ships, STOPOVER_TRIES) do
		local ship = ships[i].ship
		if ffi.string(C.AssignHiredActor(entityActor(entity), ship, "", "service", true)) == "" then
			return ship
		end
	end
	return nil
end

-- Waits until post on container holds someone; then onDone(holder).
local function awaitHolder(label, container, post, onDone)
	PromoteSpecialist.scheduler.poll(1, TIMEOUT, label, function()
		local holder = PromoteSpecialist.target.postHolder(container, post)
		if holder then
			PromoteSpecialist.executor.setPending(container, post, nil)
			PromoteSpecialist.refresh()
			if onDone then
				onDone(holder)
			end
			return true
		end
		return false
	end, function()
		PromoteSpecialist.executor.setPending(container, post, nil)
		log("%s: %s on %s still empty after %ds", label, post, tostring(container), TIMEOUT)
	end)
end

-- Puts seed (a person on ship) into the manager post of station; returns the
-- engine's reason ("" = ok).
local function fillFromShip(label, ship, seed, name, station)
	local reason = assign(seedActor(ship, seed), station, "manager", nil)
	if reason ~= "" then
		log("%s: %s from %s into %s refused (%s)", label, name, tostring(ship), tostring(station), reason)
		return reason
	end
	log("%s: %s from %s into %s", label, name, tostring(ship), tostring(station))
	PromoteSpecialist.executor.setPending(station, "manager", name)
	awaitHolder(label, station, "manager")
	return ""
end

local function runEmpty(t, cand)
	local reason = assign(entityActor(cand.entity), t.container, "manager", nil)
	if reason ~= "" then
		return false, reason
	end
	log("%s from %s into empty post on %s", cand.name, tostring(cand.ship), tostring(t.container))
	PromoteSpecialist.refresh()
	return true
end

-- Starts the move of manager candidate cand into target t's manager post.
-- Returns true, or false and a reason when it could not start.
function MM.run(t, cand)
	if t.kind == "post_empty" then
		return runEmpty(t, cand)
	end
	local tgt, src = t.container, cand.ship
	local oldName = t.name
	local stop = stopoverShip(tgt, cand.entity)
	if not stop then
		return false, PromoteSpecialist.text(MM.REASON_NO_STOPOVER)
	end
	local stopBefore = keySet(stop)

	local reason = assign(entityActor(cand.entity), stop, "", "service")
	if reason ~= "" then
		return false, reason
	end
	log("A: %s from %s to %s as service crew, then into %s", cand.name, tostring(src), tostring(stop), PromoteSpecialist.target.describe(t))
	PromoteSpecialist.executor.setPending(tgt, "manager", cand.name)
	PromoteSpecialist.executor.setPending(src, "manager", oldName)

	-- the chain broke after A: candidate back into their old post
	local function rollback(seed)
		PromoteSpecialist.executor.setPending(tgt, "manager", nil)
		PromoteSpecialist.executor.setPending(src, "manager", nil)
		if seed then
			fillFromShip("rollback", stop, seed, cand.name, src)
		else
			log("rollback: %s not found on %s, %s stays without manager", cand.name, tostring(stop), tostring(src))
		end
	end

	local function stepC()
		PromoteSpecialist.scheduler.poll(1, TIMEOUT, "manager move C", function()
			local seed = arrivedPerson(stop, stopBefore, oldName)
			if not seed then
				return false
			end
			PromoteSpecialist.executor.setPending(src, "manager", nil)
			fillFromShip("C", stop, seed, oldName, src)
			return true
		end, function()
			PromoteSpecialist.executor.setPending(src, "manager", nil)
			log("C: %s did not arrive on %s within %ds, %s stays without manager", tostring(oldName), tostring(stop), TIMEOUT, tostring(src))
		end)
	end

	local function stepB(seed)
		-- the executor flow marks the target pending itself and returns the
		-- demoted manager to the ship
		PromoteSpecialist.executor.setPending(tgt, "manager", nil)
		local stopCand = { kind = "seed", seed = seed, key = PromoteSpecialist.seedKey(seed), name = cand.name, role = "service", ship = stop }
		local ok, why = PromoteSpecialist.executor.promoteIntoPost(t, stopCand, false)
		if not ok then
			log("B: refused (%s)", tostring(why))
			rollback(seed)
			return
		end
		stepC()
	end

	PromoteSpecialist.scheduler.poll(1, TIMEOUT, "manager move A", function()
		local seed = arrivedPerson(stop, stopBefore, cand.name)
		if not seed then
			return false
		end
		local settleStart = GetCurTime()
		PromoteSpecialist.scheduler.poll(SETTLE_INTERVAL, SETTLE_MAX + 5, "manager move settle", function()
			local despawned = not IsValidComponent(cand.entity)
			if not despawned and (GetCurTime() - settleStart) < SETTLE_MAX then
				return false
			end
			if arrivedPerson(stop, stopBefore, cand.name) ~= seed then
				log("settle: %s is no longer settled on %s", cand.name, tostring(stop))
				rollback(nil)
				return true
			end
			stepB(seed)
			return true
		end, function()
			rollback(seed)
		end)
		return true
	end, function()
		log("A: %s did not arrive on %s within %ds", cand.name, tostring(stop), TIMEOUT)
		rollback(nil)
	end)
	return true
end

return MM
