--!strict
-- @Author @OrkGabb
-- AC/Core/Contract.luau
--
-- Runtime enforcement of the non-yielding contract on injected callbacks.
--
-- Every module in this layer takes integrator callbacks (getWallet, getRates,
-- getClickPower, ...) whose contracts require returning without yielding: the
-- layer's atomicity guarantees — Deduct's check-then-write, PassiveAccrual's
-- clock accounting, the purchase gate sequence — all rest on "Luau tasks only
-- switch at yields". Those contracts were documented but unenforced; a
-- getWallet that reaches a DataStore or a getRates that WaitForChilds
-- silently reopens every interleaving bug this layer exists to close.
--
-- NonYielding(name, fn) wraps a callback so each invocation runs inside its
-- own coroutine and is checked for completion synchronously:
--   * returns without yielding -> results pass through untouched;
--   * errors -> the error propagates to the caller unchanged (consumers
--     already handle callback errors exactly as they did unwrapped);
--   * YIELDS -> the coroutine is closed (the suspended work never resumes,
--     so it cannot mutate anything later), a throttled warning names the
--     offending callback for the audit trail, and the call returns nothing —
--     which every optional-returning contract already reads as "unavailable"
--     (no wallet -> no credit, no rates -> no accrual, no upgrades -> no
--     purchase). Callbacks with no in-band nil (getClickPower, multipliers)
--     make the caller's arithmetic error loudly instead of crediting on
--     garbage. Both directions fail CLOSED, and both are attributable.
--
-- A boot-time dry-run probe cannot give this guarantee — yield behavior is
-- input-dependent (the same getWallet returns instantly for a loaded profile
-- and yields for an unloaded one) — so enforcement is per-invocation and
-- permanent. Cost is one short-lived coroutine per call: negligible next to
-- the work any real callback does.
--
-- Deliberately NOT wrapped anywhere: ReceiptProcessor's `grant` (yielding is
-- legal there by design — DataStore awards — and the in-flight PurchaseId
-- guard is what makes that safe) and post-completion notification hooks
-- (onPurchased, onOwnershipChanged), which run after every state write of
-- their operation has landed and may legitimately start async work.

local Contract = {}

local WARN_INTERVAL = 5

-- Throttled per-callback so a broken hot-path callback (violating on every
-- click) warns once per window instead of flooding the log.
local lastWarnAt: { [string]: number } = {}
local suppressedCount: { [string]: number } = {}

local function reportViolation(name: string): ()
	local now = os.clock()
	local last = lastWarnAt[name]
	if last ~= nil and now - last < WARN_INTERVAL then
		suppressedCount[name] = (suppressedCount[name] or 0) + 1
		return
	end
	local extra = suppressedCount[name] or 0
	lastWarnAt[name] = now
	suppressedCount[name] = 0
	warn(string.format(
		"[Contract] %s yielded — non-yielding contract violation; call dropped (fail-closed)%s",
		name,
		if extra > 0 then string.format(" [%d earlier violations suppressed]", extra) else ""
	))
end

-- Wraps fn so a yielding invocation is contained and dropped (see header).
function Contract.NonYielding<A..., R...>(name: string, fn: (A...) -> R...): (A...) -> R...
	local callback: (...any) -> ...any = fn :: any
	local function guarded(...: any): ...any
		local co = coroutine.create(callback)
		local results = table.pack(coroutine.resume(co, ...))
		if coroutine.status(co) ~= "dead" then
			coroutine.close(co)
			reportViolation(name)
			return
		end
		if not results[1] then
			error(results[2], 2)
		end
		return table.unpack(results, 2, results.n)
	end
	return guarded :: any
end

-- Nil-tolerant variant for optional config callbacks.
function Contract.NonYieldingOpt<A..., R...>(name: string, fn: ((A...) -> R...)?): ((A...) -> R...)?
	if fn == nil then
		return nil
	end
	return Contract.NonYielding(name, fn)
end

return Contract
