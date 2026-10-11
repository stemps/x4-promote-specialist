-- Pure selection logic: star ratings, availability counts and candidate choice.
-- No engine calls, so it can be exercised outside the game.
--
-- A candidate is a table with at least:
--   skill     combined skill for the target post or role, 0-100
--   sameShip  true when the candidate is already aboard the target's container
--   sameSector true when the candidate's ship is in the target's sector
--   distance  distance to the target in metres (math.huge if unknown)
--   key       stable tie-break and identity string (seed or entity key)
--
-- The dialog sorts the candidates with M.sorted (best first), narrows them with
-- a star filter (M.filter) and keeps a cursor index into the filtered pool.

PromoteSpecialist = PromoteSpecialist or {}
local M = {}
PromoteSpecialist.model = M

M.MAX_STARS = 5

-- Full stars as shown by Helper.displaySkill: skill 0-100 -> 0-15 -> 0-5.
function M.stars(skill)
	return math.floor(math.floor((skill or 0) * 15 / 100) / 3)
end

-- { any = total, [1..5] = number of candidates with exactly that many stars }
function M.counts(candidates)
	local result = { any = #candidates }
	for n = 1, M.MAX_STARS do
		result[n] = 0
	end
	for _, cand in ipairs(candidates) do
		local s = math.min(M.stars(cand.skill), M.MAX_STARS)
		if s >= 1 then
			result[s] = result[s] + 1
		end
	end
	return result
end

local function closer(a, b)
	if a.sameShip ~= b.sameShip then
		return a.sameShip
	end
	if a.sameSector ~= b.sameSector then
		return a.sameSector
	end
	if a.distance ~= b.distance then
		return a.distance < b.distance
	end
	return a.key < b.key
end

-- New list ordered by skill, highest first; equal skill: closest first.
function M.sorted(candidates)
	local list = {}
	for i, cand in ipairs(candidates) do
		list[i] = cand
	end
	table.sort(list, function(a, b)
		if a.skill ~= b.skill then
			return a.skill > b.skill
		end
		return closer(a, b)
	end)
	return list
end

-- First index in sorted whose skill equals sorted[i].skill, i.e. the closest
-- candidate of that skill.
local function firstOfSkill(sorted, i)
	local skill = sorted[i].skill
	while i > 1 and sorted[i - 1].skill == skill do
		i = i - 1
	end
	return i
end

-- choice: "best" for the highest skill, "worst" for the lowest, or N (1-5) for
-- the weakest candidate with exactly N stars. Closest wins among equal skill.
-- Returns an index into sorted, or nil.
function M.pickIndex(sorted, choice)
	if #sorted == 0 then
		return nil
	end
	if choice == "best" then
		return 1
	end
	if choice == "worst" then
		return firstOfSkill(sorted, #sorted)
	end
	for i = #sorted, 1, -1 do
		if math.min(M.stars(sorted[i].skill), M.MAX_STARS) == choice then
			return firstOfSkill(sorted, i)
		end
	end
	return nil
end

-- Candidates of sorted that pass filter: "any", or N (1-5) for exactly N stars.
-- Keeps the order.
function M.filter(sorted, filter)
	local pool = {}
	for _, cand in ipairs(sorted) do
		if filter == "any" or math.min(M.stars(cand.skill), M.MAX_STARS) == filter then
			table.insert(pool, cand)
		end
	end
	return pool
end

-- Same as pickIndex on an unsorted list; returns the candidate or nil.
function M.pick(candidates, choice)
	local sorted = M.sorted(candidates)
	local i = M.pickIndex(sorted, choice)
	return i and sorted[i] or nil
end

-- Index of the candidate with key in list, or nil.
function M.indexOf(list, key)
	if key == nil then
		return nil
	end
	for i, cand in ipairs(list) do
		if cand.key == key then
			return i
		end
	end
	return nil
end

return M
