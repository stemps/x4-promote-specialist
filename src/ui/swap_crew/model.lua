-- Pure selection logic: star ratings, availability counts and candidate choice.
-- No engine calls, so it can be exercised outside the game.
--
-- A candidate is a table with at least:
--   skill     combined skill for the target post or role, 0-100
--   sameShip  true when the candidate is already aboard the target's container
--   sameSector true when the candidate's ship is in the target's sector
--   distance  distance to the target in metres (math.huge if unknown)
--   key       stable tie-break string (the seed key)

SwapCrew = SwapCrew or {}
local M = {}
SwapCrew.model = M

M.MAX_STARS = 5

-- Full stars as shown by Helper.displaySkill: skill 0-100 -> 0-15 -> 0-5.
function M.stars(skill)
	return math.floor(math.floor((skill or 0) * 15 / 100) / 3)
end

-- { best = total, [1..5] = number of candidates with at least that many stars }
function M.counts(candidates)
	local result = { best = #candidates }
	for n = 1, M.MAX_STARS do
		result[n] = 0
	end
	for _, cand in ipairs(candidates) do
		local s = M.stars(cand.skill)
		for n = 1, math.min(s, M.MAX_STARS) do
			result[n] = result[n] + 1
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

-- choice: "best" for the highest skill, or N (1-5) for the weakest candidate
-- with at least N stars. Returns the chosen candidate or nil.
function M.pick(candidates, choice)
	local pool = {}
	for _, cand in ipairs(candidates) do
		if choice == "best" or M.stars(cand.skill) >= choice then
			table.insert(pool, cand)
		end
	end
	if #pool == 0 then
		return nil
	end
	local best = choice == "best"
	table.sort(pool, function(a, b)
		if a.skill ~= b.skill then
			if best then
				return a.skill > b.skill
			end
			return a.skill < b.skill
		end
		return closer(a, b)
	end)
	return pool[1]
end

return M
