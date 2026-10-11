-- Performs a swap with native engine calls and runs the follow-up steps that
-- need the engine to settle first. All transfers go through vanilla crew
-- transfer, so travel uses the normal pod timing.
--
-- Flows (see KNOWLEDGEBASE.md for the engine behaviour they rely on):
--   post_occupied  npc__control_dismissed signal with the candidate as
--                  replacement; afterwards move the demoted holder to the
--                  source ship if the engine kept them on the target, unless
--                  they are to stay.
--   post_empty     AssignHiredActor from the source ship.
--   crew           PerformCrewExchange2 one for one, then restore the roles
--                  (incoming person takes the target's role, outgoing one the
--                  candidate's). Staying: only the candidate moves, and the
--                  target person becomes service crew. Same ship: roles only.
--   pilot          candidate is another ship's pilot (entity): vanilla captain
--                  exchange, see runPilotExchange.
--   manager        candidate is another station's manager (entity): ship
--                  stopover, see manager_move.lua.
--
-- opts.stay: the person in the target position stays aboard as service crew
-- instead of moving to the candidate's ship.

local ffi = require("ffi")
local C = ffi.C

PromoteSpecialist = PromoteSpecialist or {}
local E = {}
PromoteSpecialist.executor = E

local POLL_INTERVAL = 0.25
local HOLDER_TIMEOUT = 60
-- a station's post only shows its new holder once they have travelled there
local STATION_HOLDER_TIMEOUT = 600
local SETTLE_TIMEOUT = 60

local log = function(...) return PromoteSpecialist.log(...) end

-- Posts this session is filling and whose new holder has not arrived yet:
-- { ["container:post"] = name }. The engine reports such a post as empty
-- while refusing everyone else (postoccupied), so the dialog has to know.
local pending = {}

local function pendingKey(container, post)
	return tostring(container) .. ":" .. post
end

-- Name of the person on the way to post on container, or nil.
function E.pending(container, post)
	return pending[pendingKey(container, post)]
end

function E.setPending(container, post, name)
	pending[pendingKey(container, post)] = name
end

local function holderTimeout(t)
	return t.isStation and STATION_HOLDER_TIMEOUT or HOLDER_TIMEOUT
end

local function refresh()
	if PromoteSpecialist.refresh then
		PromoteSpecialist.refresh()
	end
end

local function seedSet(container)
	local set = {}
	for _, person in ipairs(PromoteSpecialist.candidates.roster(container)) do
		set[PromoteSpecialist.seedKey(person.seed)] = true
	end
	return set
end

-- New seed on container named name that was not in before, or nil.
local function findNewPerson(container, before, name)
	for _, person in ipairs(PromoteSpecialist.candidates.roster(container)) do
		if not before[PromoteSpecialist.seedKey(person.seed)] and person.name == name then
			return person.seed
		end
	end
	return nil
end

local function hasSeed(container, seed)
	local key = PromoteSpecialist.seedKey(seed)
	for _, person in ipairs(PromoteSpecialist.candidates.roster(container)) do
		if PromoteSpecialist.seedKey(person.seed) == key then
			return true
		end
	end
	return false
end

-- PerformCrewExchange2 with plain seed lists; returns the reason ("" = ok).
-- exchangeCaptains also swaps the two ships' pilots (vanilla crew transfer's
-- "Exchange captains", menu_map.lua performCrewExchange).
local function exchange(container, partner, toPartner, toContainer, checkonly, exchangeCaptains)
	local npcs = ffi.new("NPCSeed[?]", math.max(1, #toPartner))
	for i, seed in ipairs(toPartner) do
		npcs[i - 1] = seed
	end
	local partnernpcs = ffi.new("NPCSeed[?]", math.max(1, #toContainer))
	for i, seed in ipairs(toContainer) do
		partnernpcs[i - 1] = seed
	end
	local result = C.PerformCrewExchange2(container, partner, npcs, #toPartner, partnernpcs, #toContainer, 0, 0, exchangeCaptains or false, checkonly)
	return ffi.string(result.reason)
end

local function checkedExchange(container, partner, toPartner, toContainer, exchangeCaptains)
	local reason = exchange(container, partner, toPartner, toContainer, true, exchangeCaptains)
	if reason ~= "" then
		return reason
	end
	return exchange(container, partner, toPartner, toContainer, false, exchangeCaptains)
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
	PromoteSpecialist.scheduler.poll(POLL_INTERVAL, SETTLE_TIMEOUT, label, function()
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

local function runPostOccupied(t, cand, stay)
	local src, tgt = cand.ship, t.container
	local oldHolder, oldName, post = t.holder, t.name, t.post
	local srcBefore, tgtBefore = seedSet(src), seedSet(tgt)

	log("signal npc__control_dismissed: old=%s (%s) replacement=%s from %s, %s", oldName, tostring(oldHolder), cand.name, tostring(src), PromoteSpecialist.target.describe(t))
	C.SignalObjectWithNPCSeed(oldHolder, "npc__control_dismissed", cand.seed, src)
	E.setPending(tgt, post, cand.name)

	local function returnDemoted(demoted)
		PromoteSpecialist.scheduler.poll(1, SETTLE_TIMEOUT, "return demoted", function()
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

	-- The engine gives the demoted holder the replacement's old role; someone
	-- staying aboard is meant to end up as service crew.
	local function demoteToService(demoted)
		if cand.role ~= "service" then
			pollReassign("demoted to service", tgt, { { seed = demoted, role = "service" } })
		end
	end

	local function findDemoted()
		PromoteSpecialist.scheduler.poll(POLL_INTERVAL, SETTLE_TIMEOUT, "find demoted", function()
			if src == tgt then
				local demoted = findNewPerson(tgt, tgtBefore, oldName)
				if not demoted then
					return false
				end
				log("same-container promotion done, %s stays aboard", oldName)
				if stay then
					demoteToService(demoted)
				end
				return true
			end
			if findNewPerson(src, srcBefore, oldName) then
				log("demoted %s landed on source %s%s", oldName, tostring(src), stay and " (no room to stay on the target)" or "")
				return true
			end
			local demoted = findNewPerson(tgt, tgtBefore, oldName)
			if demoted then
				if stay then
					log("demoted %s stays on target %s", oldName, tostring(tgt))
					demoteToService(demoted)
				else
					log("demoted %s landed on target %s, sending to source", oldName, tostring(tgt))
					returnDemoted(demoted)
				end
				return true
			end
			return false
		end, function()
			log("find demoted: %s not found in either roster", oldName)
		end)
	end

	PromoteSpecialist.scheduler.poll(POLL_INTERVAL, holderTimeout(t), "post handover", function()
		local holder = PromoteSpecialist.target.postHolder(tgt, post)
		if holder and holder ~= oldHolder then
			log("post %s on %s now held by %s", post, tostring(tgt), tostring(holder))
			E.setPending(tgt, post, nil)
			refresh()
			findDemoted()
			return true
		end
		return false
	end, function()
		E.setPending(tgt, post, nil)
		log("post handover: %s on %s did not change within %ds", post, tostring(tgt), holderTimeout(t))
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
	log("assigned %s from %s to empty %s, %s", cand.name, tostring(cand.ship), t.post, PromoteSpecialist.target.describe(t))
	E.setPending(t.container, t.post, cand.name)
	-- the post property may only report the new holder once the engine has
	-- moved them there; record when (or whether) that happens
	PromoteSpecialist.scheduler.poll(1, STATION_HOLDER_TIMEOUT, "post filled", function()
		local holder = PromoteSpecialist.target.postHolder(t.container, t.post)
		if holder then
			log("post %s on %s now held by %s (%s)", t.post, tostring(t.container), tostring(GetComponentData(holder, "name")), tostring(holder))
			E.setPending(t.container, t.post, nil)
			refresh()
			return true
		end
		return false
	end, function()
		E.setPending(t.container, t.post, nil)
		log("post %s on %s still empty after %ds of game time", t.post, tostring(t.container), STATION_HOLDER_TIMEOUT)
	end)
	return true
end

-- Fills the empty pilot post of ship with its best crew member, like vanilla's
-- "Replace pilot with best crewmember" (menu_map.lua infoSubmenuReplacePilot).
local function promoteBestAboard(ship)
	local best = PromoteSpecialist.candidates.bestCrew(ship, "aipilot")
	if not best then
		log("no crew aboard %s to promote, its pilot post stays empty", tostring(ship))
		return
	end
	local actor = ffi.new("GenericActor")
	actor.entity = 0
	actor.personcontrollable = ship
	actor.personseed = best.seed
	local reason = ffi.string(C.AssignHiredActor(actor, ship, "aipilot", nil, false))
	log("promoted %s aboard %s to pilot%s", best.name, tostring(ship), (reason ~= "") and (" refused: " .. reason) or "")
end

-- Pilot candidate (entity) from another ship: vanilla captain exchange.
--   swap    the two ships exchange pilots
--   empty   the candidate moves over; the source promotes its best crew
--   stay    exchange, then the source promotes its best crew in place of the
--           old pilot, who is sent back to the target as service crew
-- Exposed for manager_move.lua (ship stopover): seed candidate into an
-- occupied post with the vanilla dismissal signal.
E.promoteIntoPost = function(t, cand, stay)
	return runPostOccupied(t, cand, stay)
end

local function runPilotExchange(t, cand, stay)
	local src, tgt = cand.ship, t.container
	local oldHolder, oldName = t.holder, t.name
	local reason = checkedExchange(tgt, src, {}, {}, true)
	if reason ~= "" then
		return false, reason
	end
	log("captain exchange: %s (%s) <-> %s (%s), %s", tostring(oldName), tostring(tgt), cand.name, tostring(src), stay and "old pilot stays" or "swap")

	local function sendBack(demoted)
		PromoteSpecialist.scheduler.poll(1, SETTLE_TIMEOUT, "return old pilot", function()
			if not (IsValidComponent(src) and IsValidComponent(tgt)) then
				log("return old pilot: a ship no longer exists, leaving %s where they are", oldName)
				return true
			end
			local why = checkedExchange(tgt, src, {}, { demoted })
			if why == "" then
				log("return old pilot: %s sent to %s", oldName, tostring(tgt))
				pollReassign("old pilot to service", tgt, { { seed = demoted, role = "service" } })
				return true
			end
			log("return old pilot: not yet possible (%s), retrying", why)
			return false
		end, function()
			log("return old pilot: gave up, %s stays on %s", oldName, tostring(src))
		end)
	end

	local function demoteOnSource()
		local best = PromoteSpecialist.candidates.bestCrew(src, "aipilot")
		if not best then
			log("no crew aboard %s to promote, %s stays its pilot", tostring(src), oldName)
			return
		end
		local srcBefore = seedSet(src)
		log("signal npc__control_dismissed: old=%s replacement=%s aboard %s", oldName, best.name, tostring(src))
		C.SignalObjectWithNPCSeed(oldHolder, "npc__control_dismissed", best.seed, src)
		PromoteSpecialist.scheduler.poll(POLL_INTERVAL, SETTLE_TIMEOUT, "find old pilot", function()
			local demoted = findNewPerson(src, srcBefore, oldName)
			if demoted then
				log("old pilot %s is crew on %s now", oldName, tostring(src))
				refresh()
				sendBack(demoted)
				return true
			end
			return false
		end, function()
			log("find old pilot: %s not found on %s", oldName, tostring(src))
		end)
	end

	PromoteSpecialist.scheduler.poll(POLL_INTERVAL, HOLDER_TIMEOUT, "captain handover", function()
		-- matched by "not the old holder" rather than by id, in case the
		-- engine re-creates the entity when it moves
		local tgtHolder = PromoteSpecialist.target.postHolder(tgt, "aipilot")
		if not tgtHolder or tgtHolder == oldHolder then
			return false
		end
		if oldHolder then
			local srcHolder = PromoteSpecialist.target.postHolder(src, "aipilot")
			if not srcHolder or srcHolder == cand.entity then
				return false
			end
			oldHolder = srcHolder
		elseif PromoteSpecialist.target.postHolder(src, "aipilot") then
			-- wait until the source has really lost its pilot before filling it
			return false
		end
		log("captain exchange done: %s (%s) pilots %s", cand.name, tostring(tgtHolder), tostring(tgt))
		refresh()
		if not oldHolder then
			promoteBestAboard(src)
		elseif stay then
			demoteOnSource()
		end
		return true
	end, function()
		log("captain handover: pilots of %s and %s did not change within %ds", tostring(tgt), tostring(src), HOLDER_TIMEOUT)
	end)
	return true
end

local function runCrew(t, cand, stay)
	local a, b = t.container, cand.ship
	local outgoingRole = stay and "service" or cand.role
	if a == b then
		-- only a candidate with another role reaches here (see candidates.collect)
		log("same-ship role swap on %s: %s -> %s, %s -> %s", tostring(a), t.name, outgoingRole, cand.name, t.role)
		pollReassign("role swap", a, { { seed = t.seed, role = outgoingRole }, { seed = cand.seed, role = t.role } })
		return true
	end
	if stay then
		local reason = checkedExchange(a, b, {}, { cand.seed })
		if reason ~= "" then
			return false, reason
		end
		log("crew transfer: %s (%s) from %s to %s, %s stays as service", cand.name, cand.role, tostring(b), tostring(a), t.name)
		pollReassign("roles on target", a, { { seed = cand.seed, role = t.role }, { seed = t.seed, role = "service" } })
		return true
	end
	local reason = checkedExchange(a, b, { t.seed }, { cand.seed })
	if reason ~= "" then
		return false, reason
	end
	log("crew exchange: %s (%s) %s <-> %s %s (%s)", t.name, t.role, tostring(a), tostring(b), cand.name, cand.role)
	if t.role ~= cand.role then
		pollReassign("role incoming", a, { { seed = cand.seed, role = t.role } })
		pollReassign("role outgoing", b, { { seed = t.seed, role = cand.role } })
	end
	return true
end

-- Starts the swap of target t with candidate cand (opts: see top). Returns
-- true, or false and a reason string when the engine refused immediately.
function E.run(t, cand, opts)
	local stay = (opts and opts.stay) or false
	local ok, reason = PromoteSpecialist.target.check(t)
	if not ok then
		return false, PromoteSpecialist.text(reason)
	end
	if not PromoteSpecialist.candidates.stillValid(cand) then
		return false, PromoteSpecialist.text(PromoteSpecialist.target.REASON_TRANSFER)
	end
	if stay then
		local canStay, why = PromoteSpecialist.target.checkStay(t, cand)
		if not canStay then
			return false, PromoteSpecialist.text(why)
		end
	end
	local result, err
	if cand.kind == "entity" and cand.sourcePost == "manager" then
		result, err = PromoteSpecialist.managerMove.run(t, cand)
	elseif cand.kind == "entity" then
		result, err = runPilotExchange(t, cand, stay)
	elseif t.kind == "post_occupied" then
		result, err = runPostOccupied(t, cand, stay)
	elseif t.kind == "post_empty" then
		result, err = runPostEmpty(t, cand)
	else
		result, err = runCrew(t, cand, stay)
	end
	if not result then
		log("refused (%s): %s", tostring(err), PromoteSpecialist.target.describe(t))
	end
	refresh()
	return result, err
end

return E
