-- Performs a swap with native engine calls and runs the follow-up steps that
-- need the engine to settle first. All transfers go through vanilla crew
-- transfer, so travel uses the normal pod timing.
--
-- Flows (see KNOWLEDGEBASE.md for the engine behaviour they rely on):
--   post_occupied  npc__control_dismissed signal with the candidate as
--                  replacement; afterwards move the demoted holder to the
--                  source ship if the engine kept them on the target.
--   post_empty     AssignHiredActor from the source ship.
--   crew           PerformCrewExchange2 one for one, then restore the roles
--                  (incoming person takes the target's role, outgoing one
--                  becomes service). Same ship: role swap only.

local ffi = require("ffi")
local C = ffi.C

SwapCrew = SwapCrew or {}
local E = {}
SwapCrew.executor = E

local POLL_INTERVAL = 0.25
local HOLDER_TIMEOUT = 60
local SETTLE_TIMEOUT = 60

local log = function(...) return SwapCrew.log(...) end

local function refresh()
	if SwapCrew.refresh then
		SwapCrew.refresh()
	end
end

local function seedSet(container)
	local set = {}
	for _, person in ipairs(SwapCrew.candidates.roster(container)) do
		set[SwapCrew.seedKey(person.seed)] = true
	end
	return set
end

-- New seed on container named name that was not in before, or nil.
local function findNewPerson(container, before, name)
	for _, person in ipairs(SwapCrew.candidates.roster(container)) do
		if not before[SwapCrew.seedKey(person.seed)] and person.name == name then
			return person.seed
		end
	end
	return nil
end

local function hasSeed(container, seed)
	local key = SwapCrew.seedKey(seed)
	for _, person in ipairs(SwapCrew.candidates.roster(container)) do
		if SwapCrew.seedKey(person.seed) == key then
			return true
		end
	end
	return false
end

-- PerformCrewExchange2 with plain seed lists; returns the reason ("" = ok).
local function exchange(container, partner, toPartner, toContainer, checkonly)
	local npcs = ffi.new("NPCSeed[?]", math.max(1, #toPartner))
	for i, seed in ipairs(toPartner) do
		npcs[i - 1] = seed
	end
	local partnernpcs = ffi.new("NPCSeed[?]", math.max(1, #toContainer))
	for i, seed in ipairs(toContainer) do
		partnernpcs[i - 1] = seed
	end
	local result = C.PerformCrewExchange2(container, partner, npcs, #toPartner, partnernpcs, #toContainer, 0, 0, false, checkonly)
	return ffi.string(result.reason)
end

local function checkedExchange(container, partner, toPartner, toContainer)
	local reason = exchange(container, partner, toPartner, toContainer, true)
	if reason ~= "" then
		return reason
	end
	return exchange(container, partner, toPartner, toContainer, false)
end

-- Sets role for each { seed, role } on container; returns true when the
-- engine reports every role as set. A reassignment in the same frame as the
-- transfer is silently ignored, so callers poll this.
local function reassign(container, changes)
	local pending = {}
	for _, change in ipairs(changes) do
		if ffi.string(C.GetPersonRole(change.seed, container)) ~= change.role then
			table.insert(pending, change)
		end
	end
	if #pending == 0 then
		return true
	end
	-- same form as vanilla menu.infoSubmenuConfirmCrewChanges (amount stays 0)
	local buf = ffi.new("CrewTransferContainer[?]", #pending)
	for i, change in ipairs(pending) do
		buf[i - 1].seed = change.seed
		buf[i - 1].newroleid = Helper.ffiNewString(change.role)
	end
	C.ReassignPeople(container, buf, #pending)
	return false
end

local function pollReassign(label, container, changes)
	SwapCrew.scheduler.poll(POLL_INTERVAL, SETTLE_TIMEOUT, label, function()
		if not IsValidComponent(container) then
			return true
		end
		local present = {}
		for _, change in ipairs(changes) do
			if hasSeed(container, change.seed) then
				table.insert(present, change)
			end
		end
		if #present < #changes then
			return false
		end
		if reassign(container, present) then
			log("%s: roles set on %s", label, tostring(container))
			refresh()
			return true
		end
		return false
	end, function()
		log("%s: timed out setting roles on %s", label, tostring(container))
	end)
end

local function runPostOccupied(t, cand)
	local src, tgt = cand.ship, t.container
	local oldHolder, oldName, post = t.holder, t.name, t.post
	local srcBefore, tgtBefore = seedSet(src), seedSet(tgt)

	log("signal npc__control_dismissed: old=%s (%s) replacement=%s from %s, %s", oldName, tostring(oldHolder), cand.name, tostring(src), SwapCrew.target.describe(t))
	C.SignalObjectWithNPCSeed(oldHolder, "npc__control_dismissed", cand.seed, src)

	local function returnDemoted(demoted)
		SwapCrew.scheduler.poll(1, SETTLE_TIMEOUT, "return demoted", function()
			if not (IsValidComponent(src) and IsValidComponent(tgt)) then
				log("return demoted: a ship no longer exists, leaving %s where they are", oldName)
				return true
			end
			local reason = checkedExchange(tgt, src, { demoted }, {})
			if reason == "" then
				log("return demoted: %s sent to %s", oldName, tostring(src))
				refresh()
				return true
			end
			log("return demoted: not yet possible (%s), retrying", reason)
			return false
		end, function()
			log("return demoted: gave up, %s stays on %s as service crew", oldName, tostring(tgt))
		end)
	end

	local function findDemoted()
		SwapCrew.scheduler.poll(POLL_INTERVAL, SETTLE_TIMEOUT, "find demoted", function()
			if src == tgt then
				log("same-container promotion done, %s stays aboard as service crew", oldName)
				return true
			end
			if findNewPerson(src, srcBefore, oldName) then
				log("demoted %s landed on source %s", oldName, tostring(src))
				return true
			end
			local demoted = findNewPerson(tgt, tgtBefore, oldName)
			if demoted then
				log("demoted %s landed on target %s, sending to source", oldName, tostring(tgt))
				returnDemoted(demoted)
				return true
			end
			return false
		end, function()
			log("find demoted: %s not found in either roster", oldName)
		end)
	end

	SwapCrew.scheduler.poll(POLL_INTERVAL, HOLDER_TIMEOUT, "post handover", function()
		local holder = SwapCrew.target.postHolder(tgt, post)
		if holder and holder ~= oldHolder then
			log("post %s on %s now held by %s", post, tostring(tgt), tostring(holder))
			refresh()
			findDemoted()
			return true
		end
		return false
	end, function()
		log("post handover: %s on %s did not change within %ds", post, tostring(tgt), HOLDER_TIMEOUT)
	end)
	return true
end

local function runPostEmpty(t, cand)
	local actor = ffi.new("GenericActor")
	actor.entity = 0
	actor.personcontrollable = cand.ship
	actor.personseed = cand.seed
	local reason = ffi.string(C.AssignHiredActor(actor, t.container, t.post, nil, true))
	if reason ~= "" then
		return false, reason
	end
	reason = ffi.string(C.AssignHiredActor(actor, t.container, t.post, nil, false))
	if reason ~= "" then
		return false, reason
	end
	log("assigned %s from %s to empty %s, %s", cand.name, tostring(cand.ship), t.post, SwapCrew.target.describe(t))
	-- the post property may only report the new holder once the engine has
	-- moved them there; record when (or whether) that happens
	SwapCrew.scheduler.poll(1, SETTLE_TIMEOUT * 5, "post filled", function()
		local holder = SwapCrew.target.postHolder(t.container, t.post)
		if holder then
			log("post %s on %s now held by %s (%s)", t.post, tostring(t.container), tostring(GetComponentData(holder, "name")), tostring(holder))
			refresh()
			return true
		end
		return false
	end, function()
		log("post %s on %s still empty after %ds of game time", t.post, tostring(t.container), SETTLE_TIMEOUT * 5)
	end)
	return true
end

local function runCrew(t, cand)
	local a, b = t.container, cand.ship
	if a == b then
		-- only a marine target reaches here (see candidates.collect)
		log("same-ship role swap on %s: %s -> service, %s -> %s", tostring(a), t.name, cand.name, t.role)
		pollReassign("role swap", a, { { seed = t.seed, role = "service" }, { seed = cand.seed, role = t.role } })
		return true
	end
	local reason = checkedExchange(a, b, { t.seed }, { cand.seed })
	if reason ~= "" then
		return false, reason
	end
	log("crew exchange: %s (%s) %s <-> %s %s", t.name, t.role, tostring(a), tostring(b), cand.name)
	if t.role ~= "service" then
		pollReassign("role incoming", a, { { seed = cand.seed, role = t.role } })
		pollReassign("role outgoing", b, { { seed = t.seed, role = "service" } })
	end
	return true
end

-- Starts the swap of target t with candidate cand. Returns true, or false and
-- a reason string when the engine refused immediately.
function E.run(t, cand)
	local ok, reason = SwapCrew.target.check(t)
	if not ok then
		return false, SwapCrew.text(reason)
	end
	if not SwapCrew.candidates.stillValid(cand) then
		return false, SwapCrew.text(SwapCrew.target.REASON_TRANSFER)
	end
	local result, err
	if t.kind == "post_occupied" then
		result, err = runPostOccupied(t, cand)
	elseif t.kind == "post_empty" then
		result, err = runPostEmpty(t, cand)
	else
		result, err = runCrew(t, cand)
	end
	if not result then
		log("refused (%s): %s", tostring(err), SwapCrew.target.describe(t))
	end
	refresh()
	return result, err
end

return E
