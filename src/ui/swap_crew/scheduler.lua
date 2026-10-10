-- Deferred and polled execution on the UI update loop.
--
-- Helper's one-time callback list is shared by every menu and mod, and its loop
-- has no error handling: one failing callback drops all others queued in that
-- frame. Every body scheduled here therefore runs inside pcall.

SwapCrew = SwapCrew or {}
local S = {}
SwapCrew.scheduler = S

local function guarded(label, fn)
	return function()
		local ok, err = pcall(fn)
		if not ok then
			SwapCrew.log("error in %s: %s", label, tostring(err))
		end
	end
end

-- Run fn after delay seconds of real time (0 = next frame).
function S.after(delay, label, fn)
	Helper.addDelayedOneTimeCallbackOnUpdate(guarded(label, fn), false, getElapsedTime() + (delay or 0))
end

-- Game time. The engine work we wait for (MD state machines, crew transfers)
-- stops while the game is paused, so timeouts must stop with it.
function S.gameNow()
	return GetCurTime()
end

-- Call step() every interval seconds until it returns true or timeout seconds
-- of game time have passed, then call onTimeout() if given. step and onTimeout
-- run guarded; an error in step ends the poll.
function S.poll(interval, timeout, label, step, onTimeout)
	local deadline = S.gameNow() + timeout
	local function tick()
		local ok, done = pcall(step)
		if not ok then
			SwapCrew.log("error in %s: %s", label, tostring(done))
			return
		end
		if done then
			return
		end
		if S.gameNow() >= deadline then
			if onTimeout then
				guarded(label .. " timeout", onTimeout)()
			end
			return
		end
		S.after(interval, label, tick)
	end
	S.after(interval, label, tick)
end

return S
