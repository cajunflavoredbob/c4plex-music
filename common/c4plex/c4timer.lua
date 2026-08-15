-- common/c4plex/c4timer.lua
--
-- Named-timer helpers over the Control4 C4:SetTimer API. Independent
-- implementation written from the public C4 timer API and the call sites our
-- drivers use.
--
-- C4:SetTimer(delayMs, fn, repeat) returns a timer object whose :Cancel() stops
-- it; the callback is invoked as fn(timer, skips). We key those timers by a
-- string name so a driver can re-arm or cancel one without holding the handle.
--
-- Contract (globals, matching how the drivers call them):
--   SetTimer(name, delayMs, fn, repeating) -> timer
--       Re-arms: any existing timer with this name is cancelled first, so the
--       newest SetTimer for a name always wins (one live timer per name).
--       repeating == true keeps firing; otherwise it is one-shot and cleans
--       itself up after it fires. fn runs under pcall so an error is contained.
--   CancelTimer(name)  -> nil   (accepts a name string or a timer object)
--   ONE_SECOND / ONE_MINUTE / ONE_HOUR / ONE_DAY  (millisecond constants)
--   KillAllTimers()    -> cancel every named timer (driver teardown)

ONE_SECOND = ONE_SECOND or 1000
ONE_MINUTE = ONE_MINUTE or 60 * ONE_SECOND
ONE_HOUR = ONE_HOUR or 60 * ONE_MINUTE
ONE_DAY = ONE_DAY or 24 * ONE_HOUR

-- name (string) -> live C4 timer object, and timer object -> its user callback
local byName = {}
local byTimer = {}

function CancelTimer (id)
	local timer
	if (type (id) == 'string') then
		timer = byName [id]
		byName [id] = nil
	elseif (id ~= nil) then
		-- any non-string handle is treated as the timer object itself; the C4
		-- runtime's timer type is not guaranteed to be userdata, and assuming so
		-- would make KillAllTimers a silent no-op
		timer = id
		-- drop any name still pointing at this timer object
		for name, t in pairs (byName) do
			if (t == timer) then byName [name] = nil end
		end
	end
	if (timer) then
		byTimer [timer] = nil
		-- the whole access is guarded: indexing .Cancel on a non-indexable
		-- handle (a number passed as a timer name) would itself throw
		pcall (function ()
			if (timer.Cancel) then timer:Cancel () end
		end)
	end
	return nil
end

function SetTimer (name, delayMs, fn, repeating)
	if (type (fn) ~= 'function') then
		-- parity fallback: a missing function calls a global named `name`, if any
		local g = (type (name) == 'string') and _G [name]
		fn = (type (g) == 'function') and g or function () end
	end
	local repeat_ = (repeating == true)
	local wrapper = function (t, skips)
		local cb = byTimer [t]
		if (cb) then
			-- surface the error: a silently-swallowed throw in a repeating
			-- callback (the keepalive, the re-register) turns a recovery
			-- mechanism into a no-op with nothing to diagnose
			local ok, err = pcall (cb, t, skips)
			if (not ok) then
				-- redact a token in case a callback's error carries a Plex URL
				local msg = tostring (err):gsub ('X%-Plex%-Token=[^&%s]*', 'X-Plex-Token=REDACTED')
				print ('c4plex: timer callback error: ' .. msg)
			end
		end
		if (not repeat_) then
			-- one-shot: clear bookkeeping and release the timer after it fires.
			-- Guard on byName[name] == t so a callback that re-armed the same
			-- name does not have its fresh timer wiped out here.
			byTimer [t] = nil
			if (type (name) == 'string' and byName [name] == t) then
				byName [name] = nil
			end
			-- guarded like CancelTimer: even indexing .Cancel on a
			-- non-indexable handle would throw
			pcall (function ()
				if (t.Cancel) then t:Cancel () end
			end)
		end
	end
	-- Create the new timer BEFORE cancelling the old one: C4:SetTimer can return
	-- nil, and cancelling first would then leave the name with no live timer at
	-- all (e.g. the keepalive would silently stop). On a failed create we keep
	-- the existing timer untouched.
	local timer = C4:SetTimer (delayMs, wrapper, repeat_)
	if (not timer) then return nil end
	CancelTimer (name) -- re-arm: drop the prior timer now the replacement exists
	byTimer [timer] = fn
	if (type (name) == 'string') then byName [name] = timer end
	return timer
end

function KillAllTimers ()
	-- Iterate byTimer, not byName, so a timer registered under a non-string name
	-- (which never lands in byName) is still cancelled on teardown.
	for timer in pairs (byTimer) do
		CancelTimer (timer)
	end
end
